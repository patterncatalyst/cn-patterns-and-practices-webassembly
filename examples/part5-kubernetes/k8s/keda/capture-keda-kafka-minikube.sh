#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/keda/capture-keda-kafka-minikube.sh
#
# Headless live run of the ch23 KEDA Kafka half (MINIKUBE, KEDA-owned design)
# that produces the COMMITTED evidence, teeing every step to
# evidence/<YYYY-MM-DD>/2N-*.txt (numbered in the 20s to sit alongside
# ../capture-keda-http-evidence.sh's 0N files under the same evidence/
# directory) with a secret scrub. Mirrors ../capture-keda-http-evidence.sh's
# structure; see verify-keda-kafka-minikube.sh for the full narrative this
# proves (idle 0/0 -> producer burst -> lag rises -> KEDA scales out -> handler
# processes the burst -> lag drains -> KEDA scales back to 0/0).
#
# Does NOT tear the cluster down — run ../teardown.sh afterwards.
#
# Order:
#   20 versions (minikube, Strimzi, KEDA chart versions)
#   21 pods (kafka namespace: Kafka broker + cargo-kafka-host pods)
#   22 deploy-at-zero (cargo-kafka-host Deployment observed at 0/0 while idle)
#   23 lag-after-burst (producer burst + consumer-group lag rising, via
#      kafka-consumer-groups.sh --describe through kubectl exec)
#   24 deploy-scaled-out (cargo-kafka-host Deployment peak replica count > 1)
#   25 handler-logs (per-message log lines from the running replicas)
#   26 lag-drained (CURRENT-OFFSET catches LOG-END-OFFSET, lag -> 0)
#   27 deploy-back-to-zero (cargo-kafka-host Deployment observed at 0/0 again)
#   28 sha256(kafka-app.wasm)
#   29 secret scrub
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"
KAFKA_DIR="$(cd "$SCRIPT_DIR/../kafka" && pwd)"
KAFKA_HOST_DIR="$(cd "$PART5_DIR/kafka-host" && pwd)"
KAFKA_HOST_MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../kafka-host" && pwd)"

for tool in minikube kubectl docker curl helm sha256sum python3; do
  require_cmd "$tool"
done

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
CONSUMER_GROUP="${CONSUMER_GROUP:-cargo-handling}"
BOOTSTRAP="${BOOTSTRAP:-cargo-kafka-kafka-bootstrap.${KAFKA_NAMESPACE}.svc:9092}"
TOPIC="${TOPIC:-cargo-handling-events}"
HOST_IMAGE="${HOST_IMAGE:-cargo-kafka-host:minikube}"
CLIENT_POD="${CLIENT_POD:-cargo-kafka-capture-client}"
CLIENT_IMAGE="${CLIENT_IMAGE:-quay.io/strimzi/kafka:1.3.0-kafka-4.3.1}"
BURST_COUNT="${COUNT:-120}"
ZERO_TIMEOUT="${ZERO_TIMEOUT:-120}"
LAG_TIMEOUT="${LAG_TIMEOUT:-120}"
SCALEOUT_TIMEOUT="${SCALEOUT_TIMEOUT:-150}"
HANDLER_TIMEOUT="${HANDLER_TIMEOUT:-120}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-240}"
POST_DRAIN_ZERO_TIMEOUT="${POST_DRAIN_ZERO_TIMEOUT:-120}"

OUT="$SCRIPT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

cap() {
  local file="$OUT/$1.txt"; shift
  [[ "$1" == "--" ]] && shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$file"
}

current_replicas() {
  kubectl get deployment cargo-kafka-host -n "$KAFKA_NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo ""
}

describe_group() {
  kubectl exec -i "$CLIENT_POD" -n "$KAFKA_NAMESPACE" -- \
    bin/kafka-consumer-groups.sh --bootstrap-server "$BOOTSTRAP" \
    --describe --group "$CONSUMER_GROUP" 2>/dev/null || true
}

# parse_offsets <describe-output> -> "<current_sum> <logend_sum> <lag_sum>"
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

step "ensure the cluster + Kafka + KEDA + the Deployment are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
PROFILE="$PROFILE" "$KAFKA_DIR/install-strimzi.sh"
kubectl apply -k "$KAFKA_DIR/base"
kubectl wait --for=condition=Ready "kafka/cargo-kafka" -n "$KAFKA_NAMESPACE" --timeout=300s
kubectl wait --for=condition=Ready "kafkatopic/cargo-handling-events" -n "$KAFKA_NAMESPACE" --timeout=120s
PROFILE="$PROFILE" "$SCRIPT_DIR/install-keda.sh"
"$KAFKA_HOST_DIR/build.sh"
docker build -f "$KAFKA_HOST_DIR/Containerfile" -t "$HOST_IMAGE" "$KAFKA_HOST_DIR"
minikube image load "$HOST_IMAGE" -p "$PROFILE"
kubectl apply -k "$KAFKA_HOST_MANIFESTS_DIR/overlays/minikube"
kubectl apply -f "$SCRIPT_DIR/base/kafka-scaledobject.yaml"
kubectl run "$CLIENT_POD" -n "$KAFKA_NAMESPACE" --restart=Never \
  --image="$CLIENT_IMAGE" --command -- sleep 3600 \
  2>/dev/null || echo "capture-keda-kafka-minikube.sh: pod $CLIENT_POD already exists — reusing it"
kubectl wait --for=condition=Ready "pod/$CLIENT_POD" -n "$KAFKA_NAMESPACE" --timeout=120s

echo "=== 20 versions ==="
{
  printf '$ minikube version --short\n'; minikube version --short
  printf '\n$ helm list -n keda --kube-context %s\n' "$PROFILE"
  helm --kube-context "$PROFILE" list -n keda 2>&1 || true
  printf '\n# pinned versions\nStrimzi: 1.3.0 (Kafka 4.3.1)\nKEDA core: 2.21.0\n'
} | tee "$OUT/20-versions.txt"

echo "=== 21 pods ==="
cap 21-pods -- kubectl get pods -n "$KAFKA_NAMESPACE" -o wide

echo "=== 22 deploy-at-zero (idle) ==="
{
  printf '# waiting up to %ss for KEDA to scale cargo-kafka-host to 0/0 while idle\n' "$ZERO_TIMEOUT"
  waited=0; zeroed=0
  while (( waited < ZERO_TIMEOUT )); do
    r="$(current_replicas)"
    printf 't=%ss replicas=%s\n' "$waited" "$r"
    if [[ "$r" == "0" || -z "$r" ]]; then zeroed=1; break; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  printf '\n$ kubectl get deploy cargo-kafka-host -n %s\n' "$KAFKA_NAMESPACE"
  kubectl get deploy cargo-kafka-host -n "$KAFKA_NAMESPACE"
  if [[ "$zeroed" -ne 1 ]]; then
    echo "FAIL — cargo-kafka-host never scaled to 0/0 within ${ZERO_TIMEOUT}s of idle" >&2
    exit 1
  fi
} | tee "$OUT/22-deploy-at-zero.txt"

echo "=== 23 backlog-after-burst ==="
{
  before="$(topic_end_total)"
  printf '# topic %s end offset BEFORE the burst = %s\n' "$TOPIC" "$before"
  printf '\n$ COUNT=%s %s\n' "$BURST_COUNT" "$KAFKA_DIR/producer-burst.sh"
  PROFILE="$PROFILE" COUNT="$BURST_COUNT" "$KAFKA_DIR/producer-burst.sh" 2>&1
  printf '\n# polling for the topic backlog to grow (timeout %ss) — the lag KEDA\n' "$LAG_TIMEOUT"
  printf '# reads with offsetResetPolicy: earliest before the group commits\n'
  waited=0; grew=0
  while (( waited < LAG_TIMEOUT )); do
    after="$(topic_end_total)"
    printf 't=%ss topic-end-offset=%s (was %s)\n' "$waited" "$after" "$before"
    if (( after > before )); then grew=1; break; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  if [[ "$grew" -ne 1 ]]; then
    echo "FAIL — topic backlog did not grow within ${LAG_TIMEOUT}s of the burst" >&2
    exit 1
  fi
} | tee "$OUT/23-backlog-after-burst.txt"

echo "=== 24 deploy-scaled-out ==="
{
  printf '# polling for the peak replica count (timeout %ss, 2s interval so a fast drain cannot hide the peak)\n' "$SCALEOUT_TIMEOUT"
  waited=0; peak=0
  while (( waited < SCALEOUT_TIMEOUT )); do
    r="$(current_replicas)"
    [[ "$r" =~ ^[0-9]+$ ]] || r=0
    if (( r > peak )); then peak=$r; fi
    printf 't=%ss replicas=%s peak=%s\n' "$waited" "$r" "$peak"
    if (( peak > 1 )); then break; fi
    sleep 2; waited=$(( waited + 2 ))
  done
  printf '\n$ kubectl get deploy cargo-kafka-host -n %s\n' "$KAFKA_NAMESPACE"
  kubectl get deploy cargo-kafka-host -n "$KAFKA_NAMESPACE"
  printf '\n$ kubectl get scaledobject cargo-kafka-host -n %s -o wide\n' "$KAFKA_NAMESPACE"
  kubectl get scaledobject cargo-kafka-host -n "$KAFKA_NAMESPACE" -o wide
  if [[ "$peak" -le 1 ]]; then
    echo "FAIL — cargo-kafka-host peak replica count was $peak (expected > 1) within ${SCALEOUT_TIMEOUT}s" >&2
    exit 1
  fi
  echo "peak-replicas: $peak"
} | tee "$OUT/24-deploy-scaled-out.txt"

echo "=== 25 handler-logs ==="
{
  # The host Pods are ephemeral — they drain the burst then KEDA scales them to
  # zero, so their logs vanish. Poll while they are still up (through the drain
  # and the 30s cooldown), re-reading across all current Pods until a
  # per-message `outcome=` line appears.
  printf '$ kubectl logs -l app=cargo-kafka-host -n %s --all-containers --prefix (polled)\n' "$KAFKA_NAMESPACE"
  waited=0; sawhandler=0; handler_logs=""
  while (( waited < HANDLER_TIMEOUT )); do
    handler_logs="$(kubectl logs -l app=cargo-kafka-host -n "$KAFKA_NAMESPACE" --all-containers --prefix --tail=-1 --max-log-requests=10 2>/dev/null || true)"
    if [[ "$handler_logs" == *"outcome="* ]]; then sawhandler=1; break; fi
    sleep 3; waited=$(( waited + 3 ))
  done
  printf '%s\n' "$handler_logs"
  if [[ "$sawhandler" -ne 1 ]]; then
    echo "FAIL — no per-message 'outcome=' log lines found from cargo-kafka-host within ${HANDLER_TIMEOUT}s" >&2
    exit 1
  fi
} | tee "$OUT/25-handler-logs.txt"

echo "=== 26 lag-drained ==="
{
  printf '# polling for lag to drain back to 0 (timeout %ss)\n' "$DRAIN_TIMEOUT"
  waited=0; drained=0
  while (( waited < DRAIN_TIMEOUT )); do
    read -r cur end lag <<<"$(parse_offsets "$(describe_group)")"
    printf 't=%ss current-offset=%s log-end-offset=%s lag=%s\n' "$waited" "$cur" "$end" "$lag"
    if (( lag == 0 )) && (( end > 0 )); then drained=1; break; fi
    sleep 10; waited=$(( waited + 10 ))
  done
  if [[ "$drained" -ne 1 ]]; then
    echo "FAIL — lag never drained to 0 within ${DRAIN_TIMEOUT}s" >&2
    exit 1
  fi
} | tee "$OUT/26-lag-drained.txt"

echo "=== 27 deploy-back-to-zero ==="
{
  printf '# polling for KEDA to scale cargo-kafka-host back to 0/0 after the cooldown (timeout %ss)\n' "$POST_DRAIN_ZERO_TIMEOUT"
  waited=0; rezeroed=0
  while (( waited < POST_DRAIN_ZERO_TIMEOUT )); do
    r="$(current_replicas)"
    printf 't=%ss replicas=%s\n' "$waited" "$r"
    if [[ "$r" == "0" || -z "$r" ]]; then rezeroed=1; break; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  printf '\n$ kubectl get deploy cargo-kafka-host -n %s\n' "$KAFKA_NAMESPACE"
  kubectl get deploy cargo-kafka-host -n "$KAFKA_NAMESPACE"
  if [[ "$rezeroed" -ne 1 ]]; then
    echo "FAIL — cargo-kafka-host never returned to 0/0 within ${POST_DRAIN_ZERO_TIMEOUT}s of the drain" >&2
    exit 1
  fi
} | tee "$OUT/27-deploy-back-to-zero.txt"

echo "=== 28 sha256(kafka-app.wasm) ==="
cap 28-sha256 -- sha256sum "$KAFKA_HOST_DIR/kafka-app.wasm"

echo "=== 29 secret scrub ==="
kubectl delete pod "$CLIENT_POD" -n "$KAFKA_NAMESPACE" --wait=false >/dev/null 2>&1 || true
scrub() {
  python3 -I - "$OUT" <<'PY'
import os, re, sys
root = sys.argv[1]
pats = [
    re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', re.S),
    re.compile(r'(?i)bearer\s+[A-Za-z0-9._\-]{16,}'),
    re.compile(r'(?i)(client-certificate-data|client-key-data|token):\s*\S+'),
]
changed = 0
for name in os.listdir(root):
    p = os.path.join(root, name)
    if not os.path.isfile(p):
        continue
    t = open(p, encoding="utf-8", errors="replace").read()
    o = t
    for pat in pats:
        t = pat.sub("[REDACTED]", t)
    if t != o:
        open(p, "w", encoding="utf-8").write(t)
        changed += 1
print(f"scrub: redacted {changed} file(s)")
PY
}
scrub | tee "$OUT/29-scrub.txt"
if grep -rEl 'BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}|client-key-data: [A-Za-z0-9+/=]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

# peak is set inside the step-24 `| tee` subshell; recover it from that step's
# evidence file for the summary line.
peak="$(awk -F': ' '/^peak-replicas:/ { print $2 }' "$OUT/24-deploy-scaled-out.txt" 2>/dev/null)"
echo
echo "PASS — part5-kubernetes ch23 KEDA Kafka half (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  cargo-kafka-host went 0/0 -> idle -> producer burst -> consumer-group lag"
echo "  rose -> KEDA scaled it out to a peak of ${peak:-?} replica(s) -> the handler"
echo "  processed the burst -> lag drained -> KEDA scaled it back to 0/0."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ../teardown.sh to leave the box clean."
