#!/usr/bin/env bash
#
# teardown.sh — return OpenShift Local toward a clean state.
#
# Removes everything the openshift/ scripts added: the Route, Service,
# Deployment, the ghcr pull secret (and its link to the default SA), and the
# dedicated part6-spin project. No operator, no CRDs, no PVCs — this stack is
# a plain Deployment, so teardown is correspondingly small.
#
#   ./openshift/teardown.sh                 # clean up, leave CRC running
#   ./openshift/teardown.sh --stop-cluster  # clean up, then crc stop
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STOP_CLUSTER=false
[[ "${1:-}" == "--stop-cluster" ]] && STOP_CLUSTER=true

require_crc
gone() { ! oc get "$@" >/dev/null 2>&1; }

step "1/3 Route + Service + Deployment"
oc delete route "$APP" -n "$NS" --ignore-not-found >/dev/null 2>&1
oc delete svc "$APP" -n "$NS" --ignore-not-found >/dev/null 2>&1
oc delete deploy "$APP" -n "$NS" --ignore-not-found >/dev/null 2>&1
ok "route + service + deployment removed"

step "2/3 ghcr pull secret"
oc secrets unlink default "$PULL_SECRET" -n "$NS" >/dev/null 2>&1 || true
oc delete secret "$PULL_SECRET" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
ok "pull secret removed"

step "3/3 Project $NS"
if [[ "$NS" != "default" ]] && oc get project "$NS" >/dev/null 2>&1; then
    oc delete project "$NS" --wait=false >/dev/null 2>&1 || warn "delete project $NS"
    wait_for 180 "project $NS deleted" gone namespace "$NS"
else
    ok "no deletable project $NS"
fi

leftover="$(oc get ns "$NS" --no-headers 2>/dev/null)"
if [[ -z "$leftover" ]]; then
    ok "CRC is clean of $NS"
else
    printf '    note: still present (allow a moment for terminating resources):\n%s\n' "$leftover"
fi

if [[ "$STOP_CLUSTER" == true ]]; then
    step "crc stop"
    crc stop >/dev/null 2>&1 && ok "OpenShift Local stopped" || fail "crc stop"
fi
