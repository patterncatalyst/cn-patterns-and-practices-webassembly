#!/usr/bin/env bash
#
# deploy.sh — the Part 7 final project's REDUCED OpenShift Local (CRC) pass:
# install the wasmCloud operator (Ch19's firm CRC tier, idempotent), deploy
# BOTH cargo composites (cargo-rust.wasm, cargo-go.wasm) onto one in-cluster
# wasmCloud host, and front each with its own edge-TLS Route. No service
# mesh here — the ch25 Istio proxy-wasm gateway filter stays minikube-only
# for this project (build-plan.md r08).
#
# Steps:
#   1. Confirm both composites exist next to ../build.sh and match their
#      pinned sha256 (the SAME components Part 4/5 and this project's build.sh
#      already produce; contracts/wit untouched).
#   2. Install/upgrade the pinned wasmcloud-platform chart (nats + wadm + the
#      operator) in the dedicated "wasmcloud-final" project — idempotent, same
#      restricted-v2 posture as Ch19.
#   3. Grant the operator's restricted-endpoints RBAC (same narrow
#      network-RBAC grant Ch19 needs; NOT an SCC/anyuid exception).
#   4. Push both composites to private ghcr so the in-cluster host can pull
#      them.
#   5. Create the ghcr docker-registry pull secret the host uses.
#   6. Apply the WasmCloudHostConfig and wait for the host pod.
#   7. Apply wadm-final.yaml (one Application, two components) and wait for
#      the operator to create the Service with BOTH listen ports.
#   8. Apply the two edge-TLS Routes and wait until each serves a real 200 on
#      the cargo path (CA-verified, never -k, never port-forward).
#
# Idempotent. Never starts/stops the cluster.
#
#   eval "$(crc oc-env)"
#   ./openshift/deploy.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
for t in wash gh oc helm curl; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

# ---------------------------------------------------------------------------
step "1/8 Both composites present (sha256 pinned at r08 authoring time)"
if [[ ! -s "$RUST_WASM" || ! -s "$GO_WASM" ]]; then
    warn "composite(s) missing; building them (../build.sh --no-image) ..."
    "$OPENSHIFT_DIR/../build.sh" --no-image || fail "build.sh failed"
fi
got_rust="$(sha256sum "$RUST_WASM" | awk '{print $1}')"
got_go="$(sha256sum "$GO_WASM" | awk '{print $1}')"
[[ "$got_rust" == "$EXPECTED_RUST_SHA" ]] || fail "cargo-rust.wasm sha256 mismatch: got $got_rust, expected $EXPECTED_RUST_SHA"
[[ "$got_go" == "$EXPECTED_GO_SHA" ]] || fail "cargo-go.wasm sha256 mismatch: got $got_go, expected $EXPECTED_GO_SHA (rebuild with ../build.sh if the TinyGo toolchain moved and this pin needs updating)"
ok "cargo-rust.wasm $got_rust / cargo-go.wasm $got_go"

# ---------------------------------------------------------------------------
step "2/8 Project $NS + wasmCloud platform chart $CHART_VERSION (nats + wadm + operator)"
if oc get project "$NS" >/dev/null 2>&1; then
    ok "project $NS exists"
else
    oc new-project "$NS" --display-name="wasmCloud platform (Part 7 final project, OpenShift Local)" >/dev/null \
        || fail "oc new-project $NS"
    ok "project $NS created"
fi
# --dependency-update: the parent OCI chart declares nats/wadm/operator as
# dependencies; pull them at install time (CRC has egress). Pinned to
# CHART_VERSION so the operator/host/nats versions never move without an edit.
helm upgrade --install "$RELEASE" "$CHART_REF" \
    --version "$CHART_VERSION" \
    --namespace "$NS" --create-namespace \
    --values "$OPENSHIFT_DIR/values-crc.yaml" \
    --dependency-update \
    --wait --timeout 10m >/dev/null \
    || fail "helm upgrade --install $RELEASE failed (oc get pods -n $NS)"
ok "release $RELEASE applied (chart $CHART_VERSION)"
oc rollout status statefulset/nats -n "$NS" --timeout=300s >/dev/null 2>&1 \
    || warn "nats statefulset not ready yet (continuing to explicit waits)"
wait_for 300 "wadm Deployment available" \
    oc wait --for=condition=available deploy -l app.kubernetes.io/name=wadm -n "$NS" --timeout=10s
wait_for 300 "wasmcloud-operator Deployment available" \
    oc wait --for=condition=available deploy -l app.kubernetes.io/name=wasmcloud-operator -n "$NS" --timeout=10s
ok "nats + wadm + operator ready"

# ---------------------------------------------------------------------------
step "3/8 Operator RBAC: allow it to manage EndpointSlices to cluster-network IPs"
# OpenShift's RestrictedEndpointsAdmission rejects (403) an EndpointSlice whose
# endpoint address is in the cluster/service network unless the creating SA
# holds the endpoints(slices)/restricted permission. The wasmCloud operator
# builds a selector-less Service for the app and manually writes an
# EndpointSlice pointing at the host pod IP (a cluster-network address), so
# without this grant the Service has no endpoints and the Routes 503. Narrow
# network-RBAC grant, NOT an SCC/anyuid exception (same as Ch19).
oc apply -f - >/dev/null <<EOF || fail "apply operator restricted-endpoints RBAC"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wasmcloud-operator-restricted-endpoints-final
rules:
- apiGroups: [""]
  resources: ["endpoints/restricted"]
  verbs: ["create", "update"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices/restricted"]
  verbs: ["create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wasmcloud-operator-restricted-endpoints-final
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wasmcloud-operator-restricted-endpoints-final
subjects:
- kind: ServiceAccount
  name: wasmcloud-operator
  namespace: $NS
EOF
ok "restricted-endpoints ClusterRole + binding applied (SA wasmcloud-operator/$NS)"

# ---------------------------------------------------------------------------
step "4/8 Push both composites to private ghcr"
TOKEN="$(gh auth token 2>/dev/null)" || fail "gh auth token failed (gh auth status)"
[[ -n "$TOKEN" ]] || fail "empty gh token"
wash push "$RUST_REF" "$RUST_WASM" --user "$GHCR_OWNER" --password "$TOKEN" >/dev/null \
    || fail "wash push $RUST_REF failed"
ok "pushed $RUST_REF"
wash push "$GO_REF" "$GO_WASM" --user "$GHCR_OWNER" --password "$TOKEN" >/dev/null \
    || fail "wash push $GO_REF failed"
ok "pushed $GO_REF"

# ---------------------------------------------------------------------------
step "5/8 ghcr pull secret ($PULL_SECRET) in $NS"
oc create secret docker-registry "$PULL_SECRET" \
    --docker-server=ghcr.io --docker-username="$GHCR_OWNER" --docker-password="$TOKEN" \
    -n "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null \
    || fail "create pull secret"
ok "pull secret $PULL_SECRET applied"

# ---------------------------------------------------------------------------
step "6/8 WasmCloudHostConfig -> wasmCloud host pod"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/wasmcloud-host.yaml" >/dev/null || fail "apply WasmCloudHostConfig"
wait_for 300 "host Deployment created" oc get deploy "$HOSTCFG" -n "$NS"
oc rollout status "deploy/$HOSTCFG" -n "$NS" --timeout=300s >/dev/null \
    || fail "host $HOSTCFG did not roll out (oc get pods -n $NS; oc describe deploy/$HOSTCFG -n $NS)"
ok "wasmCloud host $HOSTCFG ready"

# ---------------------------------------------------------------------------
step "7/8 wadm-final.yaml (one Application, two components) -> Service $APP"
tmp_wadm="$(mktemp -t part7-crc-wadm.XXXXXX.yaml)"
trap 'rm -f "$tmp_wadm"' EXIT
sed -e "s|__RUST_REF__|$RUST_REF|g" -e "s|__GO_REF__|$GO_REF|g" \
    "$OPENSHIFT_DIR/wadm-final.yaml" > "$tmp_wadm"
# -n "$NS": the Application is served by the operator's aggregated API, which
# maps the namespace to a lattice via the WasmCloudHostConfig in that
# namespace. Applying it anywhere without a HostConfig fails with "unable to
# initialize nats client".
oc apply -n "$NS" -f "$tmp_wadm" >/dev/null || fail "apply wadm Application"
ok "wadm Application $APP applied"
wait_for 300 "operator created Service $APP" oc get svc "$APP" -n "$NS"
# Two httpserver providers (one per language) in ONE Application: the operator
# is expected to aggregate both daemonscaler-scaled providers' listen ports
# onto this one Service. This combination has not been exercised elsewhere in
# this project (Ch19/Ch20 each wire exactly one httpserver provider per
# Application) — fail with an explicit message here rather than routing to
# the wrong backend without warning if the Service comes up with fewer than
# two ports.
port_count="$(oc get svc "$APP" -n "$NS" -o jsonpath='{.spec.ports}' 2>/dev/null | python3 -I -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"
if [[ "${port_count:-0}" -lt 2 ]]; then
    fail "Service $APP has $port_count port(s), expected 2 (one per language) — the operator did not aggregate both httpserver providers onto one Service; see README.md 'Two providers, one Application' for the fallback (split into two Applications, the Ch20 shape) instead of routing to the wrong backend without warning"
fi
oc get svc "$APP" -n "$NS" -o custom-columns='SVC:.metadata.name,PORTS:.spec.ports[*].port'
ok "Service $APP exposes $port_count ports"

# ---------------------------------------------------------------------------
step "8/8 edge-TLS Routes -> Service $APP (one per language)"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/route.yaml" >/dev/null || fail "apply Routes"
RUST_HOST="$(route_host cargo-final-rust)"
GO_HOST="$(route_host cargo-final-go)"
[[ -n "$RUST_HOST" ]] || fail "Route cargo-final-rust has no host"
[[ -n "$GO_HOST" ]]   || fail "Route cargo-final-go has no host"
ok "edge-TLS Routes https://$RUST_HOST/ (rust) and https://$GO_HOST/ (go)"

CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$tmp_wadm" "$CA"' EXIT
wait_route_serving "$CA" "$RUST_HOST" "$VALID_PATH" 240
wait_route_serving "$CA" "$GO_HOST"   "$VALID_PATH" 240

printf '\n    next: ./openshift/verify-crc.sh\n'
