#!/usr/bin/env bash
#
# verify-crc.sh — prove, LIVE, on an already-deployed OpenShift Local (CRC)
# instance, that BOTH cargo composites answer correctly through their own
# real edge-TLS Route, TLS verified against the cluster's OWN ingress CA
# (never -k/--insecure, never oc port-forward, never NodePort). This is the
# two-language-on-CRC proof: the final project's thesis made concrete on the
# reduced CRC tier.
#
# Proves:
#   1. GET https://<rust-route>/cargo/CARGO-USNYC-DEHAM and
#      GET https://<go-route>/cargo/CARGO-USNYC-DEHAM both return EXACTLY the
#      same cargo JSON — byte-identical across languages, through two
#      independent Routes.
#   2. GET .../cargo/NOPE returns 404 on both.
#   3. Readiness = a real 200 through each Route, not just "pod Ready" — the
#      router reconciles its backend AFTER the pod is Ready.
#
# Does NOT start/stop/build the cluster and does NOT deploy — run
# ./openshift/deploy.sh first.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
command -v curl >/dev/null 2>&1 || fail "curl not on PATH"

CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle (is the deploy up?)"
trap 'rm -f "$CA"' EXIT
https() { curl -sS --max-time 15 --cacert "$CA" "$@"; }

step "0/4 Preflight: both Routes exist"
RUST_HOST="$(route_host cargo-final-rust)"
GO_HOST="$(route_host cargo-final-go)"
[[ -n "$RUST_HOST" ]] || fail "Route cargo-final-rust not found in $NS — run ./openshift/deploy.sh first"
[[ -n "$GO_HOST" ]]   || fail "Route cargo-final-go not found in $NS — run ./openshift/deploy.sh first"
ok "edge-TLS Routes https://$RUST_HOST/ (rust) and https://$GO_HOST/ (go)"

step "1/4 Readiness: a real 200 through each edge-TLS Route"
wait_route_serving "$CA" "$RUST_HOST" "$VALID_PATH" 120
wait_route_serving "$CA" "$GO_HOST"   "$VALID_PATH" 120

step "2/4 Exact cargo JSON, both languages, byte-identical (CA-verified, through the Routes)"
rust_body="$(https "https://$RUST_HOST$VALID_PATH")" || fail "curl (rust) failed"
go_body="$(https "https://$GO_HOST$VALID_PATH")" || fail "curl (go) failed"
if [[ "$rust_body" != "$EXPECTED_JSON" ]]; then
    printf 'expected: %s\n     got: %s\n' "$EXPECTED_JSON" "$rust_body" >&2
    fail "cargo-rust JSON mismatch"
fi
if [[ "$go_body" != "$EXPECTED_JSON" ]]; then
    printf 'expected: %s\n     got: %s\n' "$EXPECTED_JSON" "$go_body" >&2
    fail "cargo-go JSON mismatch"
fi
if [[ "$rust_body" != "$go_body" ]]; then
    fail "cargo-rust and cargo-go responses differ (expected byte-identical)"
fi
ok "GET $VALID_PATH returned the exact cargo JSON on BOTH Routes, byte-identical"

step "3/4 404 for an unknown tracking id, both languages"
rust_code="$(https -o /dev/null -w '%{http_code}' "https://$RUST_HOST$NOPE_PATH")"
go_code="$(https -o /dev/null -w '%{http_code}' "https://$GO_HOST$NOPE_PATH")"
[[ "$rust_code" == "404" ]] || fail "GET $NOPE_PATH (rust) returned $rust_code, expected 404"
[[ "$go_code" == "404" ]]   || fail "GET $NOPE_PATH (go) returned $go_code, expected 404"
ok "GET $NOPE_PATH -> 404 on both Routes"

step "4/4 Summary"
ok "cargo-rust : https://$RUST_HOST"
ok "cargo-go   : https://$GO_HOST"

echo
echo "PASS — Part 7 final project, reduced OpenShift Local (CRC) pass:" \
     "both language composites deployed by the wasmCloud operator to one" \
     "in-cluster host, each served the exact cargo JSON and a 404 through its" \
     "own edge-TLS Route (CA-verified against the cluster's own ingress CA," \
     "never -k/port-forward/NodePort), byte-identical across Rust and Go." \
     "No service mesh on this cluster."
echo "exit 0"
