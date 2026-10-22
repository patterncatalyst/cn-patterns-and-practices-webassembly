#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/keda/verify-keda-kafka-minikube.sh
#
# ch23 serverless scale-to-zero — Kafka half, MINIKUBE, KEDA-owned design.
#
# cargo-kafka-host (../../kafka-host) is a plain Kubernetes Deployment: a
# native Rust binary that joins the cargo-handling consumer group on
# cargo-handling-events and drives kafka-app.wasm (a `wac plug` composite of
# the Part 2 cargo provider + ../../kafka-handler, wasmtime in-process) once
# per message. Because it is a real Deployment, the `kafka` ScaledObject below
# (base/kafka-scaledobject.yaml) OWNS its replica count end to end, 0 at idle
# up to the topic's 6-partition ceiling under load — no second scaling
# authority to reconcile against.
#
# Sequence proven, all in-cluster (NO port-forward):
#   1. Strimzi + the Kafka cluster + the 6-partition topic, and KEDA core, are
#      brought up.
#   2. kafka-app.wasm + the cargo-kafka-host image are built and loaded into
#      the node (minikube image load, no registry); the Deployment and the
#      kafka ScaledObject are applied.
#   3. KEDA scales cargo-kafka-host DOWN to 0/0 once idle — read from the
#      Deployment, never assumed.
#   4. ../../kafka/producer-burst.sh sends a burst onto the topic.
#   5. Consumer-group lag is confirmed to have RISEN via
#      `kafka-consumer-groups.sh --describe`, run with `kubectl exec` against
#      a disposable Strimzi client pod — read, never assumed.
#   6. KEDA scales cargo-kafka-host OUT (0 -> N, N > 1), polled on a short
#      interval so a fast drain cannot hide the peak.
#   7. The handler's own per-message log lines (`kubectl logs`) confirm the
#      Deployment actually processed messages.
#   8. The burst drains (CURRENT-OFFSET catches LOG-END-OFFSET, lag -> 0);
#      after the cooldown, KEDA scales cargo-kafka-host back to 0/0.
#
# Author-only (this BUILD pass does not start a cluster): written to the same
# standard as the other verify-*.sh scripts in this tree (idempotent,
# asserting on live cluster state); run it on a minikube profile to verify
# the Kafka scale path.
#
# Usage:
#   ./verify-keda-kafka-minikube.sh            # full run; tears the profile down
#   ./verify-keda-kafka-minikube.sh --keep     # leave the profile running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"
KAFKA_DIR="$(cd "$SCRIPT_DIR/../kafka" && pwd)"
KAFKA_HOST_DIR="$(cd "$PART5_DIR/kafka-host" && pwd)"
KAFKA_HOST_MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../kafka-host" && pwd)"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-keda-kafka-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl docker curl helm; do
  require_cmd "$tool"
done

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
CONSUMER_GROUP="${CONSUMER_GROUP:-cargo-handling}"
BOOTSTRAP="${BOOTSTRAP:-cargo-kafka-kafka-bootstrap.${KAFKA_NAMESPACE}.svc:9092}"
TOPIC="${TOPIC:-cargo-handling-events}"
HOST_IMAGE="${HOST_IMAGE:-cargo-kafka-host:minikube}"
CLIENT_POD="${CLIENT_POD:-cargo-kafka-verify-client}"
# Strimzi ships the broker's own Kafka distribution (with the CLI tools) in
# this image; reusing it (same as ../kafka/producer-burst.sh) means no extra
# client image to pin/pull.
CLIENT_IMAGE="${CLIENT_IMAGE:-quay.io/strimzi/kafka:1.3.0-kafka-4.3.1}"
BURST_COUNT="${COUNT:-120}"
ZERO_TIMEOUT="${ZERO_TIMEOUT:-120}"
LAG_TIMEOUT="${LAG_TIMEOUT:-120}"
SCALEOUT_TIMEOUT="${SCALEOUT_TIMEOUT:-150}"
HANDLER_TIMEOUT="${HANDLER_TIMEOUT:-120}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-240}"
POST_DRAIN_ZERO_TIMEOUT="${POST_DRAIN_ZERO_TIMEOUT:-120}"

cleanup() {
  kubectl delete pod "$CLIENT_POD" -n "$KAFKA_NAMESPACE" --wait=false >/dev/null 2>&1 || true
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

step "Step 3: KEDA core"
PROFILE="$PROFILE" "$SCRIPT_DIR/install-keda.sh"

step "Step 4: build kafka-app.wasm + the cargo-kafka-host image, load into the node (no registry)"
"$KAFKA_HOST_DIR/build.sh"
docker build -f "$KAFKA_HOST_DIR/Containerfile" -t "$HOST_IMAGE" "$KAFKA_HOST_DIR"
minikube image load "$HOST_IMAGE" -p "$PROFILE"
assert_file "$KAFKA_HOST_DIR/kafka-app.wasm" "kafka-app.wasm"

step "Step 5: apply cargo-kafka-host (minikube overlay) + the kafka ScaledObject"
kubectl apply -k "$KAFKA_HOST_MANIFESTS_DIR/overlays/minikube"
kubectl apply -f "$SCRIPT_DIR/base/kafka-scaledobject.yaml"

current_replicas() {
  kubectl get deployment cargo-kafka-host -n "$KAFKA_NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo ""
}

step "Step 6: idle -> assert KEDA scales cargo-kafka-host DOWN to 0/0 (never assumed)"
waited=0; zeroed=0
while (( waited < ZERO_TIMEOUT )); do
  r="$(current_replicas)"
  if [[ "$r" == "0" || -z "$r" ]]; then
    zeroed=1
    echo "verify-keda-kafka-minikube.sh: observed scale-to-zero after ${waited}s"
    break
  fi
  sleep 5; waited=$(( waited + 5 ))
done
kubectl get deploy cargo-kafka-host -n "$KAFKA_NAMESPACE"
if [[ "$zeroed" -ne 1 ]]; then
  echo "verify-keda-kafka-minikube.sh: FAIL — cargo-kafka-host never scaled to 0/0 within ${ZERO_TIMEOUT}s of idle (cooldownPeriod is 30s; check keda-operator logs)" >&2
  exit 1
fi

step "Step 7: disposable Strimzi client pod for in-cluster kafka-consumer-groups.sh exec"
kubectl run "$CLIENT_POD" -n "$KAFKA_NAMESPACE" --restart=Never \
  --image="$CLIENT_IMAGE" --command -- sleep 3600 \
  2>/dev/null || echo "verify-keda-kafka-minikube.sh: pod $CLIENT_POD already exists — reusing it"
kubectl wait --for=condition=Ready "pod/$CLIENT_POD" -n "$KAFKA_NAMESPACE" --timeout=120s

describe_group() {
  kubectl exec -i "$CLIENT_POD" -n "$KAFKA_NAMESPACE" -- \
    bin/kafka-consumer-groups.sh --bootstrap-server "$BOOTSTRAP" \
    --describe --group "$CONSUMER_GROUP" 2>/dev/null || true
}

# parse_offsets <describe-output> -> "<current_sum> <logend_sum> <lag_sum>",
# summed across every partition row (PARTITION column is numeric; the header
# and any "no active members" notice are skipped by that filter).
parse_offsets() {
  awk -v grp="$CONSUMER_GROUP" '
    $1 == grp && $3 ~ /^[0-9]+$/ { cur += $4; end += $5; lag += $6 }
    END { printf "%d %d %d\n", cur + 0, end + 0, lag + 0 }
  ' <<<"$1"
}

# Summed topic end offset — the backlog KEDA's kafka scaler reads (with
# offsetResetPolicy: earliest, a consumer group with no committed offset yet is
# treated as lagging the whole topic). Read from the topic directly, so the
# signal is available before the consumer group has committed anything.
topic_end_total() {
  kubectl exec -i "$CLIENT_POD" -n "$KAFKA_NAMESPACE" -- \
    bin/kafka-get-offsets.sh --bootstrap-server "$BOOTSTRAP" --topic "$TOPIC" 2>/dev/null \
    | awk -F: '{ s += $3 } END { printf "%d\n", s + 0 }'
}

step "Step 8: producer burst ($BURST_COUNT messages) -> topic backlog RISES (read, not assumed)"
before="$(topic_end_total)"
echo "verify-keda-kafka-minikube.sh: topic $TOPIC end offset before the burst = $before"
PROFILE="$PROFILE" COUNT="$BURST_COUNT" "$KAFKA_DIR/producer-burst.sh"
waited=0; grew=0
while (( waited < LAG_TIMEOUT )); do
  after="$(topic_end_total)"
  if (( after > before )); then
    grew=1
    echo "verify-keda-kafka-minikube.sh: observed topic backlog grow to $after (was $before) after ${waited}s"
    break
  fi
  sleep 5; waited=$(( waited + 5 ))
done
if [[ "$grew" -ne 1 ]]; then
  echo "verify-keda-kafka-minikube.sh: FAIL — topic backlog did not grow within ${LAG_TIMEOUT}s of the burst" >&2
  exit 1
fi
kubectl get scaledobject cargo-kafka-host -n "$KAFKA_NAMESPACE" -o wide

step "Step 9: assert KEDA scales cargo-kafka-host OUT (0 -> N, N > 1); polled fast so a quick drain can't hide the peak"
waited=0; peak=0
while (( waited < SCALEOUT_TIMEOUT )); do
  r="$(current_replicas)"
  [[ "$r" =~ ^[0-9]+$ ]] || r=0
  if (( r > peak )); then
    peak=$r
  fi
  if (( peak > 1 )); then
    break
  fi
  sleep 2; waited=$(( waited + 2 ))
done
kubectl get deploy cargo-kafka-host -n "$KAFKA_NAMESPACE"
if [[ "$peak" -le 1 ]]; then
  echo "verify-keda-kafka-minikube.sh: FAIL — cargo-kafka-host peak replica count was $peak (expected > 1) within ${SCALEOUT_TIMEOUT}s of the burst" >&2
  exit 1
fi
echo "verify-keda-kafka-minikube.sh: observed peak replicas=$peak"

step "Step 10: assert the handler actually ran (per-message log lines)"
# The host Pods are ephemeral (drained then scaled to zero), so poll while they
# are still up (through the drain + the 30s cooldown) rather than reading once.
waited=0; sawhandler=0; handler_logs=""
while (( waited < HANDLER_TIMEOUT )); do
  handler_logs="$(kubectl logs -l app=cargo-kafka-host -n "$KAFKA_NAMESPACE" --all-containers --prefix --tail=-1 --max-log-requests=10 2>/dev/null || true)"
  if [[ "$handler_logs" == *"outcome="* ]]; then sawhandler=1; break; fi
  sleep 3; waited=$(( waited + 3 ))
done
if [[ "$sawhandler" -ne 1 ]]; then
  echo "verify-keda-kafka-minikube.sh: FAIL — no per-message 'outcome=' log lines from cargo-kafka-host within ${HANDLER_TIMEOUT}s" >&2
  exit 1
fi
echo "verify-keda-kafka-minikube.sh: observed handler activity (outcome= log lines)"

step "Step 11: burst drains (CURRENT-OFFSET catches LOG-END-OFFSET, lag -> 0)"
waited=0; drained=0
while (( waited < DRAIN_TIMEOUT )); do
  read -r cur end lag <<<"$(parse_offsets "$(describe_group)")"
  echo "verify-keda-kafka-minikube.sh: t=${waited}s current-offset=$cur log-end-offset=$end lag=$lag"
  if (( lag == 0 )) && (( end > 0 )); then
    drained=1
    break
  fi
  sleep 10; waited=$(( waited + 10 ))
done
if [[ "$drained" -ne 1 ]]; then
  echo "verify-keda-kafka-minikube.sh: FAIL — lag never drained to 0 within ${DRAIN_TIMEOUT}s" >&2
  exit 1
fi

step "Step 12: after the cooldown, assert KEDA scales cargo-kafka-host back to 0/0"
waited=0; rezeroed=0
while (( waited < POST_DRAIN_ZERO_TIMEOUT )); do
  r="$(current_replicas)"
  if [[ "$r" == "0" || -z "$r" ]]; then
    rezeroed=1
    echo "verify-keda-kafka-minikube.sh: observed scale-back-to-zero after ${waited}s"
    break
  fi
  sleep 5; waited=$(( waited + 5 ))
done
kubectl get deploy cargo-kafka-host -n "$KAFKA_NAMESPACE"
if [[ "$rezeroed" -ne 1 ]]; then
  echo "verify-keda-kafka-minikube.sh: FAIL — cargo-kafka-host never returned to 0/0 within ${POST_DRAIN_ZERO_TIMEOUT}s of the drain (cooldownPeriod is 30s)" >&2
  exit 1
fi

step "Step 13: teardown the test workload (disposable client pod); cargo-kafka-host + the ScaledObject stay deployed"
kubectl delete pod "$CLIENT_POD" -n "$KAFKA_NAMESPACE" --wait=false >/dev/null 2>&1 || true

echo
echo "PASS — part5-kubernetes ch23 KEDA Kafka half on minikube (docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  KEDA scaled cargo-kafka-host from 0/0 up to $peak replica(s) on"
echo "  cargo-handling-events consumer-group lag, the handler processed the burst"
echo "  (kubectl logs confirmed it), and KEDA scaled it back to 0/0 once the lag"
echo "  drained — KEDA owns the replica count end to end, no second scaling"
echo "  authority to reconcile against."
echo "exit 0"
