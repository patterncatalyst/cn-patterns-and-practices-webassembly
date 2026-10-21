#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/verify-interposed-minikube.sh
#
# Live, self-contained verification of the ch20/ch21 INTERPOSED compositions on a
# real minikube cluster (docker driver + containerd runtime): the sidecar-filter
# (ch20) and the shape-translation adapter (ch21), each wac-plug-composed with the
# Part 2 provider and the Part 3 http front door, run as sibling Wasm Pods via the
# runwasi `wasmtime` shim and proven, live, through the ingress-nginx edge.
#
# Proven end to end (NO port-forward, NO NodePort, NO `minikube service`):
#   curl -> cargo-filtered.<ip>.nip.io -> Service -> Pod(shim) -> app-filtered.wasm
#   curl -> cargo-adapted.<ip>.nip.io  -> Service -> Pod(shim) -> app-adapted.wasm
#
# Assertions:
#   FILTERED: normal -> exact JSON (200); embargoed destination -> policy 400;
#             unknown id -> 404.
#   ADAPTED : round-trip -> exact JSON (200); unknown id -> 404.
#
# Usage:
#   ./verify-interposed-minikube.sh            # full run; tears the profile down
#   ./verify-interposed-minikube.sh --keep     # leave the profile running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-interposed-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl docker curl cargo-component wac wasm-tools; do
  require_cmd "$tool"
done

FILTER_IMAGE="cargo-http-filtered:minikube"
ADAPTER_IMAGE="cargo-http-adapted:minikube"
EMBARGO_PATH="/cargo/CARGO-USNYC-CUHAV"

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "verify-interposed-minikube.sh: --keep set — leaving profile '$PROFILE' running" >&2
  else
    echo "verify-interposed-minikube.sh: tearing down minikube profile '$PROFILE'" >&2
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-interposed-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }
echo "verify-interposed-minikube.sh: minikube $mk_ver OK (>= $MINIKUBE_MIN); shim $SHIM_VERSION; Kubernetes $KUBERNETES_VERSION"

step "Step 1: minikube profile '$PROFILE' (docker driver, containerd)"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-interposed-minikube.sh: profile '$PROFILE' already running — reusing it"
else
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi
kubectl get nodes

step "Step 2: build + load BOTH interposed images (no registry)"
IMAGE="$FILTER_IMAGE"  "$PART5_DIR/sidecar-filter/build.sh"
IMAGE="$ADAPTER_IMAGE" "$PART5_DIR/adapter/build.sh"
minikube image load "$FILTER_IMAGE"  -p "$PROFILE"
minikube image load "$ADAPTER_IMAGE" -p "$PROFILE"

step "Step 3: install the runwasi wasmtime shim + RuntimeClass (restarts containerd)"
PROFILE="$PROFILE" "$SCRIPT_DIR/install-shim.sh"

step "Step 3b: namespace + ingress-nginx addon"
kubectl apply -f "$SCRIPT_DIR/base/namespace.yaml"
minikube addons enable ingress -p "$PROFILE"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

step "Step 4: deploy both compositions (interposed/overlays/minikube)"
# ingress-nginx's admission webhook can refuse the Ingress create for a few
# seconds after the controller rollout reports Ready (the webhook endpoint is
# still registering) — a known race. Retry the apply until it is accepted.
apply_interposed() {
  local tries=0
  until kubectl apply -k "$SCRIPT_DIR/interposed/overlays/minikube"; do
    tries=$(( tries + 1 ))
    if (( tries >= 24 )); then
      echo "verify-interposed-minikube.sh: FAIL — apply -k never accepted (ingress admission webhook) after $tries tries" >&2
      return 1
    fi
    echo "verify-interposed-minikube.sh: ingress admission webhook not ready; retrying apply in 5s ($tries/24)" >&2
    sleep 5
  done
}
apply_interposed
kubectl rollout status deployment/cargo-http-filtered -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/cargo-http-adapted  -n "$NAMESPACE" --timeout=180s
kubectl get pods -n "$NAMESPACE" -o wide

step "Step 5: resolve + patch both Ingresses to live nip.io hosts"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
FILTERED_HOST="cargo-filtered.${MINIKUBE_IP}.nip.io"
ADAPTED_HOST="cargo-adapted.${MINIKUBE_IP}.nip.io"
FILTERED_BASE="http://$FILTERED_HOST"
ADAPTED_BASE="http://$ADAPTED_HOST"
echo "verify-interposed-minikube.sh: filtered host = $FILTERED_BASE"
echo "verify-interposed-minikube.sh: adapted  host = $ADAPTED_BASE"
kubectl patch ingress cargo-http-filtered -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$FILTERED_HOST\"}]"
kubectl patch ingress cargo-http-adapted -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$ADAPTED_HOST\"}]"

wait_for_cookie() {
  local url="$1" cookie="$2" waited=0
  while (( waited < 90 )); do
    if curl -sS -D - -o /dev/null "$url" 2>/dev/null | grep -qi "$cookie"; then return 0; fi
    sleep 2; waited=$(( waited + 2 ))
  done
  echo "verify-interposed-minikube.sh: FAIL — ingress never routed $url within 90s" >&2
  return 1
}
wait_for_cookie "$FILTERED_BASE$VALID_PATH" "part5-filtered-affinity"
wait_for_cookie "$ADAPTED_BASE$VALID_PATH" "part5-adapted-affinity"

step "Step 6: live HTTP assertions through the ingress (readiness = a real 200)"
wait_for_200 "$FILTERED_BASE$VALID_PATH" 90
wait_for_200 "$ADAPTED_BASE$VALID_PATH" 90

fbody="$(curl_body "$FILTERED_BASE$VALID_PATH")"
echo "FILTERED GET $VALID_PATH -> $fbody"
assert_eq "$EXPECTED_JSON" "$fbody" "FILTERED normal GET $VALID_PATH through ingress"
assert_eq "400" "$(curl_code "$FILTERED_BASE$EMBARGO_PATH")" "FILTERED embargo GET $EMBARGO_PATH -> 400"
assert_eq "404" "$(curl_code "$FILTERED_BASE/cargo/NOPE")" "FILTERED GET /cargo/NOPE -> 404"

abody="$(curl_body "$ADAPTED_BASE$VALID_PATH")"
echo "ADAPTED GET $VALID_PATH -> $abody"
assert_eq "$EXPECTED_JSON" "$abody" "ADAPTED round-trip GET $VALID_PATH through ingress"
assert_eq "404" "$(curl_code "$ADAPTED_BASE/cargo/NOPE")" "ADAPTED GET /cargo/NOPE -> 404"

echo
echo "PASS — part5-kubernetes interposed on minikube:"
echo "  FILTERED (ch20) returns exact JSON (200), embargo 400, unknown 404;"
echo "  ADAPTED  (ch21) round-trips to the exact JSON (200), unknown 404;"
echo "  both as Wasm Pods via the containerd wasmtime shim, through ingress-nginx."
echo "exit 0"
