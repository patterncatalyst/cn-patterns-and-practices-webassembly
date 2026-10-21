#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/scaling/capture-hpa-evidence.sh
#
# Headless live run of the ch22 minikube HPA example that produces the
# COMMITTED evidence. Self-contained and idempotent, same shape as
# ../capture-evidence.sh: ensures the profile is up, the image is built +
# loaded, the shim + RuntimeClass are installed, the scaling overlay (base app
# + HorizontalPodAutoscaler) is applied, the Ingress is patched to the live
# nip.io host — then it drives real in-cluster load, captures a REAL scale-out
# and a REAL scale-back-down (never assumed, never faked — a missed scale
# event fails the script under `set -e`), and tees every step to
# evidence/<YYYY-MM-DD>/2N-*.txt with a secret scrub.
#
# Requires metrics-server already enabled (CHECK ONLY — this script does not
# enable it; see verify-hpa-minikube.sh's Step 4 comment for why).
#
# Does NOT tear the cluster down — run ../teardown.sh afterwards.
#
# Order (continues the 00-07 numbering from ../capture-evidence.sh so both
# evidence sets can live in the same dated directory):
#   20 metrics-server + HPA object (spec + the pinned stabilization window)
#   21 HPA status BEFORE load (1 replica, steady state)
#   22 scale-out proof: load generator on, replicas climbing, HPA events
#   23 scale-down proof: load generator off, replicas settling back to 1
#   24 app still serves the exact cargo JSON after the scale cycle
#   25 secret scrub over the evidence directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

for tool in minikube kubectl docker curl sha256sum python3; do
  require_cmd "$tool"
done

SCALE_UP_TIMEOUT="${SCALE_UP_TIMEOUT:-300}"
SCALE_DOWN_TIMEOUT="${SCALE_DOWN_TIMEOUT:-420}"
METRICS_TIMEOUT="${METRICS_TIMEOUT:-180}"

OUT="$SCRIPT_DIR/../evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

# cap NN-name -- cmd...  run a command, tee combined output to the evidence file.
cap() {
  local file="$OUT/$1.txt"; shift
  [[ "$1" == "--" ]] && shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$file"
}

step "guard: metrics-server must already be enabled (CHECK ONLY, never auto-enabled)"
metrics_server_enabled() {
  minikube addons list -p "$PROFILE" -o json 2>/dev/null | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("metrics-server", {}).get("Status") == "enabled" else 1)
'
}
if ! metrics_server_enabled; then
  cat >&2 <<EOF
capture-hpa-evidence.sh: FAIL — metrics-server addon is not enabled on profile '$PROFILE'.
  Enable it explicitly, then re-run:
    minikube addons enable metrics-server -p $PROFILE
    kubectl --context $PROFILE rollout status deployment/metrics-server -n kube-system --timeout=180s
EOF
  exit 1
fi

step "ensure the cluster + the scaling deploy are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
IMAGE="$IMAGE" "$PART5_DIR/build.sh"
minikube image load "$IMAGE" -p "$PROFILE"
PROFILE="$PROFILE" "$SCRIPT_DIR/../install-shim.sh"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s

MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
BASE="http://$CARGO_HOST"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"
wait_for_200 "$BASE$VALID_PATH" 120

echo "=== 20 metrics-server + HPA object ==="
{
  printf '$ kubectl get deploy metrics-server -n kube-system\n'
  kubectl get deploy metrics-server -n kube-system 2>&1 || true
  printf '\n$ kubectl get hpa cargo-http -n %s -o yaml\n' "$NAMESPACE"
  kubectl get hpa cargo-http -n "$NAMESPACE" -o yaml
} | tee "$OUT/20-hpa-object.txt"

step "wait for the HPA to report REAL metrics (not <unknown>)"
hpa_has_metrics() {
  local v
  v="$(kubectl get hpa cargo-http -n "$NAMESPACE" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
  [[ -n "$v" ]]
}
waited=0
until hpa_has_metrics; do
  (( waited >= METRICS_TIMEOUT )) && { echo "capture-hpa-evidence.sh: FAIL — HPA never reported CPU metrics within ${METRICS_TIMEOUT}s" >&2; exit 1; }
  sleep 5; waited=$(( waited + 5 ))
done

echo "=== 21 HPA status BEFORE load (steady state) ==="
cap 21-before-load -- kubectl get hpa,deploy cargo-http -n "$NAMESPACE"

echo "=== 22 scale-OUT proof (load generator on) ==="
kubectl apply -f "$SCRIPT_DIR/load/load-generator.yaml"
kubectl scale deployment/cargo-http-load -n "$NAMESPACE" --replicas=1

current_replicas() {
  kubectl get deployment cargo-http -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0
}
{
  printf '# polling kubectl get hpa,deploy every 10s until replicas > 1 (timeout %ss)\n' "$SCALE_UP_TIMEOUT"
  waited=0; scaled=0
  while (( waited < SCALE_UP_TIMEOUT )); do
    r="$(current_replicas)"
    printf '[t=%ss] replicas=%s\n' "$waited" "$r"
    if [[ "$r" -gt 1 ]]; then scaled=1; break; fi
    sleep 10; waited=$(( waited + 10 ))
  done
  printf '\n$ kubectl get hpa,deploy cargo-http -n %s\n' "$NAMESPACE"
  kubectl get hpa,deploy cargo-http -n "$NAMESPACE"
  printf '\n$ kubectl get events -n %s --field-selector involvedObject.name=cargo-http --sort-by=.lastTimestamp\n' "$NAMESPACE"
  kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name=cargo-http --sort-by=.lastTimestamp 2>&1 | tail -20
  [[ "$scaled" -eq 1 ]] || { echo "FAIL — cargo-http never scaled above 1 replica within ${SCALE_UP_TIMEOUT}s"; exit 1; }
} | tee "$OUT/22-scale-out.txt"
[[ "$(current_replicas)" -gt 1 ]] || { echo "capture-hpa-evidence.sh: FAIL — scale-out assertion failed after capture" >&2; exit 1; }

echo "=== 23 scale-DOWN proof (load generator off) ==="
kubectl scale deployment/cargo-http-load -n "$NAMESPACE" --replicas=0
{
  printf '# polling kubectl get hpa,deploy every 10s until replicas == 1 (timeout %ss)\n' "$SCALE_DOWN_TIMEOUT"
  waited=0; settled=0
  while (( waited < SCALE_DOWN_TIMEOUT )); do
    r="$(current_replicas)"
    printf '[t=%ss] replicas=%s\n' "$waited" "$r"
    if [[ "$r" -eq 1 ]]; then settled=1; break; fi
    sleep 10; waited=$(( waited + 10 ))
  done
  printf '\n$ kubectl get hpa,deploy cargo-http -n %s\n' "$NAMESPACE"
  kubectl get hpa,deploy cargo-http -n "$NAMESPACE"
  [[ "$settled" -eq 1 ]] || { echo "FAIL — cargo-http never scaled back down to 1 replica within ${SCALE_DOWN_TIMEOUT}s"; exit 1; }
} | tee "$OUT/23-scale-down.txt"
[[ "$(current_replicas)" -eq 1 ]] || { echo "capture-hpa-evidence.sh: FAIL — scale-down assertion failed after capture" >&2; exit 1; }

echo "=== 24 app still answers correctly after the scale cycle ==="
{
  printf '$ curl -s %s%s\n' "$BASE" "$VALID_PATH"
  body="$(curl_body "$BASE$VALID_PATH")"
  printf '%s\n' "$body"
} | tee "$OUT/24-post-scale-http.txt"
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "minikube GET $VALID_PATH through ingress after scale cycle"

echo "=== 25 secret scrub ==="
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
scrub | tee "$OUT/25-scrub.txt"
if grep -rEl 'BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}|client-key-data: [A-Za-z0-9+/=]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

echo
echo "PASS — part5-kubernetes ch22 HPA (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  cargo-http scaled OUT under real in-cluster load and back IN once the load"
echo "  stopped, via a stock autoscaling/v2 HPA reading real cgroup CPU metrics"
echo "  through metrics-server."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ../teardown.sh to leave the box clean."
