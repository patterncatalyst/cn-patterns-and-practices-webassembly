#!/usr/bin/env bash
# examples/part5-kubernetes/sidecar-filter/build.sh
#
# Build the FILTERED composition and package it as a thin OCI image for the
# containerd `wasmtime` shim. The ch20 sidecar-filter interposer is spliced into
# the exact Part 2/3 recipe between the provider and the HTTP front door, via two
# `wac plug` steps:
#
#   part2 rust provider  (exports patterncatalyst:cargo/*)
#        | wac plug
#        v
#   sidecar-filter       (imports+exports patterncatalyst:cargo/*; embargo + log)
#        | wac plug
#        v
#   part3 http-rust      (imports patterncatalyst:cargo/*, exports wasi:http)
#        =
#   app-filtered.wasm    (exports wasi:http/incoming-handler; imports wasi:cli/stderr)
#
#        app-filtered.wasm ──docker build (FROM scratch)──> cargo-http-filtered:minikube
#        ──minikube image load──> node containerd store ──shim──> wasmtime serve on :8080
#
# None of the three upstream crates is forked or edited; they are rebuilt with
# their own recipes and plugged together. Output: ./app-filtered.wasm (gitignored)
# + the loaded OCI image. Pass --no-image to only (re)build app-filtered.wasm.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PART2="$SCRIPT_DIR/../../part2-building-components"
PART3="$SCRIPT_DIR/../../part3-interfaces"
OUT="$SCRIPT_DIR/app-filtered.wasm"
IMAGE="${IMAGE:-cargo-http-filtered:minikube}"

BUILD_IMAGE=1
for arg in "$@"; do
  case "$arg" in
    --no-image) BUILD_IMAGE=0 ;;
    -h|--help) echo "Usage: $0 [--no-image]"; exit 0 ;;
    *) echo "sidecar-filter/build.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in cargo cargo-component wac wasm-tools; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "sidecar-filter/build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "sidecar-filter/build.sh: [1/4] building the Part 2 Rust cargo provider (reused) ..."
( cd "$PART2/rust" && cargo component build --release )
PROVIDER="$(find "$PART2/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
[[ -s "$PROVIDER" ]] || { echo "sidecar-filter/build.sh: FAIL — provider not produced" >&2; exit 1; }

echo "sidecar-filter/build.sh: [2/4] building the sidecar-filter interposer ..."
cargo component build --release
FILTER="$(find "$SCRIPT_DIR/target" -name cargo_filter_rust.wasm -not -path '*/deps/*' | head -1)"
[[ -s "$FILTER" ]] || { echo "sidecar-filter/build.sh: FAIL — filter not produced" >&2; exit 1; }

echo "sidecar-filter/build.sh: [3/4] building the Part 3 http-rust front door (reused) ..."
( cd "$PART3/http-rust" && cargo component build --release )
HTTP="$(find "$PART3/http-rust/target" -name cargo_http_rust.wasm -not -path '*/deps/*' | head -1)"
[[ -s "$HTTP" ]] || { echo "sidecar-filter/build.sh: FAIL — http-rust not produced" >&2; exit 1; }

echo "sidecar-filter/build.sh: [4/4] composing app-filtered.wasm (wac plug: provider -> filter -> http) ..."
TMP_PF="$(mktemp -t provider-filter.XXXXXX.wasm)"
trap 'rm -f "$TMP_PF"' EXIT
# Step 1: the provider's cargo exports satisfy the filter's cargo imports; the
# result still EXPORTS cargo (the filter's exports).
wac plug --plug "$PROVIDER" "$FILTER" -o "$TMP_PF"
# Step 2: the filtered cargo exports satisfy the http front door's cargo imports.
wac plug --plug "$TMP_PF" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "sidecar-filter/build.sh: wrote $OUT"
echo "sidecar-filter/build.sh: sha256: $SHA"
echo "sidecar-filter/build.sh: exports:"
wasm-tools component wit "$OUT" | grep -E '^\s*export' | head

if [[ "$BUILD_IMAGE" -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 || { echo "sidecar-filter/build.sh: FAIL — docker not found" >&2; exit 1; }
  echo "sidecar-filter/build.sh: packaging OCI image '$IMAGE' (FROM scratch) ..."
  docker build --provenance=false -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
  echo "sidecar-filter/build.sh: built image $IMAGE"
fi

echo "sidecar-filter/build.sh: OK — app-filtered.wasm exports wasi:http/incoming-handler (embargo + logging interposed)"
