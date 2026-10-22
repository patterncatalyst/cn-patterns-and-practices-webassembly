#!/usr/bin/env bash
#
# capture-otel-evidence-crc.sh — verify the ch24 CRC observability deploy and
# write what it saw to openshift/evidence/<date>/. Same shape as
# capture-evidence.sh: idempotent, ensures the stack is up, generates traffic,
# captures, scrubs. Never starts/stops the cluster.
#
# Checks (each fails the script on a miss):
#   1. versions: the rootless collector image tag + the WasmCloudHostConfig
#      observability block.
#   2. pods: otel-collector under restricted-v2 (no anyuid exception).
#   3. traffic through the existing edge-TLS Route.
#   4. verify-otel-crc.sh, run live and captured in full, gated on its PASS line.
#   5. the collector's debug-exporter log excerpt (trace + the
#      wasmcloud_host.handle_rpc_message.duration metric + a log record).
#   6. the collector's file-exporter output (independent cross-check).
#   7. secret scrub: no token/password/private-key material under evidence/.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc

OUT="$OPENSHIFT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

step "1/7 Versions"
{
    echo "--- otel-collector image ---"
    oc get deploy otel-collector -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null
    echo "--- WasmCloudHostConfig observability block ---"
    oc get wasmcloudhostconfig "$HOSTCFG" -n "$NS" -o jsonpath='{.spec.observability}{"\n"}' 2>/dev/null
} > "$OUT/00-versions.txt" 2>&1
ok "versions -> 00-versions.txt"

step "2/7 otel-collector pod under restricted-v2"
oc get pods -n "$NS" -l app.kubernetes.io/name=otel-collector \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc,UID:.spec.containers[0].securityContext.runAsUser' \
    2>/dev/null > "$OUT/01-pods.txt"
cat "$OUT/01-pods.txt"
bad=$(awk 'NR>1 && ($2 ~ /false/ || $4 != "restricted-v2")' "$OUT/01-pods.txt" | grep -c . || true)
(( bad == 0 )) || warn "$bad otel-collector pod(s) not Ready or not restricted-v2 (see $OUT/01-pods.txt)"
ok "pods -> 01-pods.txt"

step "3/7 Traffic through the existing edge-TLS Route"
HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$HOST" ]] || fail "Route $APP not found — run ./openshift/deploy.sh first"
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$CA"' EXIT
{
    echo "# CA-verified against the cluster ingress CA (curl --cacert combined-bundle), never -k, never port-forward."
    for i in 1 2 3; do
        echo "\$ curl --cacert <ingress-ca> https://$HOST/cargo/CARGO-USNYC-DEHAM"
        curl -sS --max-time 10 --cacert "$CA" "https://$HOST/cargo/CARGO-USNYC-DEHAM"; echo
    done
} > "$OUT/02-traffic.txt" 2>&1
grep -q '"tracking_id":"CARGO-USNYC-DEHAM"' "$OUT/02-traffic.txt" || fail "cargo JSON missing (see $OUT/02-traffic.txt)"
ok "traffic -> 02-traffic.txt"

step "4/7 verify-otel-crc.sh (live: deploy collector, patch host, re-prove)"
if ! "$OPENSHIFT_DIR/verify-otel-crc.sh" > "$OUT/03-verify-otel-crc.log" 2>&1; then
    tail -n 60 "$OUT/03-verify-otel-crc.log" >&2
    fail "verify-otel-crc.sh failed — see $OUT/03-verify-otel-crc.log"
fi
grep -q '^PASS' "$OUT/03-verify-otel-crc.log" || fail "verify-otel-crc.sh did not PASS (see $OUT/03-verify-otel-crc.log)"
ok "verify-otel-crc.sh PASS -> 03-verify-otel-crc.log"

step "5/7 Collector debug-exporter excerpt (trace + metric + log)"
{
    echo "# oc logs deploy/otel-collector -n $NS --tail=2000 | grep -A2 -E 'TraceID|handle_rpc_message.duration|LogRecord #'"
    oc logs deploy/otel-collector -n "$NS" --tail=2000 2>/dev/null \
        | grep -A2 -E 'TraceID|handle_rpc_message\.duration|LogRecord #' | head -200
} > "$OUT/04-collector-debug-log.txt" 2>&1
grep -qi 'TraceID' "$OUT/04-collector-debug-log.txt" || fail "no TraceID in collector debug log (see $OUT/04-collector-debug-log.txt)"
grep -q 'handle_rpc_message.duration' "$OUT/04-collector-debug-log.txt" || fail "metric missing from collector debug log"
grep -qi 'LogRecord #' "$OUT/04-collector-debug-log.txt" || fail "no LogRecord in collector debug log"
ok "debug log excerpt -> 04-collector-debug-log.txt"

step "6/7 Collector file-exporter cross-check (emptyDir, oc exec)"
COLLECTOR_POD="$(oc get pods -n "$NS" -l app.kubernetes.io/name=otel-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
{
    echo "# oc exec $COLLECTOR_POD -n $NS -- sh -c 'grep -c handle_rpc_message.duration /data/otel-output.json'"
    if [[ -n "$COLLECTOR_POD" ]]; then
        oc exec "$COLLECTOR_POD" -n "$NS" -- sh -c 'grep -c "handle_rpc_message.duration" /data/otel-output.json 2>/dev/null || echo 0'
    else
        echo "0"
    fi
} > "$OUT/05-collector-file-export.txt" 2>&1
cat "$OUT/05-collector-file-export.txt"
grep -qE '^[1-9][0-9]*$' "$OUT/05-collector-file-export.txt" \
    || fail "file exporter did not independently confirm the metric (see $OUT/05-collector-file-export.txt)"
ok "file-exporter cross-check -> 05-collector-file-export.txt"

step "7/7 Secret scrub"
leaks=0
grep -rlE 'sha256~[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|kubeadmin-password|gh[pousr]_[A-Za-z0-9]{20,}|"auths"|dockerconfigjson' "$OUT" >&2 && leaks=1
(( leaks == 0 )) || fail "evidence contains secret material: delete $OUT and investigate"
echo "no secrets found under $OUT" > "$OUT/06-scrub.txt"
ok "no secrets in $OUT"

printf '\n    evidence: %s\n' "${OUT#"$REPO_ROOT"/}"
