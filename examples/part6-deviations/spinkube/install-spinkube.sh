#!/usr/bin/env bash
# examples/part6-deviations/spinkube/install-spinkube.sh
#
# Install the full SpinKube platform onto the running Part 5 minikube profile,
# in the order the upstream docs require, waiting on real proof at every step
# (never a fixed sleep):
#
#   1. cert-manager (spin-operator's webhook prerequisite) — apply the pinned
#      static manifest, wait for its three Deployments to roll out, then prove
#      the webhook actually ADMITS Certificate/Issuer writes with a throwaway
#      self-signed Certificate (not just that the Pods report Ready). If that
#      smoke test fails, fall back to CERT_MANAGER_VERSION_FALLBACK and retry
#      once; whichever version passes is reported on stdout.
#   2. runtime-class-manager (Helm) + the pinned containerd-shim-spin Shim
#      manifest + node labels, then wait for the RuntimeClass it provisions.
#   3. spin-operator CRDs + the shim-executor manifest (SpinAppExecutor
#      'containerd-shim-spin') + the operator chart itself (Helm --wait).
#   4. the ghcr-pull image-pull secret the SpinApp (a private ghcr package)
#      references, created from `gh auth token` — same pattern used throughout
#      this book (Part 5 OpenShift, ch25 Istio) for private cargo-* packages.
#
# Idempotent: every apply/upgrade --install is safe to re-run.
#
# Usage: PROFILE=part5 ./install-spinkube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd helm
require_cmd curl
require_cmd gh

kubectl get nodes >/dev/null || { echo "install-spinkube.sh: FAIL — minikube profile '$PROFILE' is not reachable" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. cert-manager
# ---------------------------------------------------------------------------

install_cert_manager() {
  local version="$1"
  echo "install-spinkube.sh: applying cert-manager $version"
  kubectl apply -f "$(CERT_MANAGER_MANIFEST_URL "$version")"
  kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
  kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
  kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s
}

# cert_manager_smoke_ok — prove the webhook ADMITS Certificate/Issuer writes
# (a Pod rollout alone only proves the webhook process is up, not that its
# admission logic accepts the CRs spin-operator's chart will create) by
# issuing a throwaway self-signed certificate in a scratch namespace and
# waiting for it to go Ready. Always cleans up the scratch namespace.
cert_manager_smoke_ok() {
  local ns="cert-manager-smoke-$$"
  kubectl create namespace "$ns" >/dev/null 2>&1 || return 1
  if ! kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: smoke
  namespace: $ns
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: smoke
  namespace: $ns
spec:
  secretName: smoke-tls
  issuerRef:
    name: smoke
    kind: Issuer
  dnsNames:
    - smoke.example
EOF
  then
    kubectl delete namespace "$ns" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi
  local ok=1
  kubectl wait --for=condition=Ready certificate/smoke -n "$ns" --timeout=60s >/dev/null 2>&1 && ok=0
  kubectl delete namespace "$ns" --ignore-not-found >/dev/null 2>&1 || true
  return "$ok"
}

step "1/4 cert-manager (spin-operator $SPIN_OPERATOR_VERSION webhook prerequisite)"
CERT_MANAGER_INSTALLED="$CERT_MANAGER_VERSION"
install_cert_manager "$CERT_MANAGER_VERSION"
if cert_manager_smoke_ok; then
  echo "install-spinkube.sh: cert-manager $CERT_MANAGER_VERSION OK — webhook admits Certificate writes"
else
  echo "install-spinkube.sh: cert-manager $CERT_MANAGER_VERSION webhook smoke test FAILED — falling back to $CERT_MANAGER_VERSION_FALLBACK" >&2
  kubectl delete -f "$(CERT_MANAGER_MANIFEST_URL "$CERT_MANAGER_VERSION")" --ignore-not-found >/dev/null 2>&1 || true
  install_cert_manager "$CERT_MANAGER_VERSION_FALLBACK"
  cert_manager_smoke_ok || { echo "install-spinkube.sh: FAIL — cert-manager $CERT_MANAGER_VERSION_FALLBACK webhook smoke test also failed (kubectl get pods -n cert-manager)" >&2; exit 1; }
  CERT_MANAGER_INSTALLED="$CERT_MANAGER_VERSION_FALLBACK"
  echo "install-spinkube.sh: cert-manager $CERT_MANAGER_VERSION_FALLBACK OK (fallback) — webhook admits Certificate writes"
fi
echo "install-spinkube.sh: cert-manager version installed = $CERT_MANAGER_INSTALLED"

# ---------------------------------------------------------------------------
# 2. runtime-class-manager + the containerd-shim-spin Shim + node labels
# ---------------------------------------------------------------------------

step "2/4 runtime-class-manager $RUNTIME_CLASS_MANAGER_VERSION (Helm)"
helm upgrade --install runtime-class-manager "$RUNTIME_CLASS_MANAGER_CHART" \
  --version "$RUNTIME_CLASS_MANAGER_VERSION" \
  --namespace "$RUNTIME_CLASS_MANAGER_NAMESPACE" --create-namespace \
  --wait --timeout 5m
echo "install-spinkube.sh: runtime-class-manager $RUNTIME_CLASS_MANAGER_VERSION installed (namespace $RUNTIME_CLASS_MANAGER_NAMESPACE)"

step "2b/4 Shim CR for containerd-shim-spin $SHIM_SPIN_VERSION + node labels ($SHIM_SPIN_NODE_LABEL)"
kubectl apply -f "$SHIM_SPIN_MANIFEST_URL"
kubectl label node --all "$SHIM_SPIN_NODE_LABEL" --overwrite

echo "install-spinkube.sh: waiting for RuntimeClass '$SPIN_RUNTIMECLASS' (runtime-class-manager provisions it once the shim is installed on a labeled node) ..."
wait_for_resource 300 "RuntimeClass '$SPIN_RUNTIMECLASS' present" runtimeclass "$SPIN_RUNTIMECLASS" \
  || { echo "install-spinkube.sh: FAIL — debug with: kubectl get shims.runtime-class-manager.spinframework.dev -A; kubectl get pods -n $RUNTIME_CLASS_MANAGER_NAMESPACE" >&2; exit 1; }
kubectl get runtimeclass "$SPIN_RUNTIMECLASS"

# ---------------------------------------------------------------------------
# 3. spin-operator CRDs + shim-executor + the operator chart
# ---------------------------------------------------------------------------

step "3/4 spin-operator $SPIN_OPERATOR_VERSION CRDs + shim-executor ($SPIN_EXECUTOR) + Helm"
kubectl apply -f "$SPIN_OPERATOR_CRDS_URL"
kubectl apply -f "$SPIN_OPERATOR_SHIM_EXECUTOR_URL"
helm upgrade --install spin-operator "$SPIN_OPERATOR_CHART" \
  --version "$SPIN_OPERATOR_VERSION" \
  --namespace "$SPIN_OPERATOR_NAMESPACE" --create-namespace \
  --wait --timeout 5m
echo "install-spinkube.sh: spin-operator $SPIN_OPERATOR_VERSION installed (namespace $SPIN_OPERATOR_NAMESPACE)"
kubectl get pods -n "$SPIN_OPERATOR_NAMESPACE"

# ---------------------------------------------------------------------------
# 4. ghcr-pull image-pull secret for the private cargo-spin package
# ---------------------------------------------------------------------------

step "4/4 ghcr-pull secret ($PULL_SECRET) in $SPINAPP_NAMESPACE"
TOKEN="$(gh auth token 2>/dev/null)" || { echo "install-spinkube.sh: FAIL — gh auth token failed; run 'gh auth login' first" >&2; exit 1; }
kubectl create namespace "$SPINAPP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret docker-registry "$PULL_SECRET" \
  --docker-server=ghcr.io --docker-username="$GHCR_OWNER" --docker-password="$TOKEN" \
  -n "$SPINAPP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo "install-spinkube.sh: pull secret '$PULL_SECRET' applied in namespace '$SPINAPP_NAMESPACE'"

echo
echo "install-spinkube.sh: OK — cert-manager $CERT_MANAGER_INSTALLED, runtime-class-manager"
echo "  $RUNTIME_CLASS_MANAGER_VERSION, RuntimeClass '$SPIN_RUNTIMECLASS', spin-operator"
echo "  $SPIN_OPERATOR_VERSION (executor '$SPIN_EXECUTOR') all installed on profile '$PROFILE'."
echo "  next: kubectl apply -k overlays/minikube"
