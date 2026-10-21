#!/usr/bin/env bash
#
# install-operator.sh — install the pinned wasmCloud platform chart (NATS +
# wadm + the wasmCloud operator) on OpenShift Local (CRC), under restricted-v2.
#
# This is the OpenShift counterpart to ../k8s/install-shim.sh: instead of
# installing a node-level containerd Wasm shim + RuntimeClass (which needs a
# privileged RHCOS MachineConfig that fights restricted-v2), we install the
# wasmCloud operator so an in-cluster host can run the component. deploy.sh then
# creates the host (WasmCloudHostConfig) and deploys the app onto it.
#
# Idempotent (helm upgrade --install). Never starts or stops the cluster.
#
#   eval "$(crc oc-env)"
#   ./openshift/install-operator.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
command -v helm >/dev/null 2>&1 || fail "helm not on PATH"

step "0/3 Project $NS (a normal project -> restricted-v2 enforcement)"
if oc get project "$NS" >/dev/null 2>&1; then
    ok "project $NS exists"
else
    oc new-project "$NS" --display-name="wasmCloud platform (Part 5, OpenShift Local)" >/dev/null \
        || fail "oc new-project $NS"
    ok "project $NS created"
fi

step "1/3 wasmCloud platform chart $CHART_VERSION (nats + wadm + operator) in namespace $NS"
# --dependency-update: the parent OCI chart declares nats/wadm/operator as
# dependencies; pull them at install time (CRC has egress). Pinned to
# CHART_VERSION so the operator/host/nats versions never move without an edit.
helm upgrade --install "$RELEASE" "$CHART_REF" \
    --version "$CHART_VERSION" \
    --namespace "$NS" --create-namespace \
    --values "$OPENSHIFT_DIR/values-crc.yaml" \
    --dependency-update \
    --wait --timeout 10m >/dev/null \
    || fail "helm upgrade --install $RELEASE failed (oc get pods -n $NS)"
ok "release $RELEASE applied (chart $CHART_VERSION)"

step "2/3 Waiting for NATS, wadm and the operator to roll out"
# NATS comes up as a StatefulSet; wadm and the operator as Deployments.
oc rollout status statefulset/nats -n "$NS" --timeout=300s >/dev/null 2>&1 \
    || warn "nats statefulset not ready yet (continuing to explicit waits)"
wait_for 300 "wadm Deployment available" \
    oc wait --for=condition=available deploy -l app.kubernetes.io/name=wadm -n "$NS" --timeout=10s
wait_for 300 "wasmcloud-operator Deployment available" \
    oc wait --for=condition=available deploy -l app.kubernetes.io/name=wasmcloud-operator -n "$NS" --timeout=10s
ok "nats + wadm + operator ready"

step "3/4 Operator RBAC: allow it to manage EndpointSlices to cluster-network IPs"
# OpenShift's RestrictedEndpointsAdmission rejects (403) an EndpointSlice whose
# endpoint address is in the cluster/service network unless the creating SA holds
# the endpoints(slices)/restricted permission. The wasmCloud operator builds a
# selector-less Service for the app and manually writes an EndpointSlice pointing
# at the host pod IP (a cluster-network address), so without this grant the app's
# Service has no endpoints and the Route 503s. This is a narrow network-RBAC
# grant, NOT an SCC/anyuid exception.
oc apply -f - >/dev/null <<EOF || fail "apply operator restricted-endpoints RBAC"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wasmcloud-operator-restricted-endpoints
rules:
- apiGroups: [""]
  resources: ["endpoints/restricted"]
  verbs: ["create", "update"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices/restricted"]
  verbs: ["create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wasmcloud-operator-restricted-endpoints
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wasmcloud-operator-restricted-endpoints
subjects:
- kind: ServiceAccount
  name: wasmcloud-operator
  namespace: $NS
EOF
ok "restricted-endpoints ClusterRole + binding applied (SA wasmcloud-operator/$NS)"

step "4/4 Pods + SCC (restricted-v2 expected; no anyuid exception)"
oc get pods -n "$NS" --field-selector=status.phase=Running \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,SCC:.metadata.annotations.openshift\.io/scc,UID:.spec.containers[0].securityContext.runAsUser' 2>/dev/null \
    | grep -E 'nats|wadm|operator' || true
printf '    next: ./openshift/deploy.sh\n'
