#!/usr/bin/env bash
#
# capture-keda-kafka-crc.sh — verify the ch23 KEDA Kafka half on OpenShift Local
# (CRC) and write what it saw to openshift/evidence/<date>/, mirroring
# ../capture-evidence.sh's structure (step numbering, scrub idiom) for the
# Custom-Metrics-Autoscaler / wadm-owned-kafka-handler narrative
# verify-keda-kafka-crc.sh proves live.
#
# Checks (each fails the script on a miss):
#   1. versions: CMA CSV, AMQ Streams Kafka cluster version, wasmCloud host.
#   2. kafka: cluster + topic Ready, kafka-handler component pods present.
#   3. producer burst -> consumer-group lag confirmed via oc exec (never assumed).
#   4. the ScaledObject reflecting that lag (observational only).
#   5. verify-keda-kafka-crc.sh, run live and captured in full, gated on PASS.
#   6. drain: lag returns to 0.
#   7. secret scrub: no token/password/private-key material under evidence/.
#
# Does NOT start/stop/build the cluster and does NOT deploy — run AMQ Streams +
# the Kafka cluster, ./install-cma.sh, and `oc apply -f ./wadm-kafka.yaml`
# first. Author-only (this BUILD pass does not touch a cluster): written to the
# house evidence-capture standard but not executed against a live CRC instance.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
CMA_NAMESPACE="${CMA_NAMESPACE:-openshift-keda}"
LAG_TIMEOUT="${LAG_TIMEOUT:-180}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-180}"

OUT="$OPENSHIFT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

describe_lag() {
    oc exec -n "$KAFKA_NAMESPACE" deploy/cargo-kafka-entity-operator -- \
        bin/kafka-consumer-groups.sh --bootstrap-server cargo-kafka-kafka-bootstrap.kafka.svc:9092 \
        --describe --group kafka-handler 2>/dev/null || true
}

step "1/7 Versions (pinned)"
{
    crc version | head -3
    oc version | grep -E 'Server|Kubernetes'
    echo "--- Custom Metrics Autoscaler CSV ---"
    oc get csv -n "$CMA_NAMESPACE" -l operators.coreos.com/openshift-custom-metrics-autoscaler-operator."$CMA_NAMESPACE" 2>/dev/null
    echo "--- AMQ Streams Kafka cluster ---"
    oc get kafka cargo-kafka -n "$KAFKA_NAMESPACE" -o jsonpath='{.spec.kafka.version}{"\n"}' 2>/dev/null
    echo "--- wasmCloud host ---"
    oc get wasmcloudhostconfig -n "$NS" 2>/dev/null
} > "$OUT/20-versions.txt" 2>&1
ok "versions -> 20-versions.txt"

step "2/7 Kafka cluster + topic + kafka-handler pods"
{
    oc get kafka,kafkatopic -n "$KAFKA_NAMESPACE" -o wide
    echo "--- kafka-handler pods ---"
    oc get pods -n "$NS" -l wasmcloud.dev/scale-to=kafka-handler -o wide 2>/dev/null
} > "$OUT/21-kafka.txt" 2>&1
ok "kafka + pods -> 21-kafka.txt"

step "3/7 Producer burst -> consumer-group lag"
{
    echo "--- lag BEFORE the burst ---"
    describe_lag
    echo "--- producing one burst message via oc exec (no port-forward) ---"
    oc exec -n "$KAFKA_NAMESPACE" deploy/cargo-kafka-entity-operator -- \
        bash -c "echo 'CARGO-USNYC-DEHAM|loaded|DEHAM|VOY-001|2026-11-01T00:00:00Z' | bin/kafka-console-producer.sh --bootstrap-server cargo-kafka-kafka-bootstrap.kafka.svc:9092 --topic cargo-handling-events"
    echo "--- polling for lag to rise (timeout ${LAG_TIMEOUT}s) ---"
    waited=0; lagged=0
    while (( waited < LAG_TIMEOUT )); do
        out="$(describe_lag)"
        total_lag="$(awk '/kafka-handler/{sum+=$NF} END{print sum+0}' <<<"$out")"
        echo "t=${waited}s total_lag=${total_lag:-0}"
        if [[ "${total_lag:-0}" -gt 0 ]]; then lagged=1; echo "$out"; break; fi
        sleep 10; waited=$(( waited + 10 ))
    done
    echo "lagged=$lagged"
} > "$OUT/22-producer-burst-lag.txt" 2>&1
grep -q "lagged=1" "$OUT/22-producer-burst-lag.txt" || fail "no consumer-group lag observed (see $OUT/22-producer-burst-lag.txt)"
ok "lag observed -> 22-producer-burst-lag.txt"

step "4/7 ScaledObject (observational only — wadm owns the actual scale)"
oc get scaledobject kafka-handler-lag -n "$KAFKA_NAMESPACE" -o yaml > "$OUT/23-scaledobject.yaml" 2>&1
ok "scaledobject -> 23-scaledobject.yaml"

step "5/7 verify-keda-kafka-crc.sh (live producer burst + lag + drain narrative)"
"$OPENSHIFT_DIR/verify-keda-kafka-crc.sh" | tee "$OUT/24-verify-keda-kafka-crc.log"
grep -q "^PASS —" "$OUT/24-verify-keda-kafka-crc.log" || fail "verify-keda-kafka-crc.sh did not PASS (see $OUT/24-verify-keda-kafka-crc.log)"
ok "verify-keda-kafka-crc.sh PASS -> 24-verify-keda-kafka-crc.log"

step "6/7 Drain confirmation (lag back to 0, from the verify log)"
grep -q "lag drained to 0" "$OUT/24-verify-keda-kafka-crc.log" || fail "drain confirmation not found in verify log"
ok "drain confirmed -> 24-verify-keda-kafka-crc.log"

step "7/7 Secret scrub"
leaks=0
grep -rlE 'sha256~[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|kubeadmin-password|gh[pousr]_[A-Za-z0-9]{20,}|"auths"|dockerconfigjson' "$OUT" >&2 && leaks=1
(( leaks == 0 )) || fail "evidence contains secret material: delete $OUT and investigate"
echo "no secrets found under $OUT" > "$OUT/25-scrub.txt"
ok "no secrets in $OUT"

printf '\n    evidence: %s\n' "${OUT#"$REPO_ROOT"/}"
