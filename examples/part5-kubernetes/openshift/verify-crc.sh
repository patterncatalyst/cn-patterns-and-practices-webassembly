#!/usr/bin/env bash
#
# verify-crc.sh — prove, LIVE, on an already-deployed OpenShift Local (CRC)
# instance, that the cargo component answers correctly through a real edge-TLS
# Route, TLS verified against the cluster's OWN ingress CA (never -k/--insecure,
# never oc port-forward, never NodePort). This is the OpenShift counterpart to
# ../k8s/verify-minikube.sh.
#
# Proves:
#   1. GET https://<route>/cargo/CARGO-USNYC-DEHAM returns EXACTLY the cargo
#      JSON (same bytes the component serves under wasmtime serve / wasmCloud /
#      the minikube shim — see Part 2/3/4).
#   2. GET https://<route>/cargo/NOPE returns 404.
#   3. Readiness = a real 200 through the Route (wait_route_serving), not just
#      "pod Ready" — the router reconciles its backend AFTER the pod is Ready.
#   4. Resilience / self-healing: delete the wasmCloud host pod; the operator's
#      Deployment recreates it and traffic recovers to 200 with no redeploy.
#
# Does NOT start/stop/build the cluster and does NOT deploy — run
# ./openshift/deploy.sh first. It DOES delete a host pod as part of the
# resilience proof (the Deployment restores it).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
command -v curl >/dev/null 2>&1 || fail "curl not on PATH"

EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle (is the deploy up?)"
trap 'rm -f "$CA"' EXIT
https() { curl -sS --max-time 15 --cacert "$CA" "$@"; }

step "0/4 Preflight: Route exists"
HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$HOST" ]] || fail "Route $APP not found in $NS — run ./openshift/deploy.sh first"
ok "edge-TLS Route https://$HOST/"

# wait_route_serving <path> — block until the router serves a 200 on <path>,
# CA-verified. 503/000 means the backend is not (re)wired yet.
wait_route_serving() {
    local path="$1" waited=0 code
    while (( waited < 120 )); do
        code="$(https -o /dev/null -w '%{http_code}' "https://$HOST$path" 2>/dev/null)" || true
        [[ -z "$code" ]] && code=000
        [[ "$code" == "200" ]] && { ok "Route serving (HTTP 200) on $path after ${waited}s"; return 0; }
        sleep 3; waited=$(( waited + 3 ))
    done
    fail "Route https://$HOST$path still not 200 after ${waited}s (last '$code')"
}

step "1/4 Readiness: a real 200 through the edge-TLS Route"
wait_route_serving "/cargo/CARGO-USNYC-DEHAM"

step "2/4 Exact cargo JSON (CA-verified, through the Route)"
body="$(https "https://$HOST/cargo/CARGO-USNYC-DEHAM")" || fail "curl failed"
if [[ "$body" != "$EXPECTED_JSON" ]]; then
    printf 'expected: %s\n     got: %s\n' "$EXPECTED_JSON" "$body" >&2
    fail "cargo JSON mismatch"
fi
ok "GET /cargo/CARGO-USNYC-DEHAM returned the exact cargo JSON"

step "3/4 404 for an unknown tracking id"
code="$(https -o /dev/null -w '%{http_code}' "https://$HOST/cargo/NOPE")"
[[ "$code" == "404" ]] || fail "GET /cargo/NOPE returned $code, expected 404"
ok "GET /cargo/NOPE -> 404"

step "4/4 Resilience: delete the host pod; the Deployment restores it, traffic recovers"
pod="$(oc get pods -n "$NS" -l "app.kubernetes.io/name=$HOSTCFG" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -z "$pod" ]] && pod="$(oc get pods -n "$NS" -o name 2>/dev/null | grep -m1 "$HOSTCFG" | cut -d/ -f2)"
[[ -n "$pod" ]] || fail "could not find the host pod to delete"
echo "    deleting host pod $pod ..."
oc delete pod "$pod" -n "$NS" --wait=false >/dev/null || fail "delete host pod"
# Give the router a moment to drop the backend, then wait for recovery.
sleep 5
oc rollout status "deploy/$HOSTCFG" -n "$NS" --timeout=300s >/dev/null || fail "host did not recover"
wait_route_serving "/cargo/CARGO-USNYC-DEHAM"
body="$(https "https://$HOST/cargo/CARGO-USNYC-DEHAM")" || fail "post-recovery curl failed"
[[ "$body" == "$EXPECTED_JSON" ]] || fail "post-recovery cargo JSON mismatch"
ok "host pod recreated by the operator Deployment; traffic recovered to the exact cargo JSON"

echo
echo "PASS — Part 5 cargo component on OpenShift Local (CRC, crc-admin context):" \
     "deployed by the wasmCloud operator to an in-cluster host; served the exact" \
     "cargo JSON and a 404 through an edge-TLS Route (CA-verified against the" \
     "cluster's own ingress CA, never -k/port-forward/NodePort); and recovered" \
     "after the host pod was deleted."
echo "exit 0"
