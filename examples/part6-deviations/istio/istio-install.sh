#!/usr/bin/env bash
# examples/part6-deviations/istio/istio-install.sh
#
# Install Istio 1.31.2 onto the Part 5 minikube profile (context "$PROFILE",
# default "part5" — see ../../part5-kubernetes/k8s/lib.sh) and enable sidecar
# injection on the part5-kubernetes namespace, so the EXISTING cargo-http
# Deployment/Service/RuntimeClass (examples/part5-kubernetes/k8s/base) gets an
# Envoy sidecar on its next rollout. No new app, no new namespace — this is
# purely a mesh layered onto Part 5's unmodified deployment.
#
# AUTHOR-ONLY: this BUILD pass does not touch a cluster. A later live-verify
# pass runs this for real, against an already-running Part 5 minikube profile
# (../../part5-kubernetes/k8s/verify-minikube.sh --keep).
#
# Istio <-> Kubernetes skew (read before running):
#   Istio 1.31 officially supports Kubernetes 1.32-1.36. Part 5 pins minikube's
#   control plane to KUBERNETES_VERSION=v1.37.1 (see
#   ../../part5-kubernetes/k8s/lib.sh) — ONE minor past Istio 1.31's documented
#   ceiling. `istioctl x precheck` (step 1 below) is the gate: if it reports an
#   incompatibility, re-create the profile with a supported control-plane
#   version pinned INTO the 1.32-1.36 window before re-running this script, e.g.:
#     KUBERNETES_VERSION=v1.36.0 ../../part5-kubernetes/k8s/verify-minikube.sh --keep
#   Record whichever version this chapter actually verifies against in
#   _plans/version-matrix.md (the ch25 Istio<->k8s skew entry already flags
#   this as TBD-confirm-at-kickoff).
#
# Profile choice: `demo`, not `minimal` — base/gateway.yaml + base/
# virtualservice.yaml need istio-ingressgateway, which the `minimal` profile
# does not install.
#
# Usage: PROFILE=part5 NAMESPACE=part5-kubernetes ./istio-install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../part5-kubernetes/k8s/lib.sh
source "$SCRIPT_DIR/../../part5-kubernetes/k8s/lib.sh"

ISTIO_VERSION="${ISTIO_VERSION:-1.31.2}"
ISTIO_PROFILE="${ISTIO_PROFILE:-demo}"

require_cmd istioctl
require_cmd kubectl

step "0. tool + cluster checks"
iv="$(istioctl version --remote=false --short 2>/dev/null || echo 'v0.0.0')"
echo "istio-install.sh: istioctl reports '$iv' (pin: $ISTIO_VERSION)"
case "$iv" in
  *"$ISTIO_VERSION"*) ;;
  *) echo "istio-install.sh: WARNING — istioctl binary does not report $ISTIO_VERSION; 'istioctl install' below still pins the CONTROL PLANE image tag via --set tag=$ISTIO_VERSION, but prefer a matching istioctl binary (see lgtm feedback: upgrade the local tool, never downgrade the pin)." >&2 ;;
esac
kubectl get nodes >/dev/null || { echo "istio-install.sh: FAIL — minikube profile '$PROFILE' is not reachable" >&2; exit 1; }

step "1. istioctl x precheck (the Istio<->Kubernetes skew gate, see header note)"
istioctl x precheck --context "$PROFILE" \
  || { echo "istio-install.sh: FAIL — precheck reported a blocker; re-pin minikube's Kubernetes version into Istio 1.31's supported 1.32-1.36 window and retry (see header note)" >&2; exit 1; }
echo "istio-install.sh: precheck OK"

step "2. istioctl install (pinned $ISTIO_VERSION, profile=$ISTIO_PROFILE)"
istioctl install \
  --context "$PROFILE" \
  --set profile="$ISTIO_PROFILE" \
  --set tag="$ISTIO_VERSION" \
  --skip-confirmation
kubectl -n istio-system rollout status deployment/istiod --timeout=180s
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s

step "3. sidecar injection on namespace $NAMESPACE"
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

step "4. NodePort the ingress gateway (house rule: no port-forward; a minikube-ip + NodePort URL is the nip.io entry point)"
# The demo profile's istio-ingressgateway Service is type LoadBalancer by
# default, which stays <pending> on minikube's docker driver without a
# separate `minikube tunnel`. NodePort is the same non-port-forward,
# non-tunnel pattern Part 5 uses via the minikube `ingress` addon — K8s
# auto-assigns a node port per existing Service port (status-port 15021,
# http2 80, https 443); verify-istio-minikube.sh reads the http2 one back
# dynamically rather than assuming a fixed number.
kubectl -n istio-system patch svc istio-ingressgateway --type=merge -p '{"spec":{"type":"NodePort"}}'
kubectl -n istio-system get svc istio-ingressgateway

step "5. roll the cargo-http Deployment so the sidecar webhook fires"
if kubectl get deployment/cargo-http -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl rollout restart deployment/cargo-http -n "$NAMESPACE"
  kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s
else
  echo "istio-install.sh: deployment/cargo-http not found yet in $NAMESPACE — apply examples/part6-deviations/istio/overlays/minikube first (kubectl apply -k overlays/minikube), which creates it with the injection label already in place; no separate restart needed in that order."
fi

echo
echo "istio-install.sh: OK — Istio $ISTIO_VERSION ($ISTIO_PROFILE profile) installed on profile '$PROFILE';"
echo "  namespace '$NAMESPACE' has istio-injection=enabled; istio-ingressgateway is NodePort."
echo "  next: kubectl apply -k overlays/minikube && ./verify-istio-minikube.sh"
