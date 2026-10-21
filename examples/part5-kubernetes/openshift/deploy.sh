#!/usr/bin/env bash
#
# deploy.sh — deploy the cargo HTTP component onto the in-cluster wasmCloud host
# on OpenShift Local (CRC), fronted by an edge-TLS Route. Run after
# install-operator.sh.
#
# Steps:
#   1. Ensure app.wasm exists next to ../build.sh and matches the Part 2/3/4
#      sha256 (the SAME component; contracts/wit untouched).
#   2. Push it to ghcr (private) so the in-cluster host can pull it.
#   3. Create the ghcr docker-registry pull secret the host uses.
#   4. Apply the WasmCloudHostConfig and wait for the host pod.
#   5. Apply the wadm app (daemonscaler) and wait for the operator to create the
#      Service, then wait for the app's desired instances to be deployed.
#   6. Put an edge-TLS Route in front of the operator-created Service and wait
#      until the router actually serves a 200 on the cargo path.
#
# Idempotent. Never starts/stops the cluster.
#
#   eval "$(crc oc-env)"
#   ./openshift/deploy.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
for t in wash gh oc; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

# ---------------------------------------------------------------------------
step "1/6 app.wasm (same component as Part 2/3/4; sha256 $EXPECTED_SHA)"
if [[ ! -s "$APP_WASM" ]]; then
    warn "app.wasm not found; building it (../build.sh --no-image) ..."
    "$OPENSHIFT_DIR/../build.sh" --no-image || fail "build.sh failed"
fi
got="$(sha256sum "$APP_WASM" | awk '{print $1}')"
[[ "$got" == "$EXPECTED_SHA" ]] || fail "app.wasm sha256 mismatch: got $got, expected $EXPECTED_SHA"
ok "app.wasm present, sha256 $got"

# ---------------------------------------------------------------------------
step "2/6 Push the component to $COMPONENT_REF (private)"
TOKEN="$(gh auth token 2>/dev/null)" || fail "gh auth token failed (gh auth status)"
[[ -n "$TOKEN" ]] || fail "empty gh token"
wash push "$COMPONENT_REF" "$APP_WASM" --user "$GHCR_OWNER" --password "$TOKEN" >/dev/null \
    || fail "wash push $COMPONENT_REF failed"
ok "pushed $COMPONENT_REF"

# ---------------------------------------------------------------------------
step "3/6 ghcr pull secret ($PULL_SECRET) in $NS"
oc create secret docker-registry "$PULL_SECRET" \
    --docker-server=ghcr.io --docker-username="$GHCR_OWNER" --docker-password="$TOKEN" \
    -n "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null \
    || fail "create pull secret"
ok "pull secret $PULL_SECRET applied"

# ---------------------------------------------------------------------------
step "4/6 WasmCloudHostConfig -> wasmCloud host pod"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/wasmcloud-host.yaml" >/dev/null || fail "apply WasmCloudHostConfig"
# The operator reconciles the CR into a Deployment named after the CR.
wait_for 300 "host Deployment created" oc get deploy "$HOSTCFG" -n "$NS"
oc rollout status "deploy/$HOSTCFG" -n "$NS" --timeout=300s >/dev/null \
    || fail "host $HOSTCFG did not roll out (oc get pods -n $NS; oc describe deploy/$HOSTCFG -n $NS)"
ok "wasmCloud host $HOSTCFG ready"

# ---------------------------------------------------------------------------
step "5/6 wadm app (daemonscaler) -> operator-created Service $APP:8000"
tmp_wadm="$(mktemp -t part5-crc-wadm.XXXXXX.yaml)"
trap 'rm -f "$tmp_wadm"' EXIT
sed "s|__COMPONENT_REF__|$COMPONENT_REF|g" "$OPENSHIFT_DIR/wadm.yaml" > "$tmp_wadm"
# -n "$NS": the Application is served by the operator's aggregated API, which
# maps the namespace to a lattice via the WasmCloudHostConfig in that namespace.
# Applying it anywhere without a HostConfig (e.g. "default") fails with
# "unable to initialize nats client".
oc apply -n "$NS" -f "$tmp_wadm" >/dev/null || fail "apply wadm Application"
ok "wadm Application $APP applied"
# The operator watches the lattice and creates a Service named after the app
# once the httpserver daemonscaler is up. Wait for the Service to appear.
wait_for 300 "operator created Service $APP" oc get svc "$APP" -n "$NS"
svc_port="$(oc get svc "$APP" -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
ok "Service $APP on port ${svc_port:-?}"

# ---------------------------------------------------------------------------
step "6/6 edge-TLS Route -> Service $APP"
if ! oc get route "$APP" -n "$NS" >/dev/null 2>&1; then
    oc create route edge "$APP" --service="$APP" --port="${svc_port:-8000}" -n "$NS" >/dev/null \
        || fail "create edge Route"
fi
HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$HOST" ]] || fail "Route $APP has no host"
ok "edge-TLS Route https://$HOST/"

# Wait until the router actually serves a 200 on the cargo path (CA-verified,
# never -k). `oc get svc/endpoints` ready is BEFORE the component is answering
# and before the router has a backend, so poll the real path.
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$tmp_wadm" "$CA"' EXIT
waited=0
until code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$CA" \
        "https://$HOST/cargo/CARGO-USNYC-DEHAM" 2>/dev/null)"; [[ "$code" == "200" ]]; do
    (( waited >= 180 )) && fail "Route https://$HOST/cargo/... still not 200 after ${waited}s (got '${code:-000}'); oc get pods,svc,ep,route -n $NS"
    sleep 5; waited=$(( waited + 5 ))
done
ok "Route serving: GET https://$HOST/cargo/CARGO-USNYC-DEHAM -> HTTP 200 after ${waited}s"
printf '    next: ./openshift/verify-crc.sh\n'
