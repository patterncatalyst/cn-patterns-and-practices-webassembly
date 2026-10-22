#!/usr/bin/env bash
#
# examples/part6-deviations/istio/install-ossm.sh
#
# Install OpenShift Service Mesh 3 (the Sail operator's distribution of Istio
# 1.31.2) on OpenShift Local (CRC) and prepare the istio-ingressgateway to run
# the ch25 proxy-wasm filter. This is the CRC counterpart to ./istio-install.sh.
# Pinned CSV, Manual approval, approve ONLY the named InstallPlan — the house
# OperatorHub convention (see the lgtm-crc skill and
# ../../part5-kubernetes/openshift/install-cma.sh).
#
# NO sidecar injection on the wasmCloud namespace: the same gateway-level
# filter design as minikube (see ../gateway-wasmplugin.yaml and
# ../README-istio.md) keeps this book's two cluster paths architecturally
# aligned: the filter always runs in the ingress gateway's Envoy
# (openshift/wasmplugin.yaml, istio-system), never on deploy/$HOSTCFG. This
# script therefore never labels $NS for injection and never restarts
# deploy/$HOSTCFG for a sidecar.
#
# Prerequisite: ../../part5-kubernetes/openshift/install-operator.sh AND
# ../../part5-kubernetes/openshift/deploy.sh already applied — the wasmCloud
# platform + the cargo-http app must already be running in namespace "$NS"
# before ../verify-istio-crc.sh can route to it.
#
# TBD-confirm-at-kickoff: the exact Subscription `channel` / `startingCSV` for
# OpenShift Service Mesh 3 (OperatorHub package `servicemeshoperator3`) — this
# BUILD pass has no live cluster to query. Before the live run, confirm with:
#   oc get packagemanifest servicemeshoperator3 -n openshift-marketplace \
#     -o jsonpath='{.status.channels[?(@.name=="stable")].currentCSV}'
# and correct OSSM_STARTING_CSV below if it differs — same Manual-approval,
# approve-only-the-named-InstallPlan convention as
# ../../part5-kubernetes/openshift/install-cma.sh.
#
# Idempotent (oc apply). Never starts/stops the cluster.
#
#   eval "$(crc oc-env)"
#   ./install-ossm.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../part5-kubernetes/openshift/lib.sh"

require_crc
command -v oc >/dev/null 2>&1 || fail "oc not on PATH"

OSSM_NAMESPACE="${OSSM_NAMESPACE:-openshift-operators}"
OSSM_CHANNEL="${OSSM_CHANNEL:-stable}"
OSSM_STARTING_CSV="${OSSM_STARTING_CSV:-servicemeshoperator3.v3.1.0}"
ISTIO_VERSION="${ISTIO_VERSION:-v1.31.2}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
ISTIO_CNI_NS="${ISTIO_CNI_NS:-istio-cni}"

step "0/6 Namespaces for the control plane ($ISTIO_NS) + CNI ($ISTIO_CNI_NS)"
for n in "$ISTIO_NS" "$ISTIO_CNI_NS"; do
    oc get namespace "$n" >/dev/null 2>&1 && { ok "namespace $n exists"; continue; }
    oc create namespace "$n" >/dev/null || fail "oc create namespace $n"
    ok "namespace $n created"
done

step "1/6 Subscription (channel $OSSM_CHANNEL, pinned CSV $OSSM_STARTING_CSV, Manual approval)"
# openshift-operators is the pre-existing cluster-wide OperatorGroup namespace
# (every cluster-scoped OLM operator this book installs lands here, same
# convention as the Custom Metrics Autoscaler operator) — the Sail operator
# then manages Istio/IstioCNI resources cluster-wide from its own namespace,
# referencing $ISTIO_NS / $ISTIO_CNI_NS via spec.namespace on the CRs below.
oc apply -f - >/dev/null <<EOF || fail "apply Subscription"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: $OSSM_NAMESPACE
spec:
  channel: $OSSM_CHANNEL
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  startingCSV: $OSSM_STARTING_CSV
EOF
ok "Subscription applied (installPlanApproval: Manual)"

step "2/6 Approving ONLY the InstallPlan for $OSSM_STARTING_CSV"
wait_for 180 "InstallPlan for $OSSM_STARTING_CSV to appear" \
    bash -c "oc get installplan -n '$OSSM_NAMESPACE' -o jsonpath='{.items[*].spec.clusterServiceVersionNames}' 2>/dev/null | grep -q '$OSSM_STARTING_CSV'"
PLAN="$(oc get installplan -n "$OSSM_NAMESPACE" \
    -o jsonpath="{.items[?(@.spec.clusterServiceVersionNames[0]==\"$OSSM_STARTING_CSV\")].metadata.name}")"
[[ -n "$PLAN" ]] || fail "no InstallPlan found naming $OSSM_STARTING_CSV (oc get installplan -n $OSSM_NAMESPACE)"
oc patch installplan "$PLAN" -n "$OSSM_NAMESPACE" --type merge -p '{"spec":{"approved":true}}' >/dev/null \
    || fail "approve InstallPlan $PLAN"
ok "InstallPlan $PLAN approved (names ONLY $OSSM_STARTING_CSV)"

step "3/6 Waiting for the CSV to reach Succeeded"
wait_for 300 "CSV $OSSM_STARTING_CSV Succeeded" \
    bash -c "oc get csv '$OSSM_STARTING_CSV' -n '$OSSM_NAMESPACE' -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Succeeded"
ok "CSV $OSSM_STARTING_CSV Succeeded"

step "4/6 Istio + IstioCNI custom resources (sailoperator.io/v1, pinned $ISTIO_VERSION)"
oc apply -f - >/dev/null <<EOF || fail "apply IstioCNI"
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: $ISTIO_VERSION
  namespace: $ISTIO_CNI_NS
EOF
oc apply -f - >/dev/null <<EOF || fail "apply Istio"
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: $ISTIO_VERSION
  namespace: $ISTIO_NS
EOF
ok "IstioCNI/default + Istio/default applied"

step "5/6 Waiting for istiod + the ingress gateway"
wait_for 300 "istiod Deployment available" \
    oc wait --for=condition=available deploy -l app=istiod -n "$ISTIO_NS" --timeout=10s
wait_for 300 "istio-ingressgateway Deployment available" \
    oc wait --for=condition=available deploy -l app=istio-ingressgateway -n "$ISTIO_NS" --timeout=10s
ok "istiod + istio-ingressgateway ready in $ISTIO_NS"

step "6/6 ghcr-pull image-pull secret in $ISTIO_NS (the gateway's namespace)"
# cargo-wasmfilter is a PRIVATE ghcr package; the istio-ingressgateway Envoy's
# agent needs registry credentials to fetch it on the gateway's own WasmPlugin
# (../openshift/wasmplugin.yaml, imagePullSecret: ghcr-pull) — reusing `gh`'s
# already-authenticated token, same pattern as ../istio-install.sh's minikube
# counterpart.
oc create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username=patterncatalyst \
    --docker-password="$(gh auth token)" \
    -n "$ISTIO_NS" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null || fail "apply ghcr-pull secret in $ISTIO_NS"
ok "ghcr-pull secret present in $ISTIO_NS"
if ! oc get "deploy/$HOSTCFG" -n "$NS" >/dev/null 2>&1; then
    warn "deploy/$HOSTCFG not found yet in $NS — run ../../part5-kubernetes/openshift/install-operator.sh + deploy.sh first"
fi

printf '    next: ./verify-istio-crc.sh\n'
