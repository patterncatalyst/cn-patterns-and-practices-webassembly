#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/observability/capture-otel-evidence.sh
#
# Headless live run that produces the COMMITTED ch24 minikube evidence.
# Self-contained and idempotent, same shape as ../capture-evidence.sh: ensures
# the stack is up (cargo-http + otel-lgtm + the shim pointed at it), generates
# traffic, then captures the real HTTP proof from each backend — tee'd to
# evidence/<YYYY-MM-DD>/NN-*.txt with a secret scrub.
#
# Every query goes through `kubectl exec` into the otel-lgtm Pod's OWN network
# namespace and hits its backends on localhost — NO port-forward, NO Grafana UI.
#
# Order:
#   00 versions (otel-lgtm image tag, shim version, the containerd drop-in env)
#   01 observability deploy (Deployment/Service/Pods)
#   02 traffic generated through the ingress edge
#   03 Tempo: a real trace/span
#   04 Prometheus: a real metric series
#   05 Loki: a real log line
#   06 secret scrub over the evidence directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib.sh
source "$K8S_DIR/lib.sh"

for tool in minikube kubectl docker curl sha256sum python3; do
  require_cmd "$tool"
done

OUT="$SCRIPT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

cap() {
  local file="$OUT/$1.txt"; shift
  [[ "$1" == "--" ]] && shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$file"
}

step "ensure the cluster + observability stack are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
if ! kubectl get runtimeclass "$SHIM_HANDLER" >/dev/null 2>&1; then
  PROFILE="$PROFILE" "$K8S_DIR/install-shim.sh"
fi
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl rollout status deployment/otel-lgtm -n "$NAMESPACE" --timeout=240s
PROFILE="$PROFILE" "$SCRIPT_DIR/enable-shim-otel.sh"
minikube addons enable ingress -p "$PROFILE" >/dev/null 2>&1 || true
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
IMAGE="$IMAGE" "$K8S_DIR/../build.sh"
minikube image load "$IMAGE" -p "$PROFILE"
kubectl apply -k "$K8S_DIR/overlays/minikube"
# Fresh Pod -> fresh shim process -> the shim inherits the OTel env that was
# just set on containerd above (an already-running shim would not).
kubectl delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=cargo-http --ignore-not-found >/dev/null
kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
BASE="http://$CARGO_HOST"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"
waited=0; ok=0
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "$BASE$VALID_PATH" 2>/dev/null | grep -qi "part5-cargo-affinity"; then ok=1; break; fi
  sleep 2; waited=$(( waited + 2 ))
done
[[ "$ok" -eq 1 ]] || { echo "capture-otel-evidence.sh: FAIL — ingress never routed $CARGO_HOST" >&2; exit 1; }
wait_for_200 "$BASE$VALID_PATH" 90

echo "=== 00 versions ==="
{
  printf '# ch24 on-cluster observability — minikube backend\n'
  printf 'otel-lgtm image : grafana/otel-lgtm:0.33.1\n'
  printf 'shim version    : %s (OTel traces on by default since v0.5.0)\n' "$SHIM_VERSION"
  printf '\n$ minikube ssh -- cat /etc/systemd/system/containerd.service.d/10-otel.conf\n'
  minikube ssh -p "$PROFILE" -- 'cat /etc/systemd/system/containerd.service.d/10-otel.conf' 2>&1 | grep -av '^\[?'
  printf '\n$ minikube ssh -- systemctl show containerd --property=Environment\n'
  minikube ssh -p "$PROFILE" -- 'systemctl show containerd --property=Environment' 2>&1 | grep -av '^\[?'
} | tee "$OUT/00-versions.txt"

echo "=== 01 observability deploy ==="
{
  printf '$ kubectl get deploy,svc,pods -n %s -l app.kubernetes.io/name=otel-lgtm -o wide\n' "$NAMESPACE"
  kubectl get deploy,svc,pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-lgtm -o wide
} | tee "$OUT/01-deploy.txt"

echo "=== 02 traffic through the ingress edge ==="
{
  printf '# request path: host -> ingress-nginx -> Service cargo-http:8080 -> Pod -> shim -> app.wasm\n'
  for i in 1 2 3 4 5; do
    printf '$ curl -s %s%s\n' "$BASE" "$VALID_PATH"
    curl_body "$BASE$VALID_PATH"; printf '\n'
  done
  printf '$ curl -s -o /dev/null -w %%{http_code} %s/cargo/NOPE\n' "$BASE"
  curl_code "$BASE/cargo/NOPE"; printf '\n'
} | tee "$OUT/02-traffic.txt"
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "minikube traffic-gen GET $VALID_PATH"

step "let the batch span exporter flush"
sleep 10

OTEL_POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-lgtm -o jsonpath='{.items[0].metadata.name}')"
assert_contains "otel-lgtm" "$OTEL_POD" "otel-lgtm Pod name resolved"
urlencode() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
http_in_pod() {
  kubectl exec -n "$NAMESPACE" "$OTEL_POD" -- sh -c \
    'if command -v curl >/dev/null 2>&1; then curl -sS "$0"; else wget -qO- "$0"; fi' \
    "$1"
}

echo "=== 03 Tempo: a real trace/span (shim-level, not guest-authored) ==="
tempo_q="{resource.service.name=\"${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}\"}"
tempo_url="http://127.0.0.1:3200/api/search?q=$(urlencode "$tempo_q")&limit=20"
{
  printf '# exec into otel-lgtm Pod, GET %s (NOT port-forward)\n' "$tempo_url"
  http_in_pod "$tempo_url" || true
  printf '\n'
} | tee "$OUT/03-tempo.txt"
grep -q '"traceID"' "$OUT/03-tempo.txt" || { echo "capture-otel-evidence.sh: FAIL — no trace in Tempo" >&2; exit 1; }

echo "=== 04 Prometheus: a real metric series ==="
prom_url="http://127.0.0.1:9090/api/v1/query?query=$(urlencode 'otelcol_receiver_accepted_spans_total')"
{
  printf '# exec into otel-lgtm Pod, GET %s (NOT port-forward)\n' "$prom_url"
  http_in_pod "$prom_url" || true
  printf '\n'
} | tee "$OUT/04-prometheus.txt"
grep -q '"resultType":"vector"' "$OUT/04-prometheus.txt" || { echo "capture-otel-evidence.sh: FAIL — Prometheus query did not return a vector" >&2; exit 1; }
grep -q '"value":\[' "$OUT/04-prometheus.txt" || { echo "capture-otel-evidence.sh: FAIL — Prometheus series is empty" >&2; exit 1; }

echo "=== 05 Loki: a real log line (the backend's OWN logs — the shim emits"
echo "    traces only, no logs; this is substrate self-observability, not"
echo "    Wasm-workload telemetry) ==="
now_ns="$(date +%s)000000000"
start_ns="$(( $(date +%s) - 3600 ))000000000"
loki_url="http://127.0.0.1:3100/loki/api/v1/query_range?query=$(urlencode '{job=~".+"}')&start=${start_ns}&end=${now_ns}&limit=5"
{
  printf '# exec into otel-lgtm Pod, GET %s (NOT port-forward)\n' "$loki_url"
  http_in_pod "$loki_url" || true
  printf '\n'
} | tee "$OUT/05-loki.txt"
grep -q '"values":\[' "$OUT/05-loki.txt" || { echo "capture-otel-evidence.sh: FAIL — no log stream in Loki" >&2; exit 1; }

echo "=== 06 secret scrub ==="
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
scrub | tee "$OUT/06-scrub.txt"
if grep -rEl 'BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}|client-key-data: [A-Za-z0-9+/=]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

echo
echo "PASS — ch24 on-cluster observability (minikube):"
echo "  containerd-shim-wasmtime ($SHIM_VERSION) exported OTLP to otel-lgtm"
echo "  (0.33.1); a real trace landed in Tempo, a real metric series"
echo "  (otelcol_receiver_accepted_spans_total) landed in Prometheus, a real"
echo "  log line landed in Loki — all read via kubectl exec, no port-forward."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
