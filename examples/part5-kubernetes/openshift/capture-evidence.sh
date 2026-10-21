#!/usr/bin/env bash
#
# capture-evidence.sh — verify the Part 5 OpenShift deploy and write what it saw
# to openshift/evidence/<date>/. Adapted from the WebSockets CRC reference's
# capture-evidence.sh for this example (wasmCloud operator, no Kafka).
#
# Checks (each fails the script on a miss):
#   1. versions: crc/oc, the pinned chart + CSV-free helm release, the operator
#      image, the host version, the httpserver provider tag.
#   2. pods: nats + wadm + operator + the wasmCloud host, Ready, under
#      restricted-v2 (no anyuid exception anywhere in this stack).
#   3. routes/services: the operator-created Service + the edge-TLS Route.
#   4. the CA-verified curl through the Route: exact cargo JSON + 404.
#   5. verify-crc.sh, run live and captured in full (readiness + JSON + 404 +
#      resilience), gated on its PASS line.
#   6. sha256 of app.wasm (the Part 2/3/4 byte-for-byte component).
#   7. secret scrub: no token/password/private-key material under evidence/.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc

OUT="$OPENSHIFT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$CA"' EXIT
https() { curl -sS --max-time 20 --cacert "$CA" "$@"; }

HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$HOST" ]] || fail "Route $APP not found — run ./openshift/deploy.sh first"

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
    echo "--- httpserver provider tag (wadm) ---"
    grep -m1 'http-server:' "$OPENSHIFT_DIR/wadm.yaml" | sed 's/^[[:space:]]*/  /'
    echo "--- component ref ---"
    echo "  $COMPONENT_REF"
} > "$OUT/00-versions.txt" 2>&1
ok "versions -> 00-versions.txt"

step "2/7 Pods under restricted-v2"
oc get pods -n "$NS" --field-selector=status.phase=Running \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc,UID:.spec.containers[0].securityContext.runAsUser' \
    2>/dev/null | grep -E 'NAME|nats|wadm|operator|wasmcloud-host' > "$OUT/01-pods.txt"
oc get namespace "$NS" -o jsonpath='namespace uid-range: {.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}' >> "$OUT/01-pods.txt"
# Flag any stack pod that is not Ready or not restricted-v2 (skip header + the
# trailing "namespace uid-range" line whose $1 == "namespace").
bad=$(awk 'NR>1 && $1!="namespace" && $1!="POD" && ($2 ~ /false/ || $4 != "restricted-v2")' "$OUT/01-pods.txt" | grep -c . || true)
(( bad == 0 )) || warn "$bad pod(s) not Ready or not restricted-v2 (see $OUT/01-pods.txt)"
ok "pods -> 01-pods.txt"

step "3/7 Service + Route"
{
    echo "--- Service (operator-created) ---"
    oc get svc "$APP" -n "$NS" -o custom-columns='SVC:.metadata.name,TYPE:.spec.type,PORT:.spec.ports[*].port,SELECTOR:.spec.selector' 2>/dev/null
    oc get endpoints "$APP" -n "$NS" -o custom-columns='EP:.metadata.name,ADDRS:.subsets[*].addresses[*].ip' 2>/dev/null
    echo "--- Route (edge TLS) ---"
    oc get route "$APP" -n "$NS" -o custom-columns='ROUTE:.metadata.name,HOST:.spec.host,TERMINATION:.spec.tls.termination,PORT:.spec.port.targetPort' 2>/dev/null
} > "$OUT/02-service-route.txt" 2>&1
ok "service + route -> 02-service-route.txt"

step "4/7 CA-verified curl through the edge-TLS Route"
{
    echo "# CA-verified against the cluster ingress CA (curl --cacert combined-bundle), never -k, never port-forward."
    echo "\$ curl --cacert <ingress-ca> https://$HOST/cargo/CARGO-USNYC-DEHAM"
    https "https://$HOST/cargo/CARGO-USNYC-DEHAM"; echo
    echo "\$ curl -o /dev/null -w %{http_code} https://$HOST/cargo/NOPE"
    https -o /dev/null -w '%{http_code}\n' "https://$HOST/cargo/NOPE"
} > "$OUT/03-http.txt" 2>&1
grep -q '"tracking_id":"CARGO-USNYC-DEHAM"' "$OUT/03-http.txt" || fail "cargo JSON missing (see $OUT/03-http.txt)"
grep -q '^404$' "$OUT/03-http.txt" || fail "expected 404 line missing (see $OUT/03-http.txt)"
ok "http -> 03-http.txt"

step "5/7 verify-crc.sh (live readiness + JSON + 404 + resilience)"
if ! "$OPENSHIFT_DIR/verify-crc.sh" > "$OUT/04-verify-crc.log" 2>&1; then
    tail -n 40 "$OUT/04-verify-crc.log" >&2
    fail "verify-crc.sh failed — see $OUT/04-verify-crc.log"
fi
grep -q '^PASS' "$OUT/04-verify-crc.log" || fail "verify-crc.sh did not PASS (see $OUT/04-verify-crc.log)"
ok "verify-crc.sh PASS -> 04-verify-crc.log"

step "6/7 app.wasm sha256 (Part 2/3/4 byte-for-byte)"
{ sha256sum "$APP_WASM" 2>/dev/null | awk -v e="$EXPECTED_SHA" '{print; if ($1==e) print "MATCHES Part 2/3/4 expected sha256"; else print "MISMATCH expected "e}'; } > "$OUT/05-sha256.txt"
grep -q MATCHES "$OUT/05-sha256.txt" || fail "app.wasm sha mismatch (see $OUT/05-sha256.txt)"
ok "sha256 -> 05-sha256.txt"

step "7/7 Secret scrub"
leaks=0
grep -rlE 'sha256~[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|kubeadmin-password|gh[pousr]_[A-Za-z0-9]{20,}|"auths"|dockerconfigjson' "$OUT" >&2 && leaks=1
(( leaks == 0 )) || fail "evidence contains secret material: delete $OUT and investigate"
echo "no secrets found under $OUT" > "$OUT/06-scrub.txt"
ok "no secrets in $OUT"

printf '\n    evidence: %s\n' "${OUT#"$REPO_ROOT"/}"
