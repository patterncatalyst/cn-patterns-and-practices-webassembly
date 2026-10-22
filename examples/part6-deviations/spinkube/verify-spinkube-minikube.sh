#!/usr/bin/env bash
# examples/part6-deviations/spinkube/verify-spinkube-minikube.sh
#
# Deploys the ch26 Spin app to a real minikube cluster via full SpinKube — the
# spin-operator reconciling a SpinApp CR into a Deployment + Service, scheduled
# onto the `containerd-shim-spin` shim by `runtimeClassName: wasmtime-spin-v2`
# — and proves, live, through the ingress-nginx edge that it serves the exact
# cargo JSON.
#
# Request path proven end to end (NO port-forward, NO NodePort, NO
# `minikube service`):
#
#   curl -> cargo-spin.<minikube-ip>.nip.io  (ingress-nginx)
#        -> Service cargo-spin:80           (created by spin-operator)
#        -> Pod (runtimeClassName: wasmtime-spin-v2)
#        -> containerd-shim-spin             (Spin's own HTTP trigger)
#        -> cargo-spin.wasm  (wasi:http/handler@0.3.0)
#
# Self-contained: starts/reuses the Part 5 minikube profile, builds + pushes
# the Spin OCI artifact, installs the full SpinKube stack, enables the ingress
# addon, applies the overlay, patches the Ingress host to the live nip.io name,
# then asserts a REAL 200 (readiness = a real 200, not just a rollout
# reporting Ready) with the exact JSON, and a 404 for an unknown cargo id.
#
# Usage:
#   ./verify-spinkube-minikube.sh            # full run; tears the profile down at the end
#   ./verify-spinkube-minikube.sh --keep     # leave the profile running
#   KUBERNETES_VERSION=v1.37.1 ./verify-spinkube-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-spinkube-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl helm docker curl gh; do
  require_cmd "$tool"
done

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "verify-spinkube-minikube.sh: --keep set — leaving profile '$PROFILE' running" >&2
  else
    echo "verify-spinkube-minikube.sh: tearing down minikube profile '$PROFILE'" >&2
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-spinkube-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }
echo "verify-spinkube-minikube.sh: minikube $mk_ver OK (>= $MINIKUBE_MIN); Kubernetes $KUBERNETES_VERSION"
echo "verify-spinkube-minikube.sh: pins — cert-manager $CERT_MANAGER_VERSION (fallback $CERT_MANAGER_VERSION_FALLBACK),"
echo "  runtime-class-manager $RUNTIME_CLASS_MANAGER_VERSION, containerd-shim-spin $SHIM_SPIN_VERSION,"
echo "  spin-operator $SPIN_OPERATOR_VERSION, RuntimeClass '$SPIN_RUNTIMECLASS'"

step "Step 1: minikube profile '$PROFILE' (docker driver, containerd, Kubernetes $KUBERNETES_VERSION)"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-spinkube-minikube.sh: profile '$PROFILE' already running — reusing it"
else
  minikube start -p "$PROFILE" \
    --driver=docker \
    --container-runtime=containerd \
    --kubernetes-version="$KUBERNETES_VERSION"
fi
kubectl get nodes

step "Step 2: build + push the Spin OCI artifact (needs gh auth)"
"$SPIN_APP_DIR/build.sh" --push
assert_file "$SPIN_APP_WASM" "cargo-spin.wasm"

step "Step 3: install the full SpinKube stack (cert-manager, runtime-class-manager + shim, spin-operator)"
PROFILE="$PROFILE" "$SCRIPT_DIR/install-spinkube.sh"

step "Step 3b: ingress-nginx addon"
minikube addons enable ingress -p "$PROFILE"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

step "Step 4: deploy the SpinApp (overlays/minikube)"
# The ingress-nginx admission webhook can refuse connections for a few seconds
# after the controller rollout reports complete; retry the apply until it lands.
apply_waited=0
until kubectl apply -k "$SCRIPT_DIR/overlays/minikube"; do
  (( apply_waited >= 120 )) && { echo "verify-spinkube-minikube.sh: FAIL — overlay apply did not succeed within 120s" >&2; exit 1; }
  echo "verify-spinkube-minikube.sh: apply failed (ingress webhook likely not ready yet) — retrying in 5s"
  sleep 5; apply_waited=$(( apply_waited + 5 ))
done
kubectl rollout status "deployment/$SPINAPP_NAME" -n "$SPINAPP_NAMESPACE" --timeout=180s
kubectl get spinapp,deploy,svc,ingress -n "$SPINAPP_NAMESPACE" -o wide

step "Step 5: resolve + patch the Ingress to the live nip.io host"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
CARGO_SPIN_HOST="cargo-spin.${MINIKUBE_IP}.nip.io"
echo "verify-spinkube-minikube.sh: minikube ip = $MINIKUBE_IP"
echo "verify-spinkube-minikube.sh: cargo-spin ingress host = http://$CARGO_SPIN_HOST/"
kubectl patch ingress "$SPINAPP_NAME" -n "$SPINAPP_NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$CARGO_SPIN_HOST\"}]"

# Wait until ingress-nginx is actually routing OUR rule (not the default
# backend) — the affinity cookie is stamped only on responses that went
# through this Ingress, a deterministic "the async config reload has
# happened" signal (same pattern as Part 5's verify-minikube.sh).
waited=0; ok=0
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "http://$CARGO_SPIN_HOST$VALID_PATH" 2>/dev/null | grep -qi "$SPIN_INGRESS_AFFINITY_COOKIE"; then
    ok=1; break
  fi
  sleep 2; waited=$(( waited + 2 ))
done
[[ "$ok" -eq 1 ]] || { echo "verify-spinkube-minikube.sh: FAIL — ingress never routed Host $CARGO_SPIN_HOST (no affinity cookie) within 90s" >&2; exit 1; }
echo "verify-spinkube-minikube.sh: ingress routing confirmed for Host $CARGO_SPIN_HOST after ${waited}s"

step "Step 6: live HTTP assertions through the ingress (readiness = a real 200)"
BASE="http://$CARGO_SPIN_HOST"
wait_for_200 "$BASE$VALID_PATH" 90
body="$(curl_body "$BASE$VALID_PATH")"
echo "verify-spinkube-minikube.sh: GET $VALID_PATH -> $body"
assert_eq "$EXPECTED_JSON" "$body" "SpinKube GET $VALID_PATH through ingress"
code404="$(curl_code "$BASE/cargo/NOPE")"
assert_eq "404" "$code404" "SpinKube GET /cargo/NOPE through ingress"

echo
echo "PASS — ch26 SpinKube on minikube (docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  the cargo Spin component runs as a Pod via the spin-operator and the"
echo "  containerd-shim-spin shim (RuntimeClass '$SPIN_RUNTIMECLASS'), and GET"
echo "  $VALID_PATH through ingress-nginx returns the exact cargo JSON while"
echo "  /cargo/NOPE returns 404."
echo "exit 0"
