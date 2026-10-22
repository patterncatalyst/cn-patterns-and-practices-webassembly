#!/usr/bin/env bash
# examples/part6-deviations/spinkube/lib.sh
#
# Shared helpers for the SpinKube minikube scripts (install-spinkube.sh,
# verify-spinkube-minikube.sh, capture-evidence.sh, teardown.sh).
#
# Reuses the Part 5 minikube profile conventions — PROFILE, KUBERNETES_VERSION,
# MINIKUBE_MIN, the `kubectl` wrapper that always targets this profile's
# context explicitly, `step()` banners, EXPECTED_JSON/VALID_PATH (the SAME
# cargo contract response every Part 2-5 example serves), and the
# curl_code/curl_body/wait_for_200 readiness-gates-on-a-real-200 helpers — from
# ../../part5-kubernetes/k8s/lib.sh rather than duplicating them. This is the
# SAME minikube cluster (docker driver, containerd runtime, the pinned
# Kubernetes version, ingress-nginx) as Part 5; SpinKube is a second,
# independent workload (cargo-spin, run by an entirely different shim) layered
# onto it, the way ch25's Istio deviation layers a mesh onto the same profile
# instead of standing up a second cluster.
#
# `bash -n` clean: a repo check runs `bash -n` on every *.sh in the tree.
set -euo pipefail

LIB_SPINKUBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPINKUBE_DIR="$LIB_SPINKUBE_DIR"
SPIN_APP_DIR="$(cd "$SPINKUBE_DIR/../spin" && pwd)"
export LIB_SPINKUBE_DIR SPINKUBE_DIR SPIN_APP_DIR

# shellcheck source=../../part5-kubernetes/k8s/lib.sh
source "$SPINKUBE_DIR/../../part5-kubernetes/k8s/lib.sh"

# Every helm call targets this profile's context explicitly, same discipline
# as the `kubectl` wrapper above (sourced from Part 5's lib.sh).
helm() { command helm --kube-context "$PROFILE" "$@"; }

# ---------------------------------------------------------------------------
# Pins — the SpinKube stack (see README "Pinned versions"). A later executor
# copies these into _plans/version-matrix.md.
# ---------------------------------------------------------------------------

# cert-manager — a spin-operator v0.6.1 webhook prerequisite (its chart
# provisions the webhook's serving certificate via a cert-manager Certificate).
# Primary pin v1.21.2; if its webhook does not admit that Certificate (a
# cert-manager/spin-operator API skew), install-spinkube.sh falls back to
# v1.20.0 and reports which version it actually installed.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
CERT_MANAGER_VERSION_FALLBACK="${CERT_MANAGER_VERSION_FALLBACK:-v1.20.0}"
CERT_MANAGER_MANIFEST_URL() { echo "https://github.com/cert-manager/cert-manager/releases/download/$1/cert-manager.yaml"; }

# runtime-class-manager — installs the node-level containerd-shim-spin binary
# via a Shim custom resource + node labels, then provisions the RuntimeClass
# once the shim is confirmed on a labeled node.
RUNTIME_CLASS_MANAGER_VERSION="${RUNTIME_CLASS_MANAGER_VERSION:-0.2.0}"
RUNTIME_CLASS_MANAGER_CHART="${RUNTIME_CLASS_MANAGER_CHART:-oci://ghcr.io/spinframework/charts/runtime-class-manager}"
RUNTIME_CLASS_MANAGER_NAMESPACE="${RUNTIME_CLASS_MANAGER_NAMESPACE:-runtime-class-manager}"

# containerd-shim-spin — embeds Spin 4.1.0 (WASIp3 / wasi:http@0.3.0), which
# cargo-spin.wasm's exported ABI requires (spin-sdk = "=7.0.0"; see
# ../spin/src/lib.rs). The pinned release ships a ready-to-apply Shim manifest
# for runtime-class-manager — no hand-authored CR needed.
SHIM_SPIN_VERSION="${SHIM_SPIN_VERSION:-v0.26.0}"
SHIM_SPIN_MANIFEST_URL="https://github.com/spinframework/containerd-shim-spin/releases/download/${SHIM_SPIN_VERSION}/runtime-class-manager-shim-v1alpha1-${SHIM_SPIN_VERSION}.yaml"
SHIM_SPIN_NODE_LABEL="${SHIM_SPIN_NODE_LABEL:-spin=true}"
# The RuntimeClass runtime-class-manager provisions once the shim is installed
# on a node matching the Shim's node selector (handler: spin ->
# io.containerd.spin.v2 -> containerd-shim-spin-v2 on the node's PATH).
SPIN_RUNTIMECLASS="${SPIN_RUNTIMECLASS:-wasmtime-spin-v2}"

# spin-operator — the SpinApp/SpinAppExecutor CRDs + the controller that
# reconciles a SpinApp into a Deployment + Service.
SPIN_OPERATOR_VERSION="${SPIN_OPERATOR_VERSION:-0.6.1}"
SPIN_OPERATOR_CHART="${SPIN_OPERATOR_CHART:-oci://ghcr.io/spinframework/charts/spin-operator}"
SPIN_OPERATOR_NAMESPACE="${SPIN_OPERATOR_NAMESPACE:-spin-operator}"
SPIN_OPERATOR_CRDS_URL="https://github.com/spinframework/spin-operator/releases/download/v${SPIN_OPERATOR_VERSION}/spin-operator.crds.yaml"
SPIN_OPERATOR_SHIM_EXECUTOR_URL="https://github.com/spinframework/spin-operator/releases/download/v${SPIN_OPERATOR_VERSION}/spin-operator.shim-executor.yaml"
# The SpinAppExecutor name the shim-executor manifest ships; SpinApp.spec.executor
# references it by name.
SPIN_EXECUTOR="${SPIN_EXECUTOR:-containerd-shim-spin}"

# ---------------------------------------------------------------------------
# The app this stack deploys — a Fermyon Spin HTTP component (ch26), NOT the
# containerd-shim-wasmtime Pod Part 5 runs. Same cargo contract/JSON (shared
# VALID_PATH/EXPECTED_JSON from Part 5's lib.sh), different runtime and
# packaging: a Spin OCI artifact pulled straight from ghcr by the operator, not
# an image `minikube image load`-ed into the node.
# ---------------------------------------------------------------------------
SPINAPP_NAMESPACE="${SPINAPP_NAMESPACE:-part6-spin}"
SPINAPP_NAME="${SPINAPP_NAME:-cargo-spin}"
GHCR_OWNER="${GHCR_OWNER:-patterncatalyst}"
SPIN_IMAGE_REF="${SPIN_IMAGE_REF:-ghcr.io/$GHCR_OWNER/cargo-spin:spinkube}"
PULL_SECRET="${PULL_SECRET:-ghcr-pull}"
SPIN_APP_WASM="$SPIN_APP_DIR/cargo-spin.wasm"
SPIN_INGRESS_AFFINITY_COOKIE="${SPIN_INGRESS_AFFINITY_COOKIE:-part6-spin-affinity}"

# wait_for_resource <timeout_secs> <description> <kubectl-get-args...> — poll
# every 5s until `kubectl get <args>` succeeds. The generic "wait on proof, not
# time" gate for cluster objects that have no rollout/condition to wait on
# directly (e.g. a RuntimeClass a controller provisions asynchronously).
wait_for_resource() {
  local timeout="$1" what="$2"; shift 2
  local waited=0
  until kubectl get "$@" >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      echo "lib.sh: FAIL — timed out after ${timeout}s waiting for $what" >&2
      return 1
    fi
    sleep 5; waited=$(( waited + 5 ))
  done
  echo "lib.sh: ok — $what (after ${waited}s)" >&2
}
