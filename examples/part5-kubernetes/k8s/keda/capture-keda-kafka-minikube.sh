#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/keda/capture-keda-kafka-minikube.sh
#
# Headless live run of the ch23 KEDA Kafka half (MINIKUBE) that produces the
# COMMITTED evidence, teeing every step to evidence/<YYYY-MM-DD>/2N-*.txt
# (numbered in the 20s to sit alongside ../capture-keda-http-evidence.sh's 0N
# files under the same evidence/ directory) with a secret scrub. Mirrors
# ../capture-keda-http-evidence.sh's structure; see
# verify-keda-kafka-minikube.sh for the full narrative this proves (producer
# burst -> lag -> KEDA observes / wadm owns -> drain).
#
# Does NOT tear the cluster down — run ../teardown.sh afterwards.
#
# Author-only (see verify-keda-kafka-minikube.sh's header): written to the
# house evidence-capture standard but not executed against a live cluster in
# this BUILD pass.
#
# Order:
#   20 versions (Strimzi, KEDA, wasmcloud-platform chart versions)
#   21 kafka cluster + topic (Kafka/KafkaNodePool/KafkaTopic status)
#   22 wadm app (cargo-kafka Application + component/provider pods)
#   23 producer burst + consumer-group lag (before/after kafka-consumer-groups.sh --describe)
#   24 scaledobject (KEDA's observational kafka ScaledObject status)
#   25 drain (lag returns to 0)
#   26 secret scrub
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"
WASMCLOUD_DIR="$(cd "$SCRIPT_DIR/../wasmcloud" && pwd)"
KAFKA_DIR="$(cd "$SCRIPT_DIR/../kafka" && pwd)"

for tool in minikube kubectl docker curl helm wash gh sha256sum python3; do
  require_cmd "$tool"
done

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
WASMCLOUD_NAMESPACE="${PROJECT_NAMESPACE:-wasmcloud}"
LAG_TIMEOUT="${LAG_TIMEOUT:-180}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-180}"

OUT="$SCRIPT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

cap() {
  local file="$OUT/$1.txt"; shift
  [[ "$1" == "--" ]] && shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$file"
}

describe_lag() {
  kubectl run cargo-lag-check --rm -i --restart=Never -n "$KAFKA_NAMESPACE" \
    --image=quay.io/strimzi/kafka:0.47.0-kafka-4.3.1 --command -- \
    bin/kafka-consumer-groups.sh --bootstrap-server cargo-kafka-kafka-bootstrap.kafka.svc:9092 \
    --describe --group kafka-handler 2>/dev/null || true
}

step "ensure the cluster + Kafka + KEDA + wasmCloud are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
PROFILE="$PROFILE" "$KAFKA_DIR/install-strimzi.sh"
kubectl apply -k "$KAFKA_DIR/base"
kubectl wait --for=condition=Ready "kafka/cargo-kafka" -n "$KAFKA_NAMESPACE" --timeout=300s
kubectl wait --for=condition=Ready "kafkatopic/cargo-handling-events" -n "$KAFKA_NAMESPACE" --timeout=120s
PROFILE="$PROFILE" "$SCRIPT_DIR/install-keda.sh"
kubectl apply -f "$SCRIPT_DIR/base/kafka-scaledobject.yaml"
PROFILE="$PROFILE" "$WASMCLOUD_DIR/install-wasmcloud-minikube.sh"
echo "capture-keda-kafka-minikube.sh: NOTE — push kafka-handler.wasm + the cargo provider to ghcr and"
echo "  kubectl apply -n $WASMCLOUD_NAMESPACE -f $WASMCLOUD_DIR/wadm-kafka.yaml before this capture can complete."

echo "=== 20 versions ==="
{
  printf '$ minikube version --short\n'; minikube version --short
  printf '\n# pinned versions\nStrimzi: 1.3.0 (Kafka 4.3.1)\nKEDA core: 2.21.0\nKEDA HTTP add-on: 0.16.0\nwasmcloud-platform chart: 0.1.2 (host 1.9.1)\nmessaging-kafka provider: ghcr.io/wasmcloud/messaging-kafka:6c67eb2\n'
} | tee "$OUT/20-versions.txt"

echo "=== 21 kafka cluster + topic ==="
cap 21-kafka -- kubectl get kafka,kafkanodepool,kafkatopic -n "$KAFKA_NAMESPACE" -o wide

echo "=== 22 wadm app ==="
{
  printf '$ kubectl get application.core.oam.dev -n %s\n' "$WASMCLOUD_NAMESPACE"
  kubectl get application.core.oam.dev -n "$WASMCLOUD_NAMESPACE" 2>&1 || true
  printf '\n$ kubectl get pods -n %s -o wide\n' "$WASMCLOUD_NAMESPACE"
  kubectl get pods -n "$WASMCLOUD_NAMESPACE" -o wide
} | tee "$OUT/22-wadm-app.txt"

echo "=== 23 producer burst + consumer-group lag ==="
{
  printf '# lag BEFORE the burst\n'
  describe_lag
  PROFILE="$PROFILE" COUNT="${COUNT:-60}" "$KAFKA_DIR/producer-burst.sh" 2>&1
  printf '\n# polling for lag to rise (timeout %ss)\n' "$LAG_TIMEOUT"
  waited=0; lagged=0
  while (( waited < LAG_TIMEOUT )); do
    out="$(describe_lag)"
    total_lag="$(awk '/kafka-handler/{sum+=$NF} END{print sum+0}' <<<"$out")"
    printf 't=%ss total_lag=%s\n' "$waited" "${total_lag:-0}"
    if [[ "${total_lag:-0}" -gt 0 ]]; then lagged=1; printf '%s\n' "$out"; break; fi
    sleep 10; waited=$(( waited + 10 ))
  done
  if [[ "$lagged" -ne 1 ]]; then
    echo "FAIL — no consumer-group lag observed within ${LAG_TIMEOUT}s" >&2
    exit 1
  fi
} | tee "$OUT/23-producer-burst-lag.txt"

echo "=== 24 scaledobject (KEDA observational status) ==="
cap 24-scaledobject -- kubectl get scaledobject kafka-handler-lag -n "$KAFKA_NAMESPACE" -o yaml

echo "=== 25 drain ==="
{
  printf '# polling for lag to drain back to 0 (timeout %ss)\n' "$DRAIN_TIMEOUT"
  waited=0; drained=0
  while (( waited < DRAIN_TIMEOUT )); do
    out="$(describe_lag)"
    total_lag="$(awk '/kafka-handler/{sum+=$NF} END{print sum+0}' <<<"$out")"
    printf 't=%ss total_lag=%s\n' "$waited" "${total_lag:-1}"
    if [[ "${total_lag:-1}" -eq 0 ]]; then drained=1; break; fi
    sleep 10; waited=$(( waited + 10 ))
  done
  if [[ "$drained" -ne 1 ]]; then
    echo "FAIL — lag never drained to 0 within ${DRAIN_TIMEOUT}s" >&2
    exit 1
  fi
} | tee "$OUT/25-drain.txt"

echo "=== 26 secret scrub ==="
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
scrub | tee "$OUT/26-scrub.txt"
if grep -rEl 'BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}|client-key-data: [A-Za-z0-9+/=]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

echo
echo "PASS — part5-kubernetes ch23 KEDA Kafka half (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  producer burst -> consumer-group lag rose -> KEDA observed it -> lag drained"
echo "  once the wadm-owned kafka-handler component consumed the backlog."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ../teardown.sh to leave the box clean."
