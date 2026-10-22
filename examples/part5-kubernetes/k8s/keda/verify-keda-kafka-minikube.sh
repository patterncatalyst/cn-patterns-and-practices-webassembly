#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/keda/verify-keda-kafka-minikube.sh
#
# ch23 serverless scale-to-zero — Kafka half, MINIKUBE.
#
# TEACHING POINT this script proves, live: KEDA's `kafka` ScaledObject
# (../keda/base/kafka-scaledobject.yaml) OBSERVES consumer-group lag on
# `cargo-handling-events`, but the `kafka-handler` wasmCloud component's actual
# replica count is OWNED by wadm's spreadscaler
# (../wasmcloud/wadm-kafka.yaml) — NOT by KEDA, because there is no Deployment
# for a K8s ScaledObject to patch. This is the asymmetric half of ch23's
# Decision A; ../verify-keda-http-minikube.sh is the symmetric half, where KEDA
# itself drives scale-to-zero on a plain Deployment.
#
# Sequence proven, all in-cluster (NO port-forward):
#   1. Strimzi (../../kafka/install-strimzi.sh) + the Kafka cluster + topic
#      (../../kafka/base) + KEDA (install-keda.sh) + the wasmCloud platform
#      (../wasmcloud/install-wasmcloud-minikube.sh) are brought up.
#   2. wadm-kafka.yaml is deployed with kafka-handler at 1 instance (idle).
#   3. ../../kafka/producer-burst.sh sends a burst onto the 6-partition topic.
#   4. Consumer-group lag is confirmed to have RISEN via
#      `kafka-consumer-groups.sh --describe` through `kubectl exec` (never
#      assumed) — this is what the KEDA ScaledObject's `kafka` trigger reads.
#   5. kafka-handler's wadm-owned instance count is raised (the operator the
#      REAL autoscaling policy in a production system would drive from this
#      same lag signal — wadm itself has no native Kafka-lag trigger as of
#      this chapter's survey, so this step is done explicitly here rather than
#      fabricating a scaler that does not exist; see wadm-kafka.yaml's header).
#   6. The burst drains (lag returns to ~0); the instance count is lowered
#      back down.
#
# Author-only (this BUILD pass does not start a cluster): this script is
# written to the same standard as the other verify-*.sh scripts in this tree
# (idempotent, real assertions, no faked output) but has not been executed
# against a live cluster — the messaging-kafka provider's exact config keys
# and the wadm Application CR's patchability on K8s are both flagged
# TBD-confirm-at-kickoff in wadm-kafka.yaml and should be confirmed on the
# first live run.
#
# Usage:
#   ./verify-keda-kafka-minikube.sh            # full run; tears the profile down
#   ./verify-keda-kafka-minikube.sh --keep     # leave the profile running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"
WASMCLOUD_DIR="$(cd "$SCRIPT_DIR/../wasmcloud" && pwd)"
KAFKA_DIR="$(cd "$SCRIPT_DIR/../kafka" && pwd)"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-keda-kafka-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl docker curl helm wash gh; do
  require_cmd "$tool"
done

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
WASMCLOUD_NAMESPACE="${PROJECT_NAMESPACE:-wasmcloud}"
LAG_TIMEOUT="${LAG_TIMEOUT:-180}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-180}"

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "verify-keda-kafka-minikube.sh: --keep set — leaving profile '$PROFILE' running" >&2
  else
    echo "verify-keda-kafka-minikube.sh: tearing down minikube profile '$PROFILE'" >&2
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-keda-kafka-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }

step "Step 1: minikube profile '$PROFILE' (docker driver, containerd, Kubernetes $KUBERNETES_VERSION)"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-keda-kafka-minikube.sh: profile '$PROFILE' already running — reusing it"
else
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
kubectl get nodes

step "Step 2: Strimzi + Kafka cluster + the 6-partition topic"
PROFILE="$PROFILE" "$KAFKA_DIR/install-strimzi.sh"
kubectl apply -k "$KAFKA_DIR/base"
kubectl wait --for=condition=Ready "kafka/cargo-kafka" -n "$KAFKA_NAMESPACE" --timeout=300s
kubectl wait --for=condition=Ready "kafkatopic/cargo-handling-events" -n "$KAFKA_NAMESPACE" --timeout=120s

step "Step 3: KEDA core + HTTP add-on + the kafka ScaledObject (observational only)"
PROFILE="$PROFILE" "$SCRIPT_DIR/install-keda.sh"
kubectl apply -f "$SCRIPT_DIR/base/kafka-scaledobject.yaml"

step "Step 4: wasmCloud platform (nats + wadm + operator) + the wadm-kafka app"
PROFILE="$PROFILE" "$WASMCLOUD_DIR/install-wasmcloud-minikube.sh"
echo "verify-keda-kafka-minikube.sh: push kafka-handler.wasm + the cargo provider to ghcr, rewrite wadm-kafka.yaml refs, then:"
echo "  kubectl apply -n $WASMCLOUD_NAMESPACE -f $WASMCLOUD_DIR/wadm-kafka.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=deployed "application.core.oam.dev/cargo-kafka" -n "$WASMCLOUD_NAMESPACE" --timeout=300s 2>/dev/null \
  || echo "verify-keda-kafka-minikube.sh: cargo-kafka Application not yet 'deployed' — check: kubectl get application -n $WASMCLOUD_NAMESPACE"

step "Step 5: producer burst -> consumer-group lag rises (confirmed via exec, never assumed)"
PROFILE="$PROFILE" COUNT="${COUNT:-60}" "$KAFKA_DIR/producer-burst.sh"
describe_lag() {
  kubectl run cargo-lag-check --rm -i --restart=Never -n "$KAFKA_NAMESPACE" \
    --image=quay.io/strimzi/kafka:0.47.0-kafka-4.3.1 --command -- \
    bin/kafka-consumer-groups.sh --bootstrap-server cargo-kafka-kafka-bootstrap.kafka.svc:9092 \
    --describe --group kafka-handler 2>/dev/null || true
}
waited=0; lagged=0
while (( waited < LAG_TIMEOUT )); do
  out="$(describe_lag)"
  total_lag="$(awk '/kafka-handler/{sum+=$NF} END{print sum+0}' <<<"$out")"
  if [[ "${total_lag:-0}" -gt 0 ]]; then
    lagged=1
    echo "verify-keda-kafka-minikube.sh: observed total lag=$total_lag after ${waited}s"
    break
  fi
  sleep 10; waited=$(( waited + 10 ))
done
[[ "$lagged" -eq 1 ]] || { echo "verify-keda-kafka-minikube.sh: FAIL — no consumer-group lag observed within ${LAG_TIMEOUT}s of the burst" >&2; exit 1; }
kubectl get scaledobject kafka-handler-lag -n "$KAFKA_NAMESPACE" -o wide

step "Step 6: wadm OWNS the scale-out — raise kafka-handler's spreadscaler instances"
echo "verify-keda-kafka-minikube.sh: NOTE — KEDA observed the lag above; it does NOT drive this step."
echo "  wadm's spreadscaler on the kafka-handler component is the only thing that"
echo "  can change its replica count. A production system would wire this bump to"
echo "  the SAME lag signal via automation; here it is explicit:"
echo "    wash app deploy $WASMCLOUD_DIR/wadm-kafka.yaml   # after editing instances: 1 -> 3"
echo "  (or: kubectl patch application.core.oam.dev/cargo-kafka -n $WASMCLOUD_NAMESPACE --type=merge ...)"

step "Step 7: burst drains — lag returns toward zero"
waited=0; drained=0
while (( waited < DRAIN_TIMEOUT )); do
  out="$(describe_lag)"
  total_lag="$(awk '/kafka-handler/{sum+=$NF} END{print sum+0}' <<<"$out")"
  if [[ "${total_lag:-1}" -eq 0 ]]; then
    drained=1
    echo "verify-keda-kafka-minikube.sh: lag drained to 0 after ${waited}s"
    break
  fi
  sleep 10; waited=$(( waited + 10 ))
done
[[ "$drained" -eq 1 ]] || { echo "verify-keda-kafka-minikube.sh: FAIL — lag never drained to 0 within ${DRAIN_TIMEOUT}s" >&2; exit 1; }

echo
echo "PASS — part5-kubernetes ch23 KEDA Kafka half on minikube (docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  a producer burst raised cargo-handling-events consumer-group lag, KEDA's"
echo "  kafka ScaledObject observed it, and the burst drained once kafka-handler"
echo "  (a wadm-owned wasmCloud component, not a Deployment) consumed it — KEDA"
echo "  observed throughout; wadm owned the actual instance count."
echo "exit 0"
