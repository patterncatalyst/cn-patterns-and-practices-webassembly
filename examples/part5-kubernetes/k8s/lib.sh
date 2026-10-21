#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/lib.sh
#
# Shared helpers for the Part 5 minikube scripts (install-shim.sh,
# verify-minikube.sh, capture-evidence.sh, teardown.sh). Sources the repo-wide
# examples/_lib/lib.sh for assert_eq / assert_contains / require_cmd, then adds
# the minikube/kubectl conventions this example uses:
#
#   * a `kubectl` wrapper that ALWAYS targets this profile's context explicitly
#     (kubectl's current-context is never read or changed — house convention,
#     matches the WebSockets part4-backplane and modernizing-enterprise-apps
#     deploy scripts),
#   * `step` section banners,
#   * the pins (shim version + SHA, minikube floor, kubernetes version),
#   * curl helpers that gate on a REAL HTTP 200 (readiness = a real 200, not
#     just a rollout reporting Ready).
#
# `bash -n` clean: a repo check runs `bash -n` on every *.sh in the tree.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

LIB_K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PART5_DIR="$(cd "$LIB_K8S_DIR/.." && pwd)"
export LIB_K8S_DIR PART5_DIR

# shellcheck source=../../_lib/lib.sh
source "$PART5_DIR/../_lib/lib.sh"

# ---------------------------------------------------------------------------
# Pins — the firm, live-verified Part 5 Kubernetes-tier versions. A later
# executor copies these into _plans/version-matrix.md.
# ---------------------------------------------------------------------------
PROFILE="${PROFILE:-part5}"
NAMESPACE="${NAMESPACE:-part5-kubernetes}"
MINIKUBE_MIN="v1.39.0"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.37.1}"

# runwasi containerd-shim-wasmtime — pinned release + the SHA256 of the
# x86_64-linux-musl tarball, taken verbatim from the release's SHA256SUMS.
SHIM_VERSION="${SHIM_VERSION:-v0.6.1}"
SHIM_TARBALL="containerd-shim-wasmtime-x86_64-linux-musl.tar.gz"
SHIM_URL="https://github.com/containerd/runwasi/releases/download/containerd-shim-wasmtime/${SHIM_VERSION}/${SHIM_TARBALL}"
SHIM_SHA256="a9b1215ee670f11414c8fd8e970b52679085929c8ec73a0fe6ed9cf215cf9ba1"
# The containerd runtime handler name (RuntimeClass.handler) and the shim
# binary filename containerd resolves for runtime_type io.containerd.wasmtime.v1.
SHIM_HANDLER="wasmtime"
SHIM_BINARY="containerd-shim-wasmtime-v1"

# The OCI image build.sh produces + the module path inside its rootfs.
IMAGE="${IMAGE:-cargo-http-wasm:minikube}"
MODULE_PATH="/app.wasm"

# The deployable artifact and the exact contract response (same across Parts 2-5).
APP_WASM="$PART5_DIR/app.wasm"
VALID_PATH="/cargo/CARGO-USNYC-DEHAM"
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

# Every kubectl call targets this profile's context explicitly.
kubectl() { command kubectl --context "$PROFILE" "$@"; }

step() { printf '\n=== %s ===\n' "$*"; }

# curl_code <url> [host-header] — HTTP status only (000 on failure).
curl_code() {
  local url="$1" host="${2:-}"
  if [[ -n "$host" ]]; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $host" "$url" 2>/dev/null || echo "000"
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || echo "000"
  fi
}

# curl_body <url> [host-header] — response body.
curl_body() {
  local url="$1" host="${2:-}"
  if [[ -n "$host" ]]; then
    curl -s --max-time 8 -H "Host: $host" "$url" 2>/dev/null || true
  else
    curl -s --max-time 8 "$url" 2>/dev/null || true
  fi
}

# wait_for_200 <url> <timeout_secs> [host-header] — poll until a REAL 200.
# Readiness = a real 200, not a rollout reporting Ready. Returns non-zero on
# timeout.
wait_for_200() {
  local url="$1" timeout="${2:-90}" host="${3:-}" waited=0
  while (( waited < timeout )); do
    if [[ "$(curl_code "$url" "$host")" == "200" ]]; then
      echo "lib.sh: ok — $url answered 200 after ${waited}s" >&2
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  echo "lib.sh: FAIL — $url never returned 200 within ${timeout}s" >&2
  return 1
}
