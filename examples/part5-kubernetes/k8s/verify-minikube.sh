#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/verify-minikube.sh
#
# Deploys the cargo wasi:http component to a real minikube cluster (docker
# driver + containerd runtime) as a Wasm Pod — scheduled onto the runwasi
# `containerd-shim-wasmtime` shim by `runtimeClassName: wasmtime` — and proves,
# live, through the ingress-nginx edge that it serves the exact cargo JSON.
#
# Request path proven end to end (NO port-forward, NO NodePort, NO
# `minikube service`):
#
#   curl -> cargo.<minikube-ip>.nip.io  (ingress-nginx)
#        -> Service cargo-http:8080
#        -> Pod (runtimeClassName: wasmtime)
#        -> containerd-shim-wasmtime  (hyper server on 0.0.0.0:8080)
#        -> app.wasm  (wasi:http/incoming-handler)
#
# Idempotent and self-contained: starts the profile if needed, enables the
# ingress addon, builds + loads the image, installs the shim, applies the
# overlay, patches the Ingress host to the live nip.io name, then asserts a
# REAL 200 (readiness = a real 200, not just a rollout reporting Ready) with the
# exact JSON, and a 404 for an unknown cargo id.
#
# Usage:
#   ./verify-minikube.sh            # full run; tears the profile down at the end
#   ./verify-minikube.sh --keep     # leave the profile running
#   KUBERNETES_VERSION=v1.37.1 ./verify-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl docker curl; do
  require_cmd "$tool"
done

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "verify-minikube.sh: --keep set — leaving profile '$PROFILE' running" >&2
  else
    echo "verify-minikube.sh: tearing down minikube profile '$PROFILE'" >&2
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }
echo "verify-minikube.sh: minikube $mk_ver OK (>= $MINIKUBE_MIN); shim $SHIM_VERSION; Kubernetes $KUBERNETES_VERSION"

step "Step 1: minikube profile '$PROFILE' (docker driver, containerd, Kubernetes $KUBERNETES_VERSION)"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-minikube.sh: profile '$PROFILE' already running — reusing it"
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
echo "verify-minikube.sh: image '$IMAGE' loaded into profile '$PROFILE'"

step "Step 3: install the runwasi wasmtime shim + RuntimeClass (restarts containerd)"
# install-shim restarts containerd, which bounces every Pod on the node — do it
# BEFORE enabling the ingress addon so the controller comes up cleanly after.
PROFILE="$PROFILE" "$SCRIPT_DIR/install-shim.sh"

step "Step 3b: ingress-nginx addon"
minikube addons enable ingress -p "$PROFILE"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

step "Step 4: deploy (overlays/minikube — runtimeClassName: wasmtime)"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s
kubectl get pods -n "$NAMESPACE" -o wide

step "Step 5: resolve + patch the Ingress to the live nip.io host"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_HOST="cargo.${MINIKUBE_IP}.nip.io"
echo "verify-minikube.sh: minikube ip = $MINIKUBE_IP"
echo "verify-minikube.sh: cargo ingress host = http://$CARGO_HOST/"
kubectl patch ingress cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_HOST\"}]"

# Wait until ingress-nginx is actually routing OUR rule (not the default
# backend). The affinity cookie is stamped only on responses that went through
# this Ingress — a deterministic "the async config reload has happened" signal.
waited=0; ok=0
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "http://$CARGO_HOST$VALID_PATH" 2>/dev/null | grep -qi "part5-cargo-affinity"; then
    ok=1; break
  fi
  sleep 2; waited=$(( waited + 2 ))
done
[[ "$ok" -eq 1 ]] || { echo "verify-minikube.sh: FAIL — ingress never routed Host $CARGO_HOST (no affinity cookie) within 90s" >&2; exit 1; }
echo "verify-minikube.sh: ingress routing confirmed for Host $CARGO_HOST after ${waited}s"

step "Step 6: live HTTP assertions through the ingress (readiness = a real 200)"
BASE="http://$CARGO_HOST"
wait_for_200 "$BASE$VALID_PATH" 90
body="$(curl_body "$BASE$VALID_PATH")"
echo "verify-minikube.sh: GET $VALID_PATH -> $body"
assert_eq "$EXPECTED_JSON" "$body" "minikube GET $VALID_PATH through ingress"
code404="$(curl_code "$BASE/cargo/NOPE")"
assert_eq "404" "$code404" "minikube GET /cargo/NOPE through ingress"

echo
echo "PASS — part5-kubernetes on minikube (docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  the cargo wasi:http component runs as a Wasm Pod via the containerd"
echo "  wasmtime shim (RuntimeClass '$SHIM_HANDLER'), and GET $VALID_PATH through"
echo "  ingress-nginx returns the exact cargo JSON while /cargo/NOPE returns 404."
echo "exit 0"
