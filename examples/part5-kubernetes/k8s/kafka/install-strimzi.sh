#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/kafka/install-strimzi.sh
#
# Install the pinned Strimzi Cluster Operator on minikube, via the operator's
# own combined-manifest release asset (the "quickstart" install method
# documented at strimzi.io/docs/operators/latest/deploying) rather than Helm —
# Strimzi does publish a Helm chart, but the single-YAML bundle is what
# upstream itself treats as the canonical quickstart and keeps the operator,
# its CRDs, and its RBAC pinned to one immutable asset URL per release.
#
# Author-only (this BUILD pass does not start a cluster): a later verify/
# capture run on an actual minikube profile exercises this script for real.
#
# Pinned version (surveyed live 2026-10-21, confirmed against the GitHub
# release tag and its example manifests):
#   Strimzi Cluster Operator 1.3.0
#
# CORRECTION from the original ch23 plan note: the plan assumed "Apache Kafka
# 4.1.0" for this operator line. Verified against the 1.3.0 release notes and
# its examples/kafka/kafka-single-node.yaml, Strimzi 1.3.0 supports Kafka
# 4.2.0, 4.2.1, 4.2.2, 4.3.0, and 4.3.1 — NOT 4.1.0 (4.1.x support was dropped
# in an earlier 1.x release). base/kafka.yaml therefore pins
# `spec.kafka.version: 4.3.1` / `metadataVersion: 4.3-IV0`, the exact pair
# shipped in the operator's own example for this tag. Strimzi 1.3.0 also
# requires Kubernetes >= 1.32 (satisfied: this project's KUBERNETES_VERSION is
# v1.37.1).
#
# Idempotent (kubectl apply of the combined manifest, namespace-retargeted via
# sed, matching upstream's own quickstart recipe). Never starts/stops the
# cluster; targets whatever context $PROFILE resolves to (see ../lib.sh).
#
#   PROFILE=part5 ./install-strimzi.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

for tool in kubectl curl; do
  require_cmd "$tool"
done

# k8s/lib.sh does not define ok/fail (only openshift/lib.sh does); small local
# echoes matching that same convention.
ok()   { printf '    \xe2\x9c\x93 %s\n' "$1"; }
fail() { printf '\n\xe2\x9c\x97 %s\n' "$1" >&2; exit 1; }

STRIMZI_VERSION="${STRIMZI_VERSION:-1.3.0}"
KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
STRIMZI_MANIFEST_URL="${STRIMZI_MANIFEST_URL:-https://github.com/strimzi/strimzi-kafka-operator/releases/download/${STRIMZI_VERSION}/strimzi-cluster-operator-${STRIMZI_VERSION}.yaml}"

kubectl() { command kubectl --context "$PROFILE" "$@"; }

step "0/3 Namespace $KAFKA_NAMESPACE"
kubectl create namespace "$KAFKA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "namespace $KAFKA_NAMESPACE present"

step "1/3 Strimzi Cluster Operator $STRIMZI_VERSION (namespace-scoped install)"
# Upstream's own quickstart: download the combined operator+CRDs+RBAC
# manifest for this exact tag and retarget every "namespace: myproject"
# placeholder to our Kafka namespace before applying — nothing here reaches
# out to a registry Helm doesn't already pin, and the manifest URL is
# versioned so re-running never silently picks up a newer operator.
TMP_MANIFEST="$(mktemp -t strimzi-operator.XXXXXX.yaml)"
trap 'rm -f "$TMP_MANIFEST"' EXIT
curl -fsSL "$STRIMZI_MANIFEST_URL" -o "$TMP_MANIFEST" \
  || fail "download of $STRIMZI_MANIFEST_URL failed"
sed -i "s/namespace: .*/namespace: $KAFKA_NAMESPACE/" "$TMP_MANIFEST"
kubectl apply -f "$TMP_MANIFEST" -n "$KAFKA_NAMESPACE" >/dev/null
ok "Strimzi $STRIMZI_VERSION manifest applied"

step "2/3 Waiting for the cluster operator Deployment"
kubectl rollout status deployment/strimzi-cluster-operator -n "$KAFKA_NAMESPACE" --timeout=300s
ok "strimzi-cluster-operator $STRIMZI_VERSION ready"

step "3/3 CRDs present (Kafka, KafkaNodePool, KafkaTopic)"
kubectl get crd kafkas.kafka.strimzi.io kafkanodepools.kafka.strimzi.io kafkatopics.kafka.strimzi.io >/dev/null
ok "Strimzi CRDs installed"

printf '    next: kubectl apply -k ./base  (single-node KRaft Kafka + the multi-partition topic)\n'
