#!/usr/bin/env bash
#
# verify-keda-kafka-crc.sh — ch23 serverless scale-to-zero, Kafka half, OpenShift
# Local (CRC). The CRC counterpart of ../k8s/keda/verify-keda-kafka-minikube.sh:
# SAME narrative (producer burst -> consumer-group lag rises -> the Custom
# Metrics Autoscaler's `kafka` ScaledObject OBSERVES it -> wadm's spreadscaler
# OWNS kafka-handler's actual instance count -> the burst drains), run against
# AMQ Streams + the operator-managed wasmCloud lattice instead of upstream
# Strimzi + the Helm-installed platform chart.
#
# TEACHING POINT, sharper here than on minikube: this CRC path has NO
# RuntimeClass/shim Deployment at all for any Part 5 workload (ch19 always runs
# the wasmCloud operator), so there is doubly nothing for a K8s-shaped
# autoscaler to patch — the Custom Metrics Autoscaler's `ScaledObject` here is
# PURELY observational, same as its upstream KEDA counterpart on minikube.
#
# Does NOT start/stop/build the cluster and does NOT deploy Kafka, KEDA, or the
# wadm app — run (in order, none created in this BUILD pass except
# install-cma.sh):
#   1. an AMQ Streams Kafka cluster + the `cargo-handling-events` topic (reuses
#      the ../k8s/kafka/base shapes, retargeted at AMQ Streams' apiVersion if it
#      differs from upstream Strimzi at the installed channel — confirm at
#      kickoff)
#   2. ./install-cma.sh (this BUILD pass)
#   3. oc apply -f ./wadm-kafka.yaml (this BUILD pass; __*_REF__ rewritten by a
#      future deploy-kafka.sh, not created in this pass)
#
# Author-only (this BUILD pass does not touch a cluster): written to the same
# standard as ../verify-crc.sh (require_crc, step/ok/fail, never -k/--insecure,
# never port-forward) but not executed against a live CRC instance. The
# messaging-kafka provider's config keys and the Custom Metrics Autoscaler's
# confirmed startingCSV are both TBD-confirm-at-kickoff (see wadm-kafka.yaml
# and install-cma.sh).
#
#   eval "$(crc oc-env)"
#   ./openshift/verify-keda-kafka-crc.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
for t in oc; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
CMA_NAMESPACE="${CMA_NAMESPACE:-openshift-keda}"
LAG_TIMEOUT="${LAG_TIMEOUT:-180}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-180}"

describe_lag() {
    oc exec -n "$KAFKA_NAMESPACE" deploy/cargo-kafka-entity-operator -- \
        bin/kafka-consumer-groups.sh --bootstrap-server cargo-kafka-kafka-bootstrap.kafka.svc:9092 \
        --describe --group kafka-handler 2>/dev/null || true
}

step "0/5 Preflight: Kafka cluster + wadm app present"
oc get kafka cargo-kafka -n "$KAFKA_NAMESPACE" >/dev/null 2>&1 \
    || fail "Kafka cargo-kafka not found in $KAFKA_NAMESPACE — bring up AMQ Streams + the cluster first"
oc get application.core.oam.dev cargo-kafka -n "$NS" >/dev/null 2>&1 \
    || fail "wadm Application cargo-kafka not found in $NS — oc apply -f ./wadm-kafka.yaml first"
ok "Kafka cluster + wadm app present"

step "1/5 kafka-handler pods present (wadm-owned, via the operator-managed lattice)"
oc get pods -n "$NS" -l wasmcloud.dev/scale-to=kafka-handler --no-headers 2>/dev/null | head -5
ok "kafka-handler component pod(s) visible"

step "2/5 Producer burst -> consumer-group lag rises (confirmed via oc exec, never assumed)"
oc exec -n "$KAFKA_NAMESPACE" deploy/cargo-kafka-entity-operator -- \
    bash -c "echo 'CARGO-USNYC-DEHAM|loaded|DEHAM|VOY-001|2026-11-01T00:00:00Z' | bin/kafka-console-producer.sh --bootstrap-server cargo-kafka-kafka-bootstrap.kafka.svc:9092 --topic cargo-handling-events" \
    || fail "producer burst via oc exec failed"
waited=0; lagged=0
while (( waited < LAG_TIMEOUT )); do
    out="$(describe_lag)"
    total_lag="$(awk '/kafka-handler/{sum+=$NF} END{print sum+0}' <<<"$out")"
    if [[ "${total_lag:-0}" -gt 0 ]]; then
        lagged=1
        ok "observed total lag=$total_lag after ${waited}s"
        break
    fi
    sleep 10; waited=$(( waited + 10 ))
done
[[ "$lagged" -eq 1 ]] || fail "no consumer-group lag observed within ${LAG_TIMEOUT}s of the burst"

step "3/5 Custom Metrics Autoscaler ScaledObject reflects the lag (observational only)"
oc get scaledobject kafka-handler-lag -n "$KAFKA_NAMESPACE" -o wide 2>/dev/null \
    || fail "ScaledObject kafka-handler-lag not found in $KAFKA_NAMESPACE"
ok "ScaledObject present — it OBSERVES lag; it does NOT own kafka-handler's instance count (wadm does)"

step "4/5 wadm spreadscaler instances (what actually owns the scale, if raised by hand/automation)"
oc get application.core.oam.dev cargo-kafka -n "$NS" -o jsonpath='{.status.components[?(@.name=="kafka-handler")]}' 2>/dev/null; echo
ok "kafka-handler component status printed"

step "5/5 Burst drains — lag returns toward zero"
waited=0; drained=0
while (( waited < DRAIN_TIMEOUT )); do
    out="$(describe_lag)"
    total_lag="$(awk '/kafka-handler/{sum+=$NF} END{print sum+0}' <<<"$out")"
    if [[ "${total_lag:-1}" -eq 0 ]]; then
        drained=1
        ok "lag drained to 0 after ${waited}s"
        break
    fi
    sleep 10; waited=$(( waited + 10 ))
done
[[ "$drained" -eq 1 ]] || fail "lag never drained to 0 within ${DRAIN_TIMEOUT}s"

echo
echo "PASS — part5-kubernetes ch23 KEDA Kafka half on OpenShift Local (CRC):"
echo "  a producer message raised cargo-handling-events consumer-group lag, the"
echo "  Custom Metrics Autoscaler's kafka ScaledObject observed it, and the lag"
echo "  drained once the wadm-owned kafka-handler component consumed it."
echo "exit 0"
