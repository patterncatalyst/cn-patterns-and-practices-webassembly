#!/usr/bin/env bash
# examples/part7-final-project/capture-evidence.sh
#
# Headless live run of the final project's two-language assembly that
# produces the COMMITTED evidence: ensures the profile, both composites'
# images, the shim, the shared otel-lgtm sink, both app overlays, Istio, and
# the ch25 gateway filter are all up (same idempotent sequence as
# ./verify-minikube.sh), then captures cluster state + the real HTTP/Tempo
# proof, teeing every step to evidence/<YYYY-MM-DD>/NN-*.txt with a secret
# scrub.
#
# Nothing here is faked: every assertion that misses fails the script
# (set -e). Does NOT tear anything down — the profile is shared with Part 5
# and ch25, so leaving it running is the correct default; run
# ../part5-kubernetes/k8s/teardown.sh when the whole box should go away.
#
# Every curl goes through a real edge (ingress-nginx or the Istio gateway's
# NodePort) — no port-forward, no `minikube service` (house rule; the Istio
# gateway's NodePort is the same documented exception ch25 already uses, see
# ./verify-minikube.sh's header comment).
#
# Order:
#   00 versions (minikube, kubectl client+server, shim + SHA, Istio)
#   01 nodes
#   02 runtimeclass (cluster object + the node's containerd runtime registration)
#   03 deploy (both Deployments/Services/Ingress, namespace part7-final-project)
#   04 pods (get + describe: runtimeClassName + scheduled node, both languages)
#   05 http-rust (ingress): exact JSON + 404
#   06 http-go (ingress): exact JSON + 404 + byte-identical-to-rust confirmation
#   07 istio (gateway): 403 without x-cargo-tenant / 200+header with it, both languages
#   08 tempo: one shim trace contributed by each language (bounded trace scope, see ./verify-minikube.sh Step 14)
#   09 sha256(cargo-rust.wasm, cargo-go.wasm)
#   10 secret scrub over the evidence directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PART5_K8S="$(cd "$SCRIPT_DIR/../part5-kubernetes/k8s" && pwd)"
PART6_ISTIO="$(cd "$SCRIPT_DIR/../part6-deviations/istio" && pwd)"
# shellcheck source=../part5-kubernetes/k8s/lib.sh
source "$PART5_K8S/lib.sh"

APP_NS="part7-final-project"
CARGO_PATH="/cargo/CARGO-USNYC-DEHAM"

for tool in minikube kubectl docker curl sha256sum python3; do
  require_cmd "$tool"
done

OUT="$SCRIPT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

# cap NN-name -- cmd...  run a command, tee combined output to the evidence file.
cap() {
  local file="$OUT/$1.txt"; shift
  [[ "$1" == "--" ]] && shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$file"
}

urlencode() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
http_in_otel_pod() {
  local otel_pod="$1" url="$2"
  kubectl exec -n "$NAMESPACE" "$otel_pod" -- sh -c \
    'if command -v curl >/dev/null 2>&1; then curl -sS "$0"; else wget -qO- "$0"; fi' \
    "$url"
}
tempo_trace_count() {
  local otel_pod="$1" svc="$2" q url json
  q="{resource.service.name=\"${svc}\"}"
  url="http://127.0.0.1:3200/api/search?q=$(urlencode "$q")&limit=200"
  json="$(http_in_otel_pod "$otel_pod" "$url" || true)"
  printf '%s' "$json" | grep -o '"traceID"' | wc -l | tr -d ' '
}

step "ensure the cluster + both deploys + Istio + the gateway filter are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
"$SCRIPT_DIR/build.sh" --load
PROFILE="$PROFILE" "$PART5_K8S/install-shim.sh"
minikube addons enable ingress -p "$PROFILE" >/dev/null 2>&1 || true
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
# The reused ch24 otel-lgtm overlay renders into $NAMESPACE (part5-kubernetes);
# create it so a clean profile (no prior Part 5 deploy) has it before the apply.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k "$SCRIPT_DIR/k8s/observability/overlays/minikube"
kubectl rollout status deployment/otel-lgtm -n "$NAMESPACE" --timeout=240s
PROFILE="$PROFILE" "$PART5_K8S/observability/enable-shim-otel.sh"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
kubectl apply -k "$SCRIPT_DIR/k8s/overlays/minikube"
if kubectl get deployment/istiod -n istio-system >/dev/null 2>&1; then
  echo "capture-evidence.sh: istiod already present — reusing the existing Istio control plane"
else
  PROFILE="$PROFILE" "$PART6_ISTIO/istio-install.sh"
fi
kubectl apply -k "$SCRIPT_DIR/istio/overlays/minikube"
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=patterncatalyst \
  --docker-password="$(gh auth token)" \
  -n istio-system \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$SCRIPT_DIR/istio/gateway-wasmplugin.yaml"
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s
# Force-fresh shims, same reasoning as ./verify-minikube.sh Step 9.
kubectl delete pod -n "$APP_NS" -l app.kubernetes.io/name=cargo-rust --ignore-not-found >/dev/null
kubectl delete pod -n "$APP_NS" -l app.kubernetes.io/name=cargo-go --ignore-not-found >/dev/null
kubectl rollout status deployment/cargo-rust -n "$APP_NS" --timeout=180s
kubectl rollout status deployment/cargo-go -n "$APP_NS" --timeout=180s

MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
RUST_HOST="cargo-rust.${MINIKUBE_IP}.nip.io"
GO_HOST="cargo-go.${MINIKUBE_IP}.nip.io"
RUST_ISTIO_HOST="cargo-rust-istio.${MINIKUBE_IP}.nip.io"
GO_ISTIO_HOST="cargo-go-istio.${MINIKUBE_IP}.nip.io"

kubectl patch ingress cargo-final -n "$APP_NS" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$RUST_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/rules/1/host\",\"value\":\"$GO_HOST\"}]"
kubectl patch gateway cargo-final-gateway -n "$APP_NS" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/servers/0/hosts/0\",\"value\":\"$RUST_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/servers/0/hosts/1\",\"value\":\"$GO_ISTIO_HOST\"}]"
kubectl patch virtualservice cargo-final -n "$APP_NS" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/hosts/0\",\"value\":\"$RUST_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/hosts/1\",\"value\":\"$GO_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/http/0/match/0/authority/exact\",\"value\":\"$RUST_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/http/1/match/0/authority/exact\",\"value\":\"$GO_ISTIO_HOST\"}]"

waited=0; ok_rust=0; ok_go=0
while (( waited < 90 )); do
  [[ "$ok_rust" -eq 0 ]] && curl -sS -D - -o /dev/null "http://$RUST_HOST$CARGO_PATH" 2>/dev/null | grep -qi "part7-cargo-affinity" && ok_rust=1
  [[ "$ok_go" -eq 0 ]] && curl -sS -D - -o /dev/null "http://$GO_HOST$CARGO_PATH" 2>/dev/null | grep -qi "part7-cargo-affinity" && ok_go=1
  [[ "$ok_rust" -eq 1 && "$ok_go" -eq 1 ]] && break
  sleep 2; waited=$(( waited + 2 ))
done
[[ "$ok_rust" -eq 1 && "$ok_go" -eq 1 ]] || { echo "capture-evidence.sh: FAIL — ingress never routed both hosts (rust=$ok_rust go=$ok_go)" >&2; exit 1; }
wait_for_200 "http://$RUST_HOST$CARGO_PATH" 90
wait_for_200 "http://$GO_HOST$CARGO_PATH" 90

NODE_PORT="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
[[ -n "$NODE_PORT" ]] || { echo "capture-evidence.sh: FAIL — istio-ingressgateway has no NodePort for 'http2'" >&2; exit 1; }
ISTIO_URL="http://${MINIKUBE_IP}:${NODE_PORT}${CARGO_PATH}"
waited=0; code=""
while (( waited < 150 )); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $RUST_ISTIO_HOST" -H 'x-cargo-tenant: acme' "$ISTIO_URL" || true)"
  [[ "$code" == "200" ]] && break
  sleep 3; waited=$(( waited + 3 ))
done
[[ "$code" == "200" ]] || { echo "capture-evidence.sh: FAIL — istio route+filter not ready for cargo-rust within ${waited}s" >&2; exit 1; }
waited=0; code=""
while (( waited < 150 )); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $GO_ISTIO_HOST" -H 'x-cargo-tenant: acme' "$ISTIO_URL" || true)"
  [[ "$code" == "200" ]] && break
  sleep 3; waited=$(( waited + 3 ))
done
[[ "$code" == "200" ]] || { echo "capture-evidence.sh: FAIL — istio route+filter not ready for cargo-go within ${waited}s" >&2; exit 1; }

echo "=== 00 versions ==="
{
  printf '$ minikube version --short\n'; minikube version --short
  printf '\n$ kubectl --context %s version\n' "$PROFILE"; kubectl version 2>&1 || true
  printf '\n$ istioctl version --remote=false --short\n'; istioctl version --remote=false --short 2>&1 || true
  printf '\n# runwasi containerd-shim-wasmtime (pinned)\n'
  printf 'shim version: %s\n' "$SHIM_VERSION"
  printf 'shim tarball: %s\n' "$SHIM_TARBALL"
  printf 'shim sha256 : %s\n' "$SHIM_SHA256"
  printf '\n$ minikube ssh -- containerd --version ; shim binary on node\n'
  minikube ssh -p "$PROFILE" -- 'containerd --version; ls -l /usr/bin/containerd-shim-wasmtime-v1' 2>&1 | grep -av '^\[?'
} | tee "$OUT/00-versions.txt"

echo "=== 01 nodes ==="
cap 01-nodes -- kubectl get nodes -o wide

echo "=== 02 runtimeclass ==="
{
  printf '$ kubectl get runtimeclass wasmtime -o yaml\n'
  kubectl get runtimeclass "$SHIM_HANDLER" -o yaml
  printf '\n# containerd runtime registration on the node (config.toml)\n'
  minikube ssh -p "$PROFILE" -- 'grep -A1 "runtimes.wasmtime" /etc/containerd/config.toml' 2>&1 | grep -av '^\[?'
} | tee "$OUT/02-runtimeclass.txt"

echo "=== 03 deploy (both Deployments/Services/Ingress + Istio Gateway/VirtualService) ==="
{
  printf '$ kubectl get deploy,svc,ingress -n %s -o wide\n' "$APP_NS"
  kubectl get deploy,svc,ingress -n "$APP_NS" -o wide
  printf '\n$ kubectl get gateway,virtualservice -n %s\n' "$APP_NS"
  kubectl get gateway,virtualservice -n "$APP_NS"
  printf '\n$ kubectl get wasmplugin -n istio-system\n'
  kubectl get wasmplugin -n istio-system
  printf '\n# runtimeClassName on each Deployment:\n'
  for d in cargo-rust cargo-go; do
    printf '$ kubectl get deploy %s -n %s -o jsonpath={.spec.template.spec.runtimeClassName}\n' "$d" "$APP_NS"
    kubectl get deploy "$d" -n "$APP_NS" -o jsonpath='{.spec.template.spec.runtimeClassName}'; printf '\n'
  done
} | tee "$OUT/03-deploy.txt"

echo "=== 04 pods (get + describe, both languages) ==="
{
  printf '$ kubectl get pods -n %s -o wide\n' "$APP_NS"
  kubectl get pods -n "$APP_NS" -o wide
  for app in cargo-rust cargo-go; do
    printf '\n$ kubectl describe pod -l app.kubernetes.io/name=%s -n %s\n' "$app" "$APP_NS"
    kubectl describe pod -l "app.kubernetes.io/name=$app" -n "$APP_NS" | grep -Ei 'Name:|Node:|Runtime Class Name:|Status:|Image:|Started|Ready' | head -20
  done
} | tee "$OUT/04-pods.txt"

echo "=== 05 http-rust (ingress) ==="
{
  printf '# request path: host -> ingress-nginx -> Service cargo-rust:8080 -> Pod -> shim -> cargo-rust.wasm\n'
  printf '$ curl -s http://%s%s\n' "$RUST_HOST" "$CARGO_PATH"
  rust_body="$(curl_body "http://$RUST_HOST$CARGO_PATH")"
  printf '%s\n' "$rust_body"
  printf '$ curl -s -o /dev/null -w %%{http_code} http://%s/cargo/NOPE\n' "$RUST_HOST"
  rust_404="$(curl_code "http://$RUST_HOST/cargo/NOPE")"
  printf '%s\n' "$rust_404"
} | tee "$OUT/05-http-rust.txt"
rust_body="$(curl_body "http://$RUST_HOST$CARGO_PATH")"
assert_eq "$EXPECTED_JSON" "$rust_body" "minikube GET $CARGO_PATH through ingress (cargo-rust)"
rust_404="$(curl_code "http://$RUST_HOST/cargo/NOPE")"
assert_eq "404" "$rust_404" "minikube GET /cargo/NOPE through ingress (cargo-rust)"

echo "=== 06 http-go (ingress) + byte-identical-to-rust confirmation ==="
{
  printf '# request path: host -> ingress-nginx -> Service cargo-go:8080 -> Pod -> shim -> cargo-go.wasm\n'
  printf '$ curl -s http://%s%s\n' "$GO_HOST" "$CARGO_PATH"
  go_body="$(curl_body "http://$GO_HOST$CARGO_PATH")"
  printf '%s\n' "$go_body"
  printf '$ curl -s -o /dev/null -w %%{http_code} http://%s/cargo/NOPE\n' "$GO_HOST"
  go_404="$(curl_code "http://$GO_HOST/cargo/NOPE")"
  printf '%s\n' "$go_404"
  printf '\n# two-language-one-contract proof: cargo-rust body == cargo-go body?\n'
  if [[ "$rust_body" == "$go_body" ]]; then
    printf 'byte-identical: YES\n'
  else
    printf 'byte-identical: NO\n'
  fi
} | tee "$OUT/06-http-go.txt"
go_body="$(curl_body "http://$GO_HOST$CARGO_PATH")"
assert_eq "$EXPECTED_JSON" "$go_body" "minikube GET $CARGO_PATH through ingress (cargo-go)"
go_404="$(curl_code "http://$GO_HOST/cargo/NOPE")"
assert_eq "404" "$go_404" "minikube GET /cargo/NOPE through ingress (cargo-go)"
assert_eq "$rust_body" "$go_body" "cargo-rust and cargo-go responses are byte-identical"

echo "=== 07 istio (gateway): x-cargo-tenant contract, both languages ==="
{
  for pair in "cargo-rust:$RUST_ISTIO_HOST" "cargo-go:$GO_ISTIO_HOST"; do
    label="${pair%%:*}"; host="${pair#*:}"
    printf '\n--- %s, WITHOUT x-cargo-tenant ---\n' "$label"
    printf '$ curl -s -o /dev/null -w %%{http_code} -H "Host: %s" %s\n' "$host" "$ISTIO_URL"
    code_without="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $host" "$ISTIO_URL")"
    printf '%s\n' "$code_without"
    assert_eq "403" "$code_without" "minikube GET $CARGO_PATH (no x-cargo-tenant) through istio gateway ($label)"

    printf '\n--- %s, WITH x-cargo-tenant: acme ---\n' "$label"
    printf '$ curl -sS -D - -H "Host: %s" -H "x-cargo-tenant: acme" %s\n' "$host" "$ISTIO_URL"
    tmp_body="$(mktemp -t istio-evidence-body.XXXXXX)"
    headers="$(curl -sS -D - -o "$tmp_body" --max-time 8 -H "Host: $host" -H 'x-cargo-tenant: acme' "$ISTIO_URL")"
    printf '%s\n' "$headers"
    printf '%s\n' "$(cat "$tmp_body")"
    echo "$headers" | grep -qi '^HTTP/.* 200' || { echo "capture-evidence.sh: FAIL — expected 200 with x-cargo-tenant ($label)" >&2; exit 1; }
    echo "$headers" | grep -qi '^x-cargo-filtered-by: *cargo-wasmfilter' || { echo "capture-evidence.sh: FAIL — missing x-cargo-filtered-by header ($label)" >&2; exit 1; }
    assert_eq "$EXPECTED_JSON" "$(cat "$tmp_body")" "minikube GET $CARGO_PATH (x-cargo-tenant: acme) through istio gateway ($label)"
    rm -f "$tmp_body"
  done
} | tee "$OUT/07-istio.txt"

echo "=== 08 tempo: one shim trace contributed by each language ==="
{
  printf '# TRACE SCOPE: OTEL_SERVICE_NAME is a node-level containerd.service\n'
  printf '# systemd Environment=, inherited identically by every shim process on the\n'
  printf '# node, so cargo-rust and cargo-go cannot be told apart by service.name in\n'
  printf '# Tempo. This proves a NEW shim-emitted trace following EACH language'\''s\n'
  printf '# traffic (a before/after count), not a per-service label. See\n'
  printf '# ./verify-minikube.sh Step 14 for the full rationale.\n\n'
  sleep 5
  OTEL_POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-lgtm -o jsonpath='{.items[0].metadata.name}')"
  printf 'otel-lgtm Pod: %s\n' "$OTEL_POD"
  SHIM_SVC="${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}"

  baseline_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
  printf 'Tempo trace count for "%s" before this step'\''s traffic = %s\n' "$SHIM_SVC" "$baseline_count"

  printf '\n$ curl (cargo-rust only, x3)\n'
  for i in 1 2 3; do curl_body "http://$RUST_HOST$CARGO_PATH" >/dev/null; done
  sleep 10
  after_rust_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
  printf 'Tempo trace count after cargo-rust traffic = %s\n' "$after_rust_count"
  if (( after_rust_count <= baseline_count )); then
    echo "capture-evidence.sh: FAIL — no new shim trace appeared after cargo-rust traffic" >&2
    exit 1
  fi

  printf '\n$ curl (cargo-go only, x3)\n'
  for i in 1 2 3; do curl_body "http://$GO_HOST$CARGO_PATH" >/dev/null; done
  sleep 10
  after_go_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
  printf 'Tempo trace count after cargo-go traffic = %s\n' "$after_go_count"
  if (( after_go_count <= after_rust_count )); then
    echo "capture-evidence.sh: FAIL — no new shim trace appeared after cargo-go traffic" >&2
    exit 1
  fi
  printf '\nresult: cargo-rust contributed >=1 new trace (%s -> %s); cargo-go contributed >=1 further new trace (%s -> %s)\n' \
    "$baseline_count" "$after_rust_count" "$after_rust_count" "$after_go_count"
} | tee "$OUT/08-tempo.txt"

echo "=== 09 sha256 (both composites) ==="
cap 09-sha256 -- sha256sum "$SCRIPT_DIR/cargo-rust.wasm" "$SCRIPT_DIR/cargo-go.wasm"

echo "=== 10 secret scrub ==="
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
scrub | tee "$OUT/10-scrub.txt"
if grep -rEl 'BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}|client-key-data: [A-Za-z0-9+/=]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

echo
echo "PASS — part7-final-project (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  cargo-rust.wasm and cargo-go.wasm both run as Wasm Pods via the"
echo "  containerd wasmtime shim and answer byte-identical cargo JSON through"
echo "  ingress-nginx; the ch25 proxy-wasm filter in the shared"
echo "  istio-ingressgateway enforces the x-cargo-tenant contract for both"
echo "  languages; and each language's shim independently contributed a new"
echo "  trace to the shared otel-lgtm sink's Tempo backend."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
