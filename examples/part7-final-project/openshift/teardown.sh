#!/usr/bin/env bash
#
# teardown.sh — return OpenShift Local to a clean state, then stop it.
#
# Removes everything the openshift/ scripts added: both Routes, the wadm
# Application (both composites), the WasmCloudHostConfig (and the host
# Deployment the operator made), the ghcr pull secret, this project's
# restricted-endpoints RBAC grant, and the whole wasmcloud-platform Helm
# release (nats + wadm + operator). Operands go while the operator still runs
# so no finalizer is left waiting on a controller that is already gone.
# Deletes the NATS JetStream PVCs (the hostpath storageclass uses
# reclaimPolicy Retain, so helm uninstall leaves them), then deletes the
# dedicated "wasmcloud-final" project.
#
#   ./openshift/teardown.sh                 # clean up, then crc stop
#   ./openshift/teardown.sh --keep-running  # clean up, leave CRC running
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEP_RUNNING=false
[[ "${1:-}" == "--keep-running" ]] && KEEP_RUNNING=true

require_crc
gone() { ! oc get "$@" >/dev/null 2>&1; }

step "1/6 Routes + wadm Application"
oc delete route cargo-final-rust cargo-final-go -n "$NS" --ignore-not-found >/dev/null 2>&1
oc delete application.core.oam.dev "$APP" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
ok "routes + application removed"

step "2/6 WasmCloudHostConfig (host Deployment goes with it, operator still running)"
oc delete wasmcloudhostconfig "$HOSTCFG" -n "$NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
oc delete svc "$APP" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
ok "host config + operator-created Service removed"

step "3/6 Helm release (nats + wadm + operator)"
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    helm uninstall "$RELEASE" -n "$NS" --wait --timeout 5m >/dev/null 2>&1 || warn "helm uninstall reported an error"
    ok "release $RELEASE uninstalled"
else
    ok "no release $RELEASE"
fi

step "4/6 Leftover NATS JetStream PVCs + pull secret + operator RBAC"
oc delete pvc -n "$NS" -l app.kubernetes.io/name=nats --ignore-not-found >/dev/null 2>&1 || true
# Belt-and-braces: any nats-* PVC the label misses.
for p in $(oc get pvc -n "$NS" -o name 2>/dev/null | grep -i nats || true); do
    oc delete "$p" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
done
oc delete secret "$PULL_SECRET" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
# The cluster-scoped restricted-endpoints grant deploy.sh added for this project.
oc delete clusterrolebinding wasmcloud-operator-restricted-endpoints-final --ignore-not-found >/dev/null 2>&1 || true
oc delete clusterrole wasmcloud-operator-restricted-endpoints-final --ignore-not-found >/dev/null 2>&1 || true
# The operator registers an aggregated APIService for the OAM Application API.
# Once the operator is uninstalled its backing Service is gone, discovery for
# core.oam.dev/v1beta1 fails, and that STALLS namespace deletion
# (NamespaceDeletionDiscoveryFailure). Delete it before deleting the project.
# NOTE: if examples/part5-kubernetes's operator is ALSO installed (a separate
# namespace, same cluster-scoped APIService), only delete this once both are
# torn down — deleting it while the other project's operator is still serving
# Applications will break that project's discovery too.
if ! oc get application.core.oam.dev -A --no-headers 2>/dev/null | grep -qv "^$NS"; then
    oc delete apiservice v1beta1.core.oam.dev --ignore-not-found >/dev/null 2>&1 || true
    ok "PVCs + pull secret + operator RBAC + stale OAM APIService removed"
else
    ok "PVCs + pull secret + operator RBAC removed; OAM APIService left (another project still uses it)"
fi

step "5/6 Project $NS"
if [[ "$NS" != "default" ]] && oc get project "$NS" >/dev/null 2>&1; then
    oc delete project "$NS" --wait=false >/dev/null 2>&1 || warn "delete project $NS"
    wait_for 300 "project $NS deleted" gone namespace "$NS"
else
    ok "no deletable project $NS"
fi

step "6/6 Leftover inventory"
leftover="$(
    oc get wasmcloudhostconfig -n "$NS" --no-headers 2>/dev/null
    oc get application.core.oam.dev -n "$NS" --no-headers 2>/dev/null
    oc get ns "$NS" --no-headers 2>/dev/null
)"
if [[ -z "$leftover" ]]; then
    ok "CRC is clean of this project's resources"
else
    printf '    note: still present (allow a moment for terminating resources):\n%s\n' "$leftover"
fi

if [[ "$KEEP_RUNNING" == false ]]; then
    step "crc stop"
    crc stop >/dev/null 2>&1 && ok "OpenShift Local stopped" || fail "crc stop"
fi
