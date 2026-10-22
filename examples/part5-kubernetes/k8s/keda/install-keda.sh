#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/keda/install-keda.sh
#
# Install KEDA core + the KEDA HTTP add-on on minikube via pinned Helm charts.
# Author-only (this BUILD pass does not start a cluster): a later verify/
# capture run on an actual minikube profile exercises this script for real.
#
# Pinned versions (surveyed live 2026-10-21; see README "Pinned versions" once
# authored):
#   KEDA core             2.21.0  (kedacore/keda, https://kedacore.github.io/charts)
#   KEDA HTTP add-on      0.16.0  (kedacore/keda-add-ons-http, SAME repo) —
#                         requires KEDA core >= 2.21 (the add-on's chart notes
#                         this as a hard floor, not just a recommendation).
#
# KEDA core drives BOTH scale-to-zero halves of ch23:
#   * the HTTP add-on's interceptor + `HTTPScaledObject` (ch23 raw-shim half,
#     ../keda/base/httpscaledobject.yaml) — KEDA itself scales the Deployment
#     from the interceptor's queued-request metric.
#   * the `kafka` scaler + `ScaledObject` (ch23 Kafka half,
#     ../keda/base/kafka-scaledobject.yaml) — KEDA scales the cargo-kafka-host
#     Deployment on consumer-group lag.
#
# Idempotent (helm upgrade --install). Never starts/stops the cluster; targets
# whatever context $PROFILE resolves to (see ../lib.sh).
#
#   PROFILE=part5 ./install-keda.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

for tool in helm kubectl; do
  require_cmd "$tool"
done

# k8s/lib.sh does not define ok/fail (only openshift/lib.sh does); small local
# echoes matching that same convention.
ok()   { printf '    \xe2\x9c\x93 %s\n' "$1"; }
fail() { printf '\n\xe2\x9c\x97 %s\n' "$1" >&2; exit 1; }

KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"
KEDA_VERSION="${KEDA_VERSION:-2.21.0}"
KEDA_HTTP_VERSION="${KEDA_HTTP_VERSION:-0.16.0}"
KEDA_REPO_URL="${KEDA_REPO_URL:-https://kedacore.github.io/charts}"

# Every helm call targets this profile's context explicitly (house convention
# — never read/change helm's or kubectl's current-context).
helm() { command helm --kube-context "$PROFILE" "$@"; }

step "0/3 KEDA Helm repo (kedacore)"
helm repo add kedacore "$KEDA_REPO_URL" >/dev/null 2>&1 || true
helm repo update kedacore >/dev/null
ok "kedacore repo added/updated ($KEDA_REPO_URL)"

step "1/3 KEDA core $KEDA_VERSION (namespace $KEDA_NAMESPACE)"
helm upgrade --install keda kedacore/keda \
  --version "$KEDA_VERSION" \
  --namespace "$KEDA_NAMESPACE" --create-namespace \
  --wait --timeout 5m
kubectl --context "$PROFILE" rollout status deployment/keda-operator -n "$KEDA_NAMESPACE" --timeout=180s
ok "keda-operator $KEDA_VERSION ready"

step "2/3 KEDA HTTP add-on $KEDA_HTTP_VERSION (requires KEDA core >= 2.21 — satisfied)"
helm upgrade --install keda-add-ons-http kedacore/keda-add-ons-http \
  --version "$KEDA_HTTP_VERSION" \
  --namespace "$KEDA_NAMESPACE" --create-namespace \
  --wait --timeout 5m
kubectl --context "$PROFILE" rollout status deployment/keda-add-ons-http-controller-manager -n "$KEDA_NAMESPACE" --timeout=180s
kubectl --context "$PROFILE" rollout status deployment/keda-add-ons-http-interceptor -n "$KEDA_NAMESPACE" --timeout=180s
ok "keda-add-ons-http $KEDA_HTTP_VERSION ready (controller + interceptor)"

step "3/3 CRDs present (ScaledObject, TriggerAuthentication, HTTPScaledObject)"
kubectl --context "$PROFILE" get crd scaledobjects.keda.sh triggerauthentications.keda.sh httpscaledobjects.http.keda.sh >/dev/null
ok "KEDA + HTTP add-on CRDs installed"

printf '    next: kubectl apply -k ./overlays/minikube  (HTTP half)\n'
printf '    next: ../kafka/install-strimzi.sh && ./base/kafka-scaledobject.yaml (Kafka half)\n'
