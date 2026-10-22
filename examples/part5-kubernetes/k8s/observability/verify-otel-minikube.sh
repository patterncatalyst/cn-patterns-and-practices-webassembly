#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/observability/verify-otel-minikube.sh
#
# ch24 — on-cluster observability, minikube path. Builds on top of the Part 5
# minikube example (../verify-minikube.sh): deploys the otel-lgtm OTLP sink,
# points the containerd wasmtime shim at it (enable-shim-otel.sh — this
# RESTARTS containerd, so it runs BEFORE the app is (re)deployed, never after),
# redeploys cargo-http so its Pod gets a freshly-started shim that inherited the
# OTel env, generates real traffic through the ingress edge, then proves a
# trace/metric/log reached each backend by `kubectl exec`-ing INTO the
# otel-lgtm Pod and curling its backends on their LOCALHOST ports — no
# port-forward, no Grafana UI (house rule).
#
# HONEST SCOPE: the shim emits spans about the CONTAINER/TASK lifecycle it
# manages (create/start/exec/delete) — not anything the Wasm guest code itself
# produced. Guest-authored spans (wasi-otel) are an RC-only proposal, not in
# the pinned stable toolchain (wasm32-wasip1 + wasmtime), so there is no
# component-authored telemetry to show here. What this proves is that the
# SUBSTRATE (containerd's shim) is observable, which is the honest state of the
# art for Wasm-on-Kubernetes today.
#
# Usage:
#   ./verify-otel-minikube.sh            # full run; leaves the profile running
#   KUBERNETES_VERSION=v1.37.1 ./verify-otel-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib.sh
source "$K8S_DIR/lib.sh"

for tool in minikube kubectl docker curl; do
  require_cmd "$tool"
done

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-otel-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }
echo "verify-otel-minikube.sh: minikube $mk_ver OK; otel-lgtm 0.33.1; shim $SHIM_VERSION"

step "Step 1: minikube profile '$PROFILE' up (docker driver, containerd, Kubernetes $KUBERNETES_VERSION)"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-otel-minikube.sh: profile '$PROFILE' already running — reusing it"
else
  minikube start -p "$PROFILE" \
    --driver=docker \
    --container-runtime=containerd \
    --kubernetes-version="$KUBERNETES_VERSION"
fi
kubectl get nodes

step "Step 2: the raw-shim RuntimeClass must already be installed"
# This stack is an ADD-ON to the base Part 5 example; it does not duplicate
# ../build.sh / ../install-shim.sh's full idempotent re-install here. If this
# is a brand-new profile, install the shim once first.
if ! kubectl get runtimeclass "$SHIM_HANDLER" >/dev/null 2>&1; then
  echo "verify-otel-minikube.sh: RuntimeClass '$SHIM_HANDLER' missing — installing the shim"
  PROFILE="$PROFILE" "$K8S_DIR/install-shim.sh"
fi

step "Step 3: deploy the otel-lgtm OTLP sink (observability overlay)"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl rollout status deployment/otel-lgtm -n "$NAMESPACE" --timeout=240s
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-lgtm -o wide

step "Step 4: point the containerd shim at otel-lgtm (restarts containerd)"
# MUST happen before the app overlay below — a shim already running when the
# env changes does not pick it up; only a shim started fresh after this
# restart does.
PROFILE="$PROFILE" "$SCRIPT_DIR/enable-shim-otel.sh"

step "Step 4b: ingress-nginx addon"
minikube addons enable ingress -p "$PROFILE"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

step "Step 5: build + load the image, (re)deploy cargo-http so its shim is fresh"
IMAGE="$IMAGE" "$K8S_DIR/../build.sh"
minikube image load "$IMAGE" -p "$PROFILE"
kubectl apply -k "$K8S_DIR/overlays/minikube"
# Force a fresh Pod even if the Deployment spec did not change, so its shim
# process is one that started AFTER the containerd restart above.
kubectl delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=cargo-http --ignore-not-found >/dev/null
kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s
kubectl get pods -n "$NAMESPACE" -o wide

step "Step 6: resolve + patch the Ingress to the live nip.io host"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"

waited=0; ok=0
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "http://$CARGO_HOST$VALID_PATH" 2>/dev/null | grep -qi "part5-cargo-affinity"; then
    ok=1; break
  fi
  sleep 2; waited=$(( waited + 2 ))
done
[[ "$ok" -eq 1 ]] || { echo "verify-otel-minikube.sh: FAIL — ingress never routed Host $CARGO_HOST within 90s" >&2; exit 1; }
wait_for_200 "http://$CARGO_HOST$VALID_PATH" 90

step "Step 7: generate traffic (the signal the shim will emit telemetry about)"
BASE="http://$CARGO_HOST"
for i in 1 2 3 4 5; do
  body="$(curl_body "$BASE$VALID_PATH")"
  assert_eq "$EXPECTED_JSON" "$body" "minikube traffic-gen GET $VALID_PATH (#$i)"
done
code404="$(curl_code "$BASE/cargo/NOPE")"
assert_eq "404" "$code404" "minikube traffic-gen GET /cargo/NOPE"
echo "verify-otel-minikube.sh: generated 5x 200 + 1x 404 through the ingress edge"

step "Step 8: let the shim's batch span exporter flush, then query each backend"
sleep 10

OTEL_POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-lgtm -o jsonpath='{.items[0].metadata.name}')"
assert_contains "otel-lgtm" "$OTEL_POD" "otel-lgtm Pod name resolved"

# urlencode <string> — percent-encode a query value (python3 is already a
# required tool for ../capture-evidence.sh's secret scrub, so it is on PATH).
urlencode() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# http_in_pod <full-url> — GET a URL from inside the otel-lgtm Pod's own
# network namespace via kubectl exec (NOT port-forward). curl-or-wget: the
# image's base OS is not pinned by upstream, so fall back to wget if curl is
# not on its PATH; both support a plain GET to a fully-encoded URL.
http_in_pod() {
  kubectl exec -n "$NAMESPACE" "$OTEL_POD" -- sh -c \
    'if command -v curl >/dev/null 2>&1; then curl -sS "$0"; else wget -qO- "$0"; fi' \
    "$1"
}

echo "--- Tempo: search for a span from service '${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}' ---"
tempo_q="{resource.service.name=\"${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}\"}"
tempo_url="http://127.0.0.1:3200/api/search?q=$(urlencode "$tempo_q")&limit=20"
tempo_json="$(http_in_pod "$tempo_url" || true)"
echo "$tempo_json"
assert_contains '"traceID"' "$tempo_json" "Tempo returned at least one trace"

echo "--- Prometheus: a real metric series for OTLP spans the Collector accepted ---"
prom_url="http://127.0.0.1:9090/api/v1/query?query=$(urlencode 'otelcol_receiver_accepted_spans_total')"
prom_json="$(http_in_pod "$prom_url" || true)"
echo "$prom_json"
assert_contains '"resultType":"vector"' "$prom_json" "Prometheus query returned a vector"
assert_contains '"value":[' "$prom_json" "Prometheus query returned at least one sample"

echo "--- Loki: a real log line (the otel-lgtm stack's OWN internal logs — the"
echo "    shim emits traces only, no logs, so Loki's evidence here is the"
echo "    backend's self-observability, not Wasm-workload telemetry) ---"
now_ns="$(date +%s)000000000"
start_ns="$(( $(date +%s) - 3600 ))000000000"
loki_url="http://127.0.0.1:3100/loki/api/v1/query_range?query=$(urlencode '{job=~".+"}')&start=${start_ns}&end=${now_ns}&limit=5"
loki_json="$(http_in_pod "$loki_url" || true)"
echo "$loki_json"
assert_contains '"values":[' "$loki_json" "Loki query_range returned at least one stream"

echo
echo "PASS — ch24 on-cluster observability (minikube):"
echo "  otel-lgtm (0.33.1) received OTLP from the containerd wasmtime shim"
echo "  ($SHIM_VERSION); a real trace is in Tempo, a real metric series"
echo "  (otelcol_receiver_accepted_spans_total) is in Prometheus, and a real"
echo "  log line is in Loki. These are SHIM/stack-level signals, not"
echo "  guest-authored Wasm telemetry (wasi-otel is RC-only, not pinned here)."
echo "exit 0"
