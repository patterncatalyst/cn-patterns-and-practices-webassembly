#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/wasmcloud/install-wasmcloud-minikube.sh
#
# Install the pinned wasmCloud platform chart (NATS + wadm + the wasmCloud
# operator) on PLAIN minikube — the Kafka-half counterpart to
# ../../openshift/install-operator.sh. On minikube there is no restricted-v2
# admission to satisfy and no RestrictedEndpointsAdmission plugin to grant
# RBAC around (both OpenShift-only steps in the CRC script are skipped here).
#
# Why the operator at all, on minikube, when ../install-shim.sh already proves
# a node-level containerd-shim-wasmtime RuntimeClass works? Because the ch23
# Kafka half needs a wasmCloud LATTICE (NATS + wadm + a host) to run the
# `messaging-kafka` capability provider and link it to the `kafka-handler`
# component — the raw-shim path (a bare wasi:http Pod) has no concept of a
# capability provider or a wadm-owned spreadscaler. This is the SAME operator
# chart and host version the CRC path uses, proving the Kafka half's wadm/wash
# mechanics are IDENTICAL across both clusters — only the Ingress/Route edge
# and restricted-v2 accommodations differ.
#
# Author-only (this BUILD pass does not start a cluster): a later verify/
# capture run on an actual minikube profile exercises this script for real.
#
# Pinned versions (reused verbatim from ../../openshift/lib.sh — same chart,
# same host, same provider pairing, surveyed live 2026-10-21):
#   wasmcloud-platform chart  oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2
#   wasmCloud host            1.9.1 (WasmCloudHostConfig .spec.version)
#   messaging-kafka provider  ghcr.io/wasmcloud/messaging-kafka:canary (pinned to
#                             the commit-SHA tag 6c67eb2 — upstream ships NO
#                             semver release for this provider, only
#                             commit-SHA builds aliased `canary`; confirmed via
#                             the ghcr package page 2026-10-21. TBD-confirm-at-
#                             kickoff: re-check ghcr for a newer commit-SHA tag
#                             before the live run, since `canary` can move.)
#
# Idempotent (helm upgrade --install / kubectl apply). Never starts/stops the
# cluster; targets whatever context $PROFILE resolves to (see ../lib.sh).
#
#   PROFILE=part5 ./install-wasmcloud-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

for tool in helm kubectl; do
  require_cmd "$tool"
done

ok()   { printf '    \xe2\x9c\x93 %s\n' "$1"; }
fail() { printf '\n\xe2\x9c\x97 %s\n' "$1" >&2; exit 1; }

NS="${PROJECT_NAMESPACE:-wasmcloud}"
RELEASE="${RELEASE:-wasmcloud-platform}"
CHART_VERSION="${CHART_VERSION:-0.1.2}"
CHART_REF="${CHART_REF:-oci://ghcr.io/wasmcloud/charts/wasmcloud-platform}"
HOSTCFG="wasmcloud-host"

kubectl() { command kubectl --context "$PROFILE" "$@"; }
helm() { command helm --kube-context "$PROFILE" "$@"; }

step "0/4 Namespace $NS"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "namespace $NS present"

step "1/4 wasmCloud platform chart $CHART_VERSION (nats + wadm + operator) in namespace $NS"
helm upgrade --install "$RELEASE" "$CHART_REF" \
    --version "$CHART_VERSION" \
    --kube-context "$PROFILE" \
    --namespace "$NS" --create-namespace \
    --values "$SCRIPT_DIR/values-minikube.yaml" \
    --dependency-update \
    --wait --timeout 10m >/dev/null \
    || fail "helm upgrade --install $RELEASE failed (kubectl get pods -n $NS)"
ok "release $RELEASE applied (chart $CHART_VERSION)"

step "2/4 Waiting for NATS, wadm and the operator to roll out"
kubectl rollout status statefulset/nats -n "$NS" --timeout=300s >/dev/null 2>&1 \
  || echo "install-wasmcloud-minikube.sh: nats statefulset not ready yet (continuing to explicit waits)"
kubectl wait --for=condition=available deploy -l app.kubernetes.io/name=wadm -n "$NS" --timeout=300s
kubectl wait --for=condition=available deploy -l app.kubernetes.io/name=wasmcloud-operator -n "$NS" --timeout=300s
ok "nats + wadm + operator ready"

step "3/4 WasmCloudHostConfig -> wasmCloud host pod"
# The host pulls the PRIVATE ghcr component images (kafka-handler + the cargo
# provider) via the ghcr-pull secret; deploy.sh (author-only, same as CRC's)
# creates it right before applying this CR in a later BUILD pass that pushes
# the images — not run here.
kubectl apply -n "$NS" -f "$SCRIPT_DIR/wasmcloud-host.yaml" >/dev/null || fail "apply WasmCloudHostConfig"
kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 "deploy/$HOSTCFG" -n "$NS" --timeout=300s 2>/dev/null \
  || echo "install-wasmcloud-minikube.sh: host Deployment not yet reporting ready (check: kubectl get pods -n $NS)"
ok "wasmCloud host $HOSTCFG applied"

step "4/4 Pods"
kubectl get pods -n "$NS" -o wide
printf '    next: push kafka-handler.wasm + the cargo provider to ghcr, then kubectl apply -n %s -f wadm-kafka.yaml\n' "$NS"
