#!/usr/bin/env bash
#
# verify-crc.sh — prove, LIVE, on an already-deployed OpenShift Local (CRC)
# instance, that the ch26 Spin app answers correctly through a real edge-TLS
# Route, TLS verified against the cluster's OWN ingress CA (never -k/
# --insecure, never oc port-forward, never NodePort).
#
# Proves:
#   1. GET https://<route>/cargo/CARGO-USNYC-DEHAM returns EXACTLY the cargo
#      JSON (the same bytes `spin up` serves locally — see ../../spin/README.md
#      "Verify (no cluster)").
#   2. GET https://<route>/cargo/NOPE returns 404.
#   3. Readiness = a real 200 through the Route (wait_route_serving), not just
#      "pod Ready" — the router reconciles its backend AFTER the pod is Ready.
#   4. Resilience / self-healing: delete the cargo-spin pod; the Deployment
#      recreates it and traffic recovers to 200 with no redeploy.
#
# Does NOT start/stop/build the cluster and does NOT deploy — run
# ./openshift/deploy.sh first. It DOES delete a pod as part of the resilience
# proof (the Deployment restores it).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
command -v curl >/dev/null 2>&1 || fail "curl not on PATH"

CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle (is the deploy up?)"
trap 'rm -f "$CA"' EXIT
https() { curl -sS --max-time 15 --cacert "$CA" "$@"; }

step "0/4 Preflight: Route exists"
HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$HOST" ]] || fail "Route $APP not found in $NS — run ./openshift/deploy.sh first"
ok "edge-TLS Route https://$HOST/"

step "1/4 Readiness: a real 200 through the edge-TLS Route"
wait_route_serving "$HOST" "/cargo/CARGO-USNYC-DEHAM"

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

step "4/4 Resilience: delete the pod; the Deployment restores it, traffic recovers"
pod="$(oc get pods -n "$NS" -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$pod" ]] || fail "could not find the $APP pod to delete"
echo "    deleting pod $pod ..."
oc delete pod "$pod" -n "$NS" --wait=false >/dev/null || fail "delete pod"
# Give the router a moment to drop the backend, then wait for recovery.
sleep 5
oc rollout status "deploy/$APP" -n "$NS" --timeout=300s >/dev/null || fail "$APP did not recover"
wait_route_serving "$HOST" "/cargo/CARGO-USNYC-DEHAM"
body="$(https "https://$HOST/cargo/CARGO-USNYC-DEHAM")" || fail "post-recovery curl failed"
[[ "$body" == "$EXPECTED_JSON" ]] || fail "post-recovery cargo JSON mismatch"
ok "pod recreated by the Deployment; traffic recovered to the exact cargo JSON"

echo
echo "PASS — ch26 Spin app on OpenShift Local (CRC, crc-admin context):" \
     "the spin CLI running inside a restricted-v2 container served the exact" \
     "cargo JSON and a 404 through an edge-TLS Route (CA-verified against the" \
     "cluster's own ingress CA, never -k/port-forward/NodePort); and recovered" \
     "after the pod was deleted."
echo "exit 0"
