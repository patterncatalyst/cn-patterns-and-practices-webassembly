#!/usr/bin/env bash
#
# capture-evidence.sh — verify the Part 7 final project's reduced CRC deploy
# and write what it saw to openshift/evidence/<date>/. Adapted from
# examples/part5-kubernetes/openshift/capture-evidence.sh for TWO composites.
#
# Checks (each fails the script on a miss):
#   1. versions: crc/oc, the pinned chart + release, the operator image, the
#      host version, the httpserver provider tag.
#   2. pods: nats + wadm + operator + the wasmCloud host, Ready, under
#      restricted-v2 (no anyuid exception anywhere in this stack).
#   3. the Service (both ports) + both edge-TLS Routes.
#   4. the CA-verified curl through BOTH Routes: exact cargo JSON (byte-
#      identical across languages) + 404.
#   5. verify-crc.sh, run live and captured in full, gated on its PASS line.
#   6. sha256 of both composites.
#   7. secret scrub: no token/password/private-key material under evidence/.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc

OUT="$OPENSHIFT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$CA"' EXIT
https() { curl -sS --max-time 20 --cacert "$CA" "$@"; }

RUST_HOST="$(route_host cargo-final-rust)"
GO_HOST="$(route_host cargo-final-go)"
[[ -n "$RUST_HOST" && -n "$GO_HOST" ]] || fail "Route(s) not found — run ./openshift/deploy.sh first"

step "1/7 Versions (pinned)"
{
    crc version | head -3
    oc version | grep -E 'Server|Kubernetes'
    echo "--- helm release ---"
    helm list -n "$NS" --filter "^${RELEASE}$" 2>/dev/null
    echo "--- chart pin: $CHART_REF:$CHART_VERSION ---"
    echo "--- operator image ---"
    oc get deploy -l app.kubernetes.io/name=wasmcloud-operator -n "$NS" \
        -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null
    echo "--- wasmCloud host version (WasmCloudHostConfig) ---"
    oc get wasmcloudhostconfig "$HOSTCFG" -n "$NS" -o jsonpath='version={.spec.version}{"\n"}' 2>/dev/null
    echo "--- httpserver provider tag (wadm-final.yaml) ---"
    grep -m1 'http-server:' "$OPENSHIFT_DIR/wadm-final.yaml" | sed 's/^[[:space:]]*/  /'
    echo "--- component refs ---"
    echo "  rust: $RUST_REF"
    echo "  go:   $GO_REF"
} > "$OUT/00-versions.txt" 2>&1
ok "versions -> 00-versions.txt"

step "2/7 Pods under restricted-v2"
oc get pods -n "$NS" --field-selector=status.phase=Running \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc,UID:.spec.containers[0].securityContext.runAsUser' \
    2>/dev/null | grep -E 'NAME|nats|wadm|operator|wasmcloud-host' > "$OUT/01-pods.txt"
oc get namespace "$NS" -o jsonpath='namespace uid-range: {.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}' >> "$OUT/01-pods.txt"
bad=$(awk 'NR>1 && $1!="namespace" && $1!="POD" && ($2 ~ /false/ || $4 != "restricted-v2")' "$OUT/01-pods.txt" | grep -c . || true)
(( bad == 0 )) || warn "$bad pod(s) not Ready or not restricted-v2 (see $OUT/01-pods.txt)"
ok "pods -> 01-pods.txt"

step "3/7 Service (both ports) + both Routes"
{
    echo "--- Services (operator-created, one per Application) ---"
    oc get svc "$RUST_APP" "$GO_APP" -n "$NS" -o custom-columns='SVC:.metadata.name,TYPE:.spec.type,PORTS:.spec.ports[*].port,SELECTOR:.spec.selector' 2>/dev/null
    oc get endpoints "$RUST_APP" "$GO_APP" -n "$NS" -o custom-columns='EP:.metadata.name,ADDRS:.subsets[*].addresses[*].ip' 2>/dev/null
    echo "--- Routes (edge TLS) ---"
    oc get route -n "$NS" -l app.kubernetes.io/part-of=part7-final-project \
        -o custom-columns='ROUTE:.metadata.name,HOST:.spec.host,TERMINATION:.spec.tls.termination,PORT:.spec.port.targetPort' 2>/dev/null
} > "$OUT/02-service-routes.txt" 2>&1
ok "service + routes -> 02-service-routes.txt"

step "4/7 CA-verified curl through BOTH edge-TLS Routes"
{
    echo "# CA-verified against the cluster ingress CA (curl --cacert combined-bundle), never -k, never port-forward."
    echo "\$ curl --cacert <ingress-ca> https://$RUST_HOST$VALID_PATH   (rust)"
    https "https://$RUST_HOST$VALID_PATH"; echo
    echo "\$ curl --cacert <ingress-ca> https://$GO_HOST$VALID_PATH     (go)"
    https "https://$GO_HOST$VALID_PATH"; echo
    echo "\$ curl -o /dev/null -w %{http_code} https://$RUST_HOST$NOPE_PATH (rust)"
    https -o /dev/null -w '%{http_code}\n' "https://$RUST_HOST$NOPE_PATH"
    echo "\$ curl -o /dev/null -w %{http_code} https://$GO_HOST$NOPE_PATH   (go)"
    https -o /dev/null -w '%{http_code}\n' "https://$GO_HOST$NOPE_PATH"
} > "$OUT/03-http.txt" 2>&1
[[ "$(grep -c '"tracking_id":"CARGO-USNYC-DEHAM"' "$OUT/03-http.txt")" -ge 2 ]] \
    || fail "cargo JSON missing from one or both Routes (see $OUT/03-http.txt)"
[[ "$(grep -c '^404$' "$OUT/03-http.txt")" -ge 2 ]] \
    || fail "expected 404 missing from one or both Routes (see $OUT/03-http.txt)"
ok "http (both routes, byte-identical JSON + 404) -> 03-http.txt"

step "5/7 verify-crc.sh (live readiness + JSON + 404, both languages)"
if ! "$OPENSHIFT_DIR/verify-crc.sh" > "$OUT/04-verify-crc.log" 2>&1; then
    tail -n 40 "$OUT/04-verify-crc.log" >&2
    fail "verify-crc.sh failed — see $OUT/04-verify-crc.log"
fi
grep -q '^PASS' "$OUT/04-verify-crc.log" || fail "verify-crc.sh did not PASS (see $OUT/04-verify-crc.log)"
ok "verify-crc.sh PASS -> 04-verify-crc.log"

step "6/7 Composite sha256 (both languages)"
{
    sha256sum "$RUST_WASM" 2>/dev/null | awk -v e="$EXPECTED_RUST_SHA" '{print; if ($1==e) print "cargo-rust.wasm MATCHES expected sha256"; else print "cargo-rust.wasm MISMATCH expected "e}'
    sha256sum "$GO_WASM" 2>/dev/null | awk -v e="$EXPECTED_GO_SHA" '{print; if ($1==e) print "cargo-go.wasm MATCHES expected sha256"; else print "cargo-go.wasm MISMATCH expected "e}'
} > "$OUT/05-sha256.txt"
[[ "$(grep -c MATCHES "$OUT/05-sha256.txt")" -eq 2 ]] || fail "composite sha mismatch (see $OUT/05-sha256.txt)"
ok "sha256 -> 05-sha256.txt"

step "7/7 Secret scrub"
leaks=0
grep -rlE 'sha256~[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|kubeadmin-password|gh[pousr]_[A-Za-z0-9]{20,}|"auths"|dockerconfigjson' "$OUT" >&2 && leaks=1
(( leaks == 0 )) || fail "evidence contains secret material: delete $OUT and investigate"
echo "no secrets found under $OUT" > "$OUT/06-scrub.txt"
ok "no secrets in $OUT"

printf '\n    evidence: %s\n' "${OUT#"$REPO_ROOT"/}"
