#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/keda/verify-keda-http-minikube.sh
#
# ch23 serverless scale-to-zero — HTTP half, MINIKUBE.
#
# Unlike ch22 (HPA floor of 1 replica), this proves KEDA driving the raw-shim
# `cargo-http` Deployment all the way to ZERO replicas when idle, and back to
# one on the FIRST cold request — through the real edge, with the KEDA HTTP
# add-on interceptor in the path (see base/interceptor-service.yaml for why an
# Ingress can't reach the interceptor's Service directly across namespaces):
#
#   curl -> cargo.<minikube-ip>.nip.io  (ingress-nginx)
#        -> keda-interceptor-proxy (ExternalName -> keda ns)
#        -> keda-add-ons-http-interceptor-proxy  (holds the request, asks KEDA
#           to scale cargo-http 0 -> 1, waits for Ready)
#        -> Service cargo-http:8080 -> Pod (runtimeClassName: wasmtime)
#        -> containerd-shim-wasmtime -> app.wasm
#
# Idempotent and self-contained: starts the profile if needed, installs the
# shim + ingress-nginx (reusing ../install-shim.sh), installs KEDA core + the
# HTTP add-on (install-keda.sh), applies this overlay, scales cargo-http to 0
# to simulate idle, waits for KEDA to confirm it, then fires ONE cold request
# and asserts it still gets a real 200 with the exact cargo JSON — proving the
# interceptor held the request through the 0->1 scale-up rather than dropping
# it. Timed with `curl -w` so the cold-start latency is a real, captured
# number, never assumed.
#
# Usage:
#   ./verify-keda-http-minikube.sh            # full run; tears the profile down
#   ./verify-keda-http-minikube.sh --keep     # leave the profile running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-keda-http-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl docker curl helm; do
  require_cmd "$tool"
done

IDLE_TIMEOUT="${IDLE_TIMEOUT:-120}"
COLDSTART_TIMEOUT="${COLDSTART_TIMEOUT:-60}"

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "verify-keda-http-minikube.sh: --keep set — leaving profile '$PROFILE' running" >&2
  else
    echo "verify-keda-http-minikube.sh: tearing down minikube profile '$PROFILE'" >&2
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-keda-http-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }
echo "verify-keda-http-minikube.sh: minikube $mk_ver OK; shim $SHIM_VERSION; Kubernetes $KUBERNETES_VERSION"

step "Step 1: minikube profile '$PROFILE' (docker driver, containerd, Kubernetes $KUBERNETES_VERSION)"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-keda-http-minikube.sh: profile '$PROFILE' already running — reusing it"
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

step "Step 3b: ingress-nginx addon"
minikube addons enable ingress -p "$PROFILE"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

step "Step 4: install KEDA core + the HTTP add-on (pinned Helm charts)"
PROFILE="$PROFILE" "$SCRIPT_DIR/install-keda.sh"

step "Step 5: deploy (keda/overlays/minikube — base app + HTTPScaledObject + interceptor routing)"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
# The Deployment may already be at 0 from a previous idle run; do not assume
# it rolls to 1 here (KEDA may already be holding it at 0 before this wait).
kubectl wait --for=condition=Available=True deployment/cargo-http -n "$NAMESPACE" --timeout=180s 2>/dev/null \
  || echo "verify-keda-http-minikube.sh: cargo-http Deployment not yet Available (ok if KEDA has already scaled it to 0)"
kubectl get pods -n "$NAMESPACE" -o wide

step "Step 6: resolve + patch the Ingress to the live nip.io host"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
echo "verify-keda-http-minikube.sh: cargo ingress host = http://$CARGO_HOST/"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"
kubectl patch httpscaledobject cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/hosts/0\",\"value\":\"$CARGO_HOST\"}]"
BASE="http://$CARGO_HOST"

step "Step 7: prove a warm request works BEFORE testing scale-to-zero"
wait_for_200 "$BASE$VALID_PATH" 120
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "minikube GET $VALID_PATH (warm)"

step "Step 8: idle -> assert KEDA scales cargo-http DOWN to 0 (never assumed)"
current_replicas() {
  kubectl get deployment cargo-http -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "-1"
}
waited=0; zeroed=0
while (( waited < IDLE_TIMEOUT )); do
  r="$(current_replicas)"
  if [[ "$r" == "0" || -z "$r" ]]; then
    zeroed=1
    echo "verify-keda-http-minikube.sh: observed scale-to-zero after ${waited}s"
    break
  fi
  sleep 5; waited=$(( waited + 5 ))
done
kubectl get deploy cargo-http -n "$NAMESPACE"
[[ "$zeroed" -eq 1 ]] || { echo "verify-keda-http-minikube.sh: FAIL — cargo-http never scaled to 0 within ${IDLE_TIMEOUT}s of idle (scaledownPeriod is 30s; check KEDA operator + add-ons-http-controller-manager logs)" >&2; exit 1; }

step "Step 9: COLD request through the interceptor — 0 -> 1 -> real 200, timed"
# -w total_time measures wall-clock from the request leaving curl to the full
# response body arriving: edge -> interceptor hold -> KEDA scale-up ->
# Pod Ready -> component response. This is a REAL cold-start latency number,
# not a guess.
cold_out="$(curl -sS -o /tmp/keda-http-cold-body.$$ -w '%{http_code} %{time_total}' \
  --max-time "$COLDSTART_TIMEOUT" "$BASE$VALID_PATH" 2>/dev/null || echo "000 0")"
cold_code="$(awk '{print $1}' <<<"$cold_out")"
cold_seconds="$(awk '{print $2}' <<<"$cold_out")"
cold_body="$(cat /tmp/keda-http-cold-body.$$ 2>/dev/null || true)"
rm -f "/tmp/keda-http-cold-body.$$"
echo "verify-keda-http-minikube.sh: cold request -> HTTP $cold_code in ${cold_seconds}s"
assert_eq "200" "$cold_code" "minikube COLD GET $VALID_PATH through the KEDA interceptor"
assert_eq "$EXPECTED_JSON" "$cold_body" "minikube COLD GET $VALID_PATH body"
echo "verify-keda-http-minikube.sh: cold-start latency = ${cold_seconds}s (0 -> 1 replica -> real 200)"

step "Step 10: confirm the scale-up actually happened (replicas > 0 post cold request)"
r="$(current_replicas)"
[[ "$r" -ge 1 ]] || { echo "verify-keda-http-minikube.sh: FAIL — cargo-http still shows $r replicas after a 200 response" >&2; exit 1; }
echo "verify-keda-http-minikube.sh: cargo-http at $r replica(s) after the cold request"

echo
echo "PASS — part5-kubernetes ch23 KEDA HTTP scale-to-zero on minikube (docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  KEDA HTTP add-on 0.16.0 (KEDA core 2.21.0) scaled cargo-http to ZERO"
echo "  replicas while idle and back to 1 on the first cold request, with the"
echo "  interceptor holding the request through the scale-up; cold-start latency"
echo "  was ${cold_seconds:-?}s and the response body matched byte-for-byte."
echo "exit 0"
