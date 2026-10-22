#!/usr/bin/env bash
# examples/part6-deviations/spinkube/teardown.sh
#
# Idempotent teardown of the ch26 SpinKube example. By default it removes the
# app (SpinApp + Ingress + namespace), the spin-operator, runtime-class-manager
# (and the RuntimeClass it provisioned), and cert-manager — leaving the
# minikube profile itself running and usable for another example (the SAME
# profile Part 5 and ch25 Istio share). Pass --delete-profile to also delete
# the whole minikube profile.
#
# Safe to run whether or not anything is up — every step tolerates "not found".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PROFILE:-part5}"
SPINAPP_NAMESPACE="${SPINAPP_NAMESPACE:-part6-spin}"
SPIN_OPERATOR_NAMESPACE="${SPIN_OPERATOR_NAMESPACE:-spin-operator}"
RUNTIME_CLASS_MANAGER_NAMESPACE="${RUNTIME_CLASS_MANAGER_NAMESPACE:-runtime-class-manager}"
SPIN_RUNTIMECLASS="${SPIN_RUNTIMECLASS:-wasmtime-spin-v2}"
SPIN_OPERATOR_VERSION="${SPIN_OPERATOR_VERSION:-0.6.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
CERT_MANAGER_VERSION_FALLBACK="${CERT_MANAGER_VERSION_FALLBACK:-v1.20.0}"

DELETE_PROFILE=0
for arg in "$@"; do
  case "$arg" in
    --delete-profile) DELETE_PROFILE=1 ;;
    -h|--help) echo "Usage: $0 [--delete-profile]"; exit 0 ;;
    *) echo "teardown.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

kubectl() { command kubectl --context "$PROFILE" "$@"; }
helm() { command helm --kube-context "$PROFILE" "$@"; }

echo "teardown.sh: removing the SpinKube app + stack from profile '$PROFILE' ..."

echo "teardown.sh: app (overlays/minikube, namespace $SPINAPP_NAMESPACE) ..."
kubectl delete -k "$SCRIPT_DIR/overlays/minikube" --ignore-not-found 2>/dev/null || true
kubectl delete namespace "$SPINAPP_NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "teardown.sh: spin-operator $SPIN_OPERATOR_VERSION (CRDs + shim-executor + chart) ..."
helm uninstall spin-operator -n "$SPIN_OPERATOR_NAMESPACE" 2>/dev/null || true
kubectl delete -f "https://github.com/spinframework/spin-operator/releases/download/v${SPIN_OPERATOR_VERSION}/spin-operator.shim-executor.yaml" --ignore-not-found 2>/dev/null || true
kubectl delete -f "https://github.com/spinframework/spin-operator/releases/download/v${SPIN_OPERATOR_VERSION}/spin-operator.crds.yaml" --ignore-not-found 2>/dev/null || true
kubectl delete namespace "$SPIN_OPERATOR_NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "teardown.sh: RuntimeClass '$SPIN_RUNTIMECLASS' + runtime-class-manager ..."
kubectl delete runtimeclass "$SPIN_RUNTIMECLASS" --ignore-not-found 2>/dev/null || true
helm uninstall runtime-class-manager -n "$RUNTIME_CLASS_MANAGER_NAMESPACE" 2>/dev/null || true
kubectl delete namespace "$RUNTIME_CLASS_MANAGER_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl label node --all spin- 2>/dev/null || true

echo "teardown.sh: cert-manager (whichever version install-spinkube.sh ended up with) ..."
kubectl delete -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" --ignore-not-found 2>/dev/null || true
kubectl delete -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION_FALLBACK}/cert-manager.yaml" --ignore-not-found 2>/dev/null || true
kubectl delete namespace cert-manager --ignore-not-found 2>/dev/null || true

if [[ "$DELETE_PROFILE" -eq 1 ]]; then
  echo "teardown.sh: --delete-profile set — deleting minikube profile '$PROFILE' ..."
  minikube delete -p "$PROFILE" 2>/dev/null || true
  echo "teardown.sh: OK — profile deleted (box clean)"
else
  echo "teardown.sh: OK — SpinKube removed; profile '$PROFILE' left running (pass --delete-profile to also delete it)"
fi
