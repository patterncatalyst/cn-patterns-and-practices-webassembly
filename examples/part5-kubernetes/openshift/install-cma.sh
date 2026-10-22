#!/usr/bin/env bash
# examples/part5-kubernetes/openshift/install-cma.sh
#
# Install the OpenShift Custom Metrics Autoscaler Operator (Red Hat's
# supported KEDA distribution) on OpenShift Local (CRC) — the ch23 CRC
# counterpart to ../k8s/keda/install-keda.sh's upstream Helm charts. Pinned
# CSV, Manual approval, approve ONLY the named InstallPlan — the house
# OperatorHub convention (see the lgtm-crc skill): never let a Subscription
# silently ride a channel to whatever is newest.
#
# TEACHING POINT carried over from ../k8s/keda/base/kafka-scaledobject.yaml:
# on CRC the Kafka-half asymmetry is even sharper than on minikube — there is
# no RuntimeClass/shim Deployment AT ALL for the wasmCloud workload (ch19 runs
# the wasmCloud OPERATOR here, never a plain Deployment-backed Pod), so a
# Custom-Metrics-Autoscaler `ScaledObject` has exactly as little to scale here
# as KEDA's upstream `kafka` scaler does on minikube — this operator is
# installed for the SAME observational/vocabulary reason, not because it can
# own kafka-handler's replica count (wadm does, via wadm-kafka.yaml's
# spreadscaler — identical reasoning to the minikube half).
#
# TBD-confirm-at-kickoff: the exact `startingCSV` string below
# (custom-metrics-autoscaler.v2.17.2-2) was the latest version this survey
# could confirm existed (Red Hat advisory RHSA-2025:16124, 2025-09-25, with a
# no-code-change rebuild on 2025-10-21) but no single source confirmed the
# PRECISE catalog CSV name on the "stable" channel at kickoff — run
# `oc get packagemanifest custom-metrics-autoscaler -n openshift-marketplace
# -o jsonpath='{.status.channels[?(@.name=="stable")].currentCSV}'` on the live
# cluster and correct this constant before the live run if it differs.
#
# Author-only (this BUILD pass does not touch a cluster): a later verify/
# capture run on an actual CRC instance exercises this script for real.
#
#   eval "$(crc oc-env)"
#   ./openshift/install-cma.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
command -v oc >/dev/null 2>&1 || fail "oc not on PATH"

CMA_NAMESPACE="${CMA_NAMESPACE:-openshift-keda}"
CMA_CHANNEL="${CMA_CHANNEL:-stable}"
CMA_STARTING_CSV="${CMA_STARTING_CSV:-custom-metrics-autoscaler.v2.17.2-2}"

step "0/4 Namespace + OperatorGroup ($CMA_NAMESPACE)"
oc apply -f - >/dev/null <<EOF || fail "apply namespace/OperatorGroup"
apiVersion: v1
kind: Namespace
metadata:
  name: $CMA_NAMESPACE
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-keda-operatorgroup
  namespace: $CMA_NAMESPACE
spec:
  targetNamespaces:
    - $CMA_NAMESPACE
EOF
ok "namespace + OperatorGroup applied"

step "1/4 Subscription (channel $CMA_CHANNEL, pinned CSV $CMA_STARTING_CSV, Manual approval)"
oc apply -f - >/dev/null <<EOF || fail "apply Subscription"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-custom-metrics-autoscaler-operator
  namespace: $CMA_NAMESPACE
spec:
  channel: $CMA_CHANNEL
  name: openshift-custom-metrics-autoscaler-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  startingCSV: $CMA_STARTING_CSV
EOF
ok "Subscription applied (installPlanApproval: Manual)"

step "2/4 Approving ONLY the InstallPlan for $CMA_STARTING_CSV"
wait_for 180 "InstallPlan for $CMA_STARTING_CSV to appear" \
  bash -c "oc get installplan -n '$CMA_NAMESPACE' -o jsonpath='{.items[*].spec.clusterServiceVersionNames}' 2>/dev/null | grep -q '$CMA_STARTING_CSV'"
PLAN="$(oc get installplan -n "$CMA_NAMESPACE" \
  -o jsonpath="{.items[?(@.spec.clusterServiceVersionNames[0]==\"$CMA_STARTING_CSV\")].metadata.name}")"
[[ -n "$PLAN" ]] || fail "no InstallPlan found naming $CMA_STARTING_CSV (oc get installplan -n $CMA_NAMESPACE)"
oc patch installplan "$PLAN" -n "$CMA_NAMESPACE" --type merge -p '{"spec":{"approved":true}}' >/dev/null \
  || fail "approve InstallPlan $PLAN"
ok "InstallPlan $PLAN approved (names ONLY $CMA_STARTING_CSV)"

step "3/4 Waiting for the CSV to reach Succeeded"
wait_for 300 "CSV $CMA_STARTING_CSV Succeeded" \
  bash -c "oc get csv '$CMA_STARTING_CSV' -n '$CMA_NAMESPACE' -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Succeeded"
ok "CSV $CMA_STARTING_CSV Succeeded"

step "4/4 KedaController (operator-managed KEDA core + metrics adapter)"
oc apply -f - >/dev/null <<EOF || fail "apply KedaController"
apiVersion: keda.sh/v1alpha1
kind: KedaController
metadata:
  name: keda
  namespace: $CMA_NAMESPACE
spec:
  watchNamespace: ""
  operator:
    logLevel: info
  metricsServer:
    logLevel: "0"
EOF
wait_for 300 "KedaController $CMA_NAMESPACE/keda ready" \
  oc get deploy -n "$CMA_NAMESPACE" -l app=keda-operator
ok "Custom Metrics Autoscaler ($CMA_STARTING_CSV) installed in $CMA_NAMESPACE"

printf '    next: oc apply -f ./wadm-kafka.yaml  (reuses the ch19 wasmCloud setup)\n'
