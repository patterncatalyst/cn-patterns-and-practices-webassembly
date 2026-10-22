#!/usr/bin/env bash
# examples/part6-deviations/spinkube/capture-evidence.sh
#
# Headless live run of the ch26 SpinKube minikube example that produces the
# COMMITTED evidence. Self-contained and idempotent: ensures the profile is
# up, builds + pushes the Spin OCI artifact, installs the full SpinKube stack,
# enables the ingress addon, applies the overlay and rolls it out, patches the
# Ingress host to the live nip.io name — then captures cluster state and the
# real HTTP proof, teeing every step to evidence/<YYYY-MM-DD>/NN-*.txt with a
# secret scrub.
#
# Nothing here is faked: every assertion that misses fails the script (set -e).
# It does NOT tear the cluster down — run ./teardown.sh afterwards.
#
# The curl goes through the REAL ingress edge (host -> ingress-nginx -> Service
# -> Pod -> shim -> component). No port-forward, no NodePort, no
# `minikube service` (house rule).
#
# Order:
#   00 versions (minikube, kubectl client+server, cert-manager, runtime-class-
#      manager, containerd-shim-spin + manifest URL, spin-operator)
#   01 nodes
#   02 runtimeclass (cluster object + the Shim CR)
#   03 spinapp + deploy/svc/ingress (SpinApp spec, the operator-created
#      Deployment/Service, the Ingress)
#   04 pods (get + describe: runtimeClassName + scheduled node)
#   05 http through the ingress: exact JSON + 404
#   06 sha256(cargo-spin.wasm)
#   07 secret scrub over the evidence directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

for tool in minikube kubectl helm docker curl gh sha256sum python3; do
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
"$SPIN_APP_DIR/build.sh" --push
assert_file "$SPIN_APP_WASM" "cargo-spin.wasm"
PROFILE="$PROFILE" "$SCRIPT_DIR/install-spinkube.sh"
minikube addons enable ingress -p "$PROFILE" >/dev/null 2>&1 || true
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl rollout status "deployment/$SPINAPP_NAME" -n "$SPINAPP_NAMESPACE" --timeout=180s
# Belt-and-suspenders: if anything bounced the ingress controller, wait again
# before trusting it to route.
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_SPIN_HOST="cargo-spin.${MINIKUBE_IP}.nip.io"
BASE="http://$CARGO_SPIN_HOST"
kubectl patch ingress "$SPINAPP_NAME" -n "$SPINAPP_NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_SPIN_HOST\"}]"
# Wait until our Ingress rule is actually routing (affinity cookie), then a real 200.
waited=0; ok=0
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "$BASE$VALID_PATH" 2>/dev/null | grep -qi "$SPIN_INGRESS_AFFINITY_COOKIE"; then ok=1; break; fi
  sleep 2; waited=$(( waited + 2 ))
done
[[ "$ok" -eq 1 ]] || { echo "capture-evidence.sh: FAIL — ingress never routed $CARGO_SPIN_HOST" >&2; exit 1; }
wait_for_200 "$BASE$VALID_PATH" 90

echo "=== 00 versions ==="
{
  printf '$ minikube version --short\n'; minikube version --short
  printf '\n$ kubectl --context %s version\n' "$PROFILE"; kubectl version 2>&1 || true
  printf '\n# SpinKube stack (pinned)\n'
  printf 'cert-manager          : %s (fallback %s)\n' "$CERT_MANAGER_VERSION" "$CERT_MANAGER_VERSION_FALLBACK"
  printf 'runtime-class-manager : %s (%s)\n' "$RUNTIME_CLASS_MANAGER_VERSION" "$RUNTIME_CLASS_MANAGER_CHART"
  printf 'containerd-shim-spin  : %s\n' "$SHIM_SPIN_VERSION"
  printf 'shim manifest         : %s\n' "$SHIM_SPIN_MANIFEST_URL"
  printf 'spin-operator         : %s (%s)\n' "$SPIN_OPERATOR_VERSION" "$SPIN_OPERATOR_CHART"
  printf 'executor              : %s\n' "$SPIN_EXECUTOR"
  printf '\n$ helm list -A --kube-context %s\n' "$PROFILE"
  helm list -A 2>&1 || true
} | tee "$OUT/00-versions.txt"

echo "=== 01 nodes ==="
cap 01-nodes -- kubectl get nodes -o wide

echo "=== 02 runtimeclass ==="
{
  printf '$ kubectl get runtimeclass %s -o yaml\n' "$SPIN_RUNTIMECLASS"
  kubectl get runtimeclass "$SPIN_RUNTIMECLASS" -o yaml
  printf '\n$ kubectl get shims.runtime-class-manager.spinframework.dev -A\n'
  kubectl get shims.runtime-class-manager.spinframework.dev -A 2>&1 || true
} | tee "$OUT/02-runtimeclass.txt"

echo "=== 03 spinapp + deploy/svc/ingress ==="
{
  printf '$ kubectl get spinapp %s -n %s -o yaml\n' "$SPINAPP_NAME" "$SPINAPP_NAMESPACE"
  kubectl get spinapp "$SPINAPP_NAME" -n "$SPINAPP_NAMESPACE" -o yaml
  printf '\n$ kubectl get deploy,svc,ingress -n %s -o wide\n' "$SPINAPP_NAMESPACE"
  kubectl get deploy,svc,ingress -n "$SPINAPP_NAMESPACE" -o wide
  printf '\n# the runtimeClassName that routes this Pod to the Spin shim:\n'
  printf '$ kubectl get deploy %s -n %s -o jsonpath={.spec.template.spec.runtimeClassName}\n' "$SPINAPP_NAME" "$SPINAPP_NAMESPACE"
  kubectl get deploy "$SPINAPP_NAME" -n "$SPINAPP_NAMESPACE" -o jsonpath='{.spec.template.spec.runtimeClassName}'; printf '\n'
} | tee "$OUT/03-spinapp.txt"

echo "=== 04 pods (get + describe) ==="
{
  printf '$ kubectl get pods -n %s -o wide\n' "$SPINAPP_NAMESPACE"
  kubectl get pods -n "$SPINAPP_NAMESPACE" -o wide
  printf '\n$ kubectl describe pod (RuntimeClass + node)\n'
  kubectl describe pod -l app.kubernetes.io/name="$SPINAPP_NAME" -n "$SPINAPP_NAMESPACE" \
    | grep -Ei 'Name:|Node:|Runtime Class Name:|Status:|Image:|Started|Ready' | head -20
} | tee "$OUT/04-pods.txt"

echo "=== 05 http through the ingress edge ==="
{
  printf '# request path: host -> ingress-nginx -> Service %s:80 -> Pod -> containerd-shim-spin -> cargo-spin.wasm\n' "$SPINAPP_NAME"
  printf '$ curl -s %s%s\n' "$BASE" "$VALID_PATH"
  body="$(curl_body "$BASE$VALID_PATH")"
  printf '%s\n' "$body"
  printf '$ curl -s -o /dev/null -w %%{http_code} %s/cargo/NOPE\n' "$BASE"
  code404="$(curl_code "$BASE/cargo/NOPE")"
  printf '%s\n' "$code404"
} | tee "$OUT/05-http.txt"
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "SpinKube GET $VALID_PATH through ingress"
code404="$(curl_code "$BASE/cargo/NOPE")"
assert_eq "404" "$code404" "SpinKube GET /cargo/NOPE through ingress"

echo "=== 06 sha256(cargo-spin.wasm) ==="
cap 06-sha256 -- sha256sum "$SPIN_APP_WASM"

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
echo "PASS — ch26 SpinKube (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  the cargo Spin component runs as a Pod via the spin-operator and the"
echo "  containerd-shim-spin shim (RuntimeClass '$SPIN_RUNTIMECLASS'); GET"
echo "  $VALID_PATH through ingress-nginx returned the exact cargo JSON and"
echo "  /cargo/NOPE returned 404."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ./teardown.sh to remove the SpinKube stack."
