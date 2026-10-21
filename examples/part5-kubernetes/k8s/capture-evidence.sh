#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/capture-evidence.sh
#
# Headless live run of the Part 5 minikube example that produces the COMMITTED
# evidence. Self-contained and idempotent: it ensures the profile is up, the
# ingress addon is on, the image is built+loaded, the shim+RuntimeClass are
# installed, the overlay is applied and rolled out, and the Ingress host is
# patched to the live nip.io name — then it captures the cluster state and the
# real HTTP proof, teeing every step to evidence/<YYYY-MM-DD>/NN-*.txt with a
# secret scrub.
#
# Nothing here is faked: every assertion that misses fails the script (set -e).
# It does NOT tear the cluster down — run ./teardown.sh afterwards to leave the
# box clean.
#
# The curl goes through the REAL ingress edge (host -> ingress-nginx -> Service
# -> Pod -> shim -> component). No port-forward, no NodePort, no
# `minikube service` (house rule).
#
# Order:
#   00 versions (minikube, kubectl client+server, containerd, shim + SHA)
#   01 nodes
#   02 runtimeclass (cluster object + the node's containerd runtime registration)
#   03 deploy (Deployment showing runtimeClassName, Service, Ingress)
#   04 pods (get + describe: runtimeClassName + scheduled node)
#   05 http through the ingress: exact JSON + 404
#   06 sha256(app.wasm) — same bytes as Parts 2/3/4
#   07 secret scrub over the evidence directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

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

step "ensure the cluster + deploy are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
# Build + load the image, then install the shim — which restarts containerd —
# BEFORE enabling the ingress addon. Restarting containerd bounces every Pod on
# the node, so the ingress-nginx controller is brought up AFTER the restart to
# avoid racing a mid-restart controller when we later wait for it to route.
IMAGE="$IMAGE" "$PART5_DIR/build.sh"
minikube image load "$IMAGE" -p "$PROFILE"
PROFILE="$PROFILE" "$SCRIPT_DIR/install-shim.sh"
minikube addons enable ingress -p "$PROFILE" >/dev/null 2>&1 || true
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s
# Belt-and-suspenders: if anything bounced the ingress controller, wait again
# before trusting it to route.
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
BASE="http://$CARGO_HOST"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"
# Wait until our Ingress rule is actually routing (affinity cookie), then a real 200.
waited=0; ok=0
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "$BASE$VALID_PATH" 2>/dev/null | grep -qi "part5-cargo-affinity"; then ok=1; break; fi
  sleep 2; waited=$(( waited + 2 ))
done
[[ "$ok" -eq 1 ]] || { echo "capture-evidence.sh: FAIL — ingress never routed $CARGO_HOST" >&2; exit 1; }
wait_for_200 "$BASE$VALID_PATH" 90

echo "=== 00 versions ==="
{
  printf '$ minikube version --short\n'; minikube version --short
  printf '\n$ kubectl --context %s version\n' "$PROFILE"; kubectl version 2>&1 || true
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

echo "=== 03 deploy (Deployment/Service/Ingress) ==="
{
  printf '$ kubectl get deploy,svc,ingress -n %s -o wide\n' "$NAMESPACE"
  kubectl get deploy,svc,ingress -n "$NAMESPACE" -o wide
  printf '\n# the runtimeClassName that routes this Pod to the Wasm shim:\n'
  printf '$ kubectl get deploy cargo-http -n %s -o jsonpath={.spec.template.spec.runtimeClassName}\n' "$NAMESPACE"
  kubectl get deploy cargo-http -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.runtimeClassName}'; printf '\n'
} | tee "$OUT/03-deploy.txt"

echo "=== 04 pods (get + describe) ==="
{
  printf '$ kubectl get pods -n %s -o wide\n' "$NAMESPACE"
  kubectl get pods -n "$NAMESPACE" -o wide
  printf '\n$ kubectl describe pod (RuntimeClass + node)\n'
  kubectl describe pod -l app.kubernetes.io/name=cargo-http -n "$NAMESPACE" | grep -Ei 'Name:|Node:|Runtime Class Name:|Status:|Image:|Started|Ready' | head -20
} | tee "$OUT/04-pods.txt"

echo "=== 05 http through the ingress edge ==="
{
  printf '# request path: host -> ingress-nginx -> Service cargo-http:8080 -> Pod -> shim -> app.wasm\n'
  printf '$ curl -s %s%s\n' "$BASE" "$VALID_PATH"
  body="$(curl_body "$BASE$VALID_PATH")"
  printf '%s\n' "$body"
  printf '$ curl -s -o /dev/null -w %%{http_code} %s/cargo/NOPE\n' "$BASE"
  code404="$(curl_code "$BASE/cargo/NOPE")"
  printf '%s\n' "$code404"
} | tee "$OUT/05-http.txt"
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "minikube GET $VALID_PATH through ingress"
code404="$(curl_code "$BASE/cargo/NOPE")"
assert_eq "404" "$code404" "minikube GET /cargo/NOPE through ingress"

echo "=== 06 sha256 (same bytes as Parts 2/3/4) ==="
cap 06-sha256 -- sha256sum "$APP_WASM"

echo "=== 07 secret scrub ==="
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
scrub | tee "$OUT/07-scrub.txt"
if grep -rEl 'BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}|client-key-data: [A-Za-z0-9+/=]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

echo
echo "PASS — part5-kubernetes (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  the cargo wasi:http component runs as a Wasm Pod via the containerd"
echo "  wasmtime shim (RuntimeClass '$SHIM_HANDLER'); GET $VALID_PATH through"
echo "  ingress-nginx returned the exact cargo JSON and /cargo/NOPE returned 404."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ./teardown.sh to leave the box clean."
