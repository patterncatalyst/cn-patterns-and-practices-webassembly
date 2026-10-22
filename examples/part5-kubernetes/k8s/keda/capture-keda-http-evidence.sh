#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/keda/capture-keda-http-evidence.sh
#
# Headless live run of the ch23 KEDA HTTP scale-to-zero example that produces
# the COMMITTED evidence, teeing every step to evidence/<YYYY-MM-DD>/NN-*.txt
# with a secret scrub. Self-contained and idempotent, mirroring the structure
# of ../capture-evidence.sh (ch17/18) and ../scaling/capture-hpa-evidence.sh
# (ch22) but proving the ADDITIONAL scale-to-ZERO behavior those chapters do
# not: idle -> 0 replicas -> a cold request through the KEDA interceptor -> 1
# replica -> a real 200, with the cold-start latency captured as a number.
#
# Does NOT tear the cluster down — run ../teardown.sh afterwards.
#
# Order:
#   00 versions (minikube, kubectl, KEDA core + HTTP add-on chart versions)
#   01 keda pods (operator, add-ons-http controller-manager + interceptor)
#   02 deploy (HTTPScaledObject + Deployment + interceptor-service + Ingress)
#   03 warm http (exact JSON through the edge, before idling)
#   04 scale-to-zero (replica count observed going to 0 while idle)
#   05 cold-start (timed COLD request through the interceptor: 0 -> 1 -> 200)
#   06 sha256(app.wasm) — same bytes as Parts 2/3/4/5
#   07 secret scrub
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

for tool in minikube kubectl docker curl helm sha256sum python3; do
  require_cmd "$tool"
done

IDLE_TIMEOUT="${IDLE_TIMEOUT:-120}"
COLDSTART_TIMEOUT="${COLDSTART_TIMEOUT:-60}"

OUT="$SCRIPT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

cap() {
  local file="$OUT/$1.txt"; shift
  [[ "$1" == "--" ]] && shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$file"
}

step "ensure the cluster + KEDA + deploy are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
IMAGE="$IMAGE" "$PART5_DIR/build.sh"
minikube image load "$IMAGE" -p "$PROFILE"
PROFILE="$PROFILE" "$SCRIPT_DIR/../install-shim.sh"
minikube addons enable ingress -p "$PROFILE" >/dev/null 2>&1 || true
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
PROFILE="$PROFILE" "$SCRIPT_DIR/install-keda.sh"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl wait --for=condition=Available=True deployment/cargo-http -n "$NAMESPACE" --timeout=180s 2>/dev/null || true
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
BASE="http://$CARGO_HOST"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"
kubectl patch httpscaledobject cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/hosts/0\",\"value\":\"$CARGO_HOST\"}]"
wait_for_200 "$BASE$VALID_PATH" 120

echo "=== 00 versions ==="
{
  printf '$ minikube version --short\n'; minikube version --short
  printf '\n$ helm list -n keda --kube-context %s\n' "$PROFILE"
  helm --kube-context "$PROFILE" list -n keda 2>&1 || true
  printf '\n# pinned chart versions\nKEDA core: 2.21.0\nKEDA HTTP add-on: 0.16.0\n'
} | tee "$OUT/00-versions.txt"

echo "=== 01 keda pods ==="
cap 01-keda-pods -- kubectl get pods -n keda -o wide

echo "=== 02 deploy (HTTPScaledObject + Deployment + interceptor routing + Ingress) ==="
{
  printf '$ kubectl get httpscaledobject,deploy,svc,ingress -n %s -o wide\n' "$NAMESPACE"
  kubectl get httpscaledobject,deploy,svc,ingress -n "$NAMESPACE" -o wide
} | tee "$OUT/02-deploy.txt"

echo "=== 03 warm http (before idling) ==="
{
  printf '$ curl -s %s%s\n' "$BASE" "$VALID_PATH"
  body="$(curl_body "$BASE$VALID_PATH")"
  printf '%s\n' "$body"
} | tee "$OUT/03-warm-http.txt"
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "minikube GET $VALID_PATH (warm)"

echo "=== 04 scale-to-zero (idle) ==="
current_replicas() { kubectl get deployment cargo-http -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "-1"; }
{
  printf '# waiting up to %ss for KEDA to scale cargo-http to 0 while idle\n' "$IDLE_TIMEOUT"
  waited=0; zeroed=0
  while (( waited < IDLE_TIMEOUT )); do
    r="$(current_replicas)"
    printf 't=%ss replicas=%s\n' "$waited" "$r"
    if [[ "$r" == "0" || -z "$r" ]]; then zeroed=1; break; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  printf 'scaled-to-zero after %ss: %s\n' "$waited" "$zeroed"
  if [[ "$zeroed" -ne 1 ]]; then
    echo "FAIL — cargo-http never scaled to 0 within ${IDLE_TIMEOUT}s" >&2
    exit 1
  fi
} | tee "$OUT/04-scale-to-zero.txt"

echo "=== 05 cold-start (timed COLD request through the interceptor) ==="
{
  printf '$ curl -sS -w "%%{http_code} %%{time_total}" %s%s\n' "$BASE" "$VALID_PATH"
  cold_out="$(curl -sS -o /tmp/keda-http-cold-body.$$ -w '%{http_code} %{time_total}' --max-time "$COLDSTART_TIMEOUT" "$BASE$VALID_PATH" 2>/dev/null || echo "000 0")"
  cold_code="$(awk '{print $1}' <<<"$cold_out")"
  cold_seconds="$(awk '{print $2}' <<<"$cold_out")"
  cold_body="$(cat /tmp/keda-http-cold-body.$$ 2>/dev/null || true)"
  rm -f "/tmp/keda-http-cold-body.$$"
  printf 'http_code=%s cold_start_seconds=%s\n' "$cold_code" "$cold_seconds"
  printf 'body=%s\n' "$cold_body"
  printf '\n$ kubectl get deploy cargo-http -n %s\n' "$NAMESPACE"
  kubectl get deploy cargo-http -n "$NAMESPACE"
  if [[ "$cold_code" != "200" ]]; then
    echo "FAIL — cold request returned HTTP $cold_code, not 200" >&2
    exit 1
  fi
  if [[ "$cold_body" != "$EXPECTED_JSON" ]]; then
    echo "FAIL — cold request body mismatch" >&2
    exit 1
  fi
  echo "cold-start-latency-seconds: $cold_seconds"
} | tee "$OUT/05-cold-start.txt"

echo "=== 06 sha256 (same bytes as Parts 2/3/4/5) ==="
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
echo "PASS — part5-kubernetes ch23 KEDA HTTP scale-to-zero (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  cargo-http scaled to 0 replicas while idle and back to 1 on the first"
echo "  cold request through the KEDA interceptor, with a real 200 and the exact"
echo "  cargo JSON; cold-start latency captured in evidence/*/05-cold-start.txt."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ../teardown.sh to leave the box clean."
