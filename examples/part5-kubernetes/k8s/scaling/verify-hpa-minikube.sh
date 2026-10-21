#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/scaling/verify-hpa-minikube.sh
#
# ch22 autoscaler asymmetry — MINIKUBE HALF.
#
# Teaching point this script proves, live: a Pod with `runtimeClassName:
# wasmtime` is still scheduled, cgrouped, and metered by the kubelet exactly
# like a runc Pod — containerd-shim-wasmtime reports CPU usage into the SAME
# cgroup hierarchy cAdvisor reads. metrics-server scrapes that through the
# summary API, and a stock `autoscaling/v2` HorizontalPodAutoscaler reacts to
# it exactly as it would for any container workload. No Wasm-specific
# autoscaler controller is needed here — see ../../openshift/verify-scaling-
# crc.sh for the CRC counterpart, where this is NOT true (the wasmCloud
# operator manages the workload, not a plain Deployment, so a K8s HPA has
# nothing correct to target).
#
# The second half of the teaching point is SPEED: a Wasm component has no JVM-
# style warm-up, so a freshly scheduled replica starts serving within
# milliseconds of going Ready. hpa.yaml shortens the scale-down stabilization
# window from the Kubernetes default (300s) accordingly (see hpa.yaml's
# comments) — scale-up stays fast by default.
#
# What this script does, idempotently:
#   1. Bring up the minikube profile, build + load the image, install the
#      wasmtime shim (same as ../verify-minikube.sh).
#   2. Check (NOT enable) metrics-server: HPA metrics require it, and enabling
#      a cluster addon is an explicit, user-gated step in this house
#      convention — the script fails with a clear instruction rather than
#      silently flipping it on.
#   3. Apply overlays/minikube (base Deployment/Service/Ingress + the HPA) and
#      wait for the HPA to report REAL (non-"<unknown>") metrics.
#   4. Scale the load generator (../load/load-generator.yaml) to 1 replica
#      (CONCURRENCY parallel in-cluster request loops, NO port-forward) and
#      poll `kubectl get hpa` + `kubectl get deploy` until replicas actually
#      climb above 1 — never assumed, never faked; a timeout here is a FAIL.
#   5. Scale the load generator back to 0 and poll until replicas return to 1.
#
# Usage:
#   ./verify-hpa-minikube.sh            # full run; tears the profile down
#   ./verify-hpa-minikube.sh --keep     # leave the profile running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-hpa-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl docker curl python3; do
  require_cmd "$tool"
done

SCALE_UP_TIMEOUT="${SCALE_UP_TIMEOUT:-300}"
SCALE_DOWN_TIMEOUT="${SCALE_DOWN_TIMEOUT:-420}"
METRICS_TIMEOUT="${METRICS_TIMEOUT:-180}"

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "verify-hpa-minikube.sh: --keep set — leaving profile '$PROFILE' running" >&2
  else
    echo "verify-hpa-minikube.sh: tearing down minikube profile '$PROFILE'" >&2
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-hpa-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }
echo "verify-hpa-minikube.sh: minikube $mk_ver OK (>= $MINIKUBE_MIN); shim $SHIM_VERSION; Kubernetes $KUBERNETES_VERSION"

step "Step 1: minikube profile '$PROFILE' (docker driver, containerd, Kubernetes $KUBERNETES_VERSION)"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-hpa-minikube.sh: profile '$PROFILE' already running — reusing it"
else
  minikube start -p "$PROFILE" \
    --driver=docker \
    --container-runtime=containerd \
    --kubernetes-version="$KUBERNETES_VERSION"
fi
kubectl get nodes

step "Step 2: build app.wasm + the OCI image, load it into the node (no registry)"
IMAGE="$IMAGE" "$PART5_DIR/build.sh"
minikube image load "$IMAGE" -p "$PROFILE"
assert_file "$APP_WASM" "app.wasm"

step "Step 3: install the runwasi wasmtime shim + RuntimeClass (restarts containerd)"
PROFILE="$PROFILE" "$SCRIPT_DIR/../install-shim.sh"

step "Step 4: metrics-server addon — CHECK ONLY, never auto-enabled"
# HPA CPU metrics require metrics-server. Enabling a minikube addon changes the
# cluster's control-plane surface, so this script treats it the same as it
# treats starting/stopping the profile elsewhere in the house scripts: an
# explicit, user-gated action. It checks and reminds; it does not run
# `minikube addons enable metrics-server` itself.
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
verify-hpa-minikube.sh: FAIL — metrics-server addon is not enabled on profile '$PROFILE'.
  The HPA cannot read CPU utilization without it. Enable it explicitly, then re-run:
    minikube addons enable metrics-server -p $PROFILE
    kubectl --context $PROFILE rollout status deployment/metrics-server -n kube-system --timeout=180s
EOF
  exit 1
fi
echo "verify-hpa-minikube.sh: metrics-server addon is enabled"

step "Step 5: deploy (scaling/overlays/minikube — base app + HorizontalPodAutoscaler)"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s
kubectl get pods -n "$NAMESPACE" -o wide

step "Step 6: resolve + patch the Ingress to the live nip.io host, wait for a real 200"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"
BASE="http://$CARGO_HOST"
wait_for_200 "$BASE$VALID_PATH" 120

step "Step 7: wait for the HPA to report REAL metrics (not <unknown>)"
hpa_has_metrics() {
  local targets
  targets="$(kubectl get hpa cargo-http -n "$NAMESPACE" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
  [[ -n "$targets" ]]
}
waited=0
until hpa_has_metrics; do
  (( waited >= METRICS_TIMEOUT )) && { echo "verify-hpa-minikube.sh: FAIL — HPA never reported CPU metrics within ${METRICS_TIMEOUT}s (metrics-server may not be scraping yet)" >&2; kubectl describe hpa cargo-http -n "$NAMESPACE" >&2 || true; exit 1; }
  sleep 5; waited=$(( waited + 5 ))
done
kubectl get hpa cargo-http -n "$NAMESPACE"
echo "verify-hpa-minikube.sh: HPA reporting real CPU metrics after ${waited}s"

step "Step 8: apply the load generator (idle, 0 replicas) and start the load"
kubectl apply -f "$SCRIPT_DIR/load/load-generator.yaml"
kubectl scale deployment/cargo-http-load -n "$NAMESPACE" --replicas=1
echo "verify-hpa-minikube.sh: load generator scaled to 1 (CONCURRENCY parallel in-cluster request loops)"

step "Step 9: assert a REAL scale-out — replicas 1 -> N under load (never assumed)"
current_replicas() {
  kubectl get deployment cargo-http -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0
}
waited=0; scaled=0
while (( waited < SCALE_UP_TIMEOUT )); do
  r="$(current_replicas)"
  if [[ "$r" -gt 1 ]]; then
    scaled=1
    echo "verify-hpa-minikube.sh: observed scale-out to $r replicas after ${waited}s"
    break
  fi
  sleep 10; waited=$(( waited + 10 ))
done
kubectl get hpa,deploy cargo-http -n "$NAMESPACE"
[[ "$scaled" -eq 1 ]] || { echo "verify-hpa-minikube.sh: FAIL — cargo-http never scaled above 1 replica within ${SCALE_UP_TIMEOUT}s under load" >&2; exit 1; }

step "Step 10: stop the load; assert a REAL scale-down — replicas N -> 1"
kubectl scale deployment/cargo-http-load -n "$NAMESPACE" --replicas=0
echo "verify-hpa-minikube.sh: load generator scaled to 0; waiting for the HPA to scale cargo-http back down"
waited=0; settled=0
while (( waited < SCALE_DOWN_TIMEOUT )); do
  r="$(current_replicas)"
  if [[ "$r" -eq 1 ]]; then
    settled=1
    echo "verify-hpa-minikube.sh: observed scale-down to 1 replica after ${waited}s"
    break
  fi
  sleep 10; waited=$(( waited + 10 ))
done
kubectl get hpa,deploy cargo-http -n "$NAMESPACE"
[[ "$settled" -eq 1 ]] || { echo "verify-hpa-minikube.sh: FAIL — cargo-http never scaled back down to 1 replica within ${SCALE_DOWN_TIMEOUT}s after load stopped" >&2; exit 1; }

step "Step 11: the app still answers correctly after the scale cycle"
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "minikube GET $VALID_PATH through ingress after scale cycle"

echo
echo "PASS — part5-kubernetes ch22 HPA on minikube (docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  the stock autoscaling/v2 HorizontalPodAutoscaler scaled cargo-http OUT under"
echo "  load and back IN once the load stopped, reading real cgroup CPU metrics"
echo "  through metrics-server from a Pod scheduled via RuntimeClass '$SHIM_HANDLER'."
echo "exit 0"
