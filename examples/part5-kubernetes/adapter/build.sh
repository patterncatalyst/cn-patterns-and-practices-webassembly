#!/usr/bin/env bash
# examples/part5-kubernetes/adapter/build.sh
#
# Build the ADAPTED composition and package it as a thin OCI image for the
# containerd `wasmtime` shim. The ch21 shape-translation adapter is spliced into
# the Part 2/3 recipe between the provider and the HTTP front door, via two
# `wac plug` steps:
#
#   part2 rust provider  (exports patterncatalyst:cargo/*)
#        | wac plug
#        v
#   adapter              (imports+exports patterncatalyst:cargo/*; round-trips each
#                         book-cargo canonical -> legacy -> canonical; also exports
#                         patterncatalyst:cargo-adapter/legacy)
#        | wac plug
#        v
#   part3 http-rust      (imports patterncatalyst:cargo/*, exports wasi:http)
#        =
#   app-adapted.wasm     (exports wasi:http/incoming-handler)
#
#        app-adapted.wasm ──docker build (FROM scratch)──> cargo-http-adapted:minikube
#        ──minikube image load──> node containerd store ──shim──> wasmtime serve on :8080
#
# No upstream crate is forked or edited. Output: ./app-adapted.wasm (gitignored)
# + the loaded OCI image. Pass --no-image to only (re)build app-adapted.wasm.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PART2="$SCRIPT_DIR/../../part2-building-components"
PART3="$SCRIPT_DIR/../../part3-interfaces"
OUT="$SCRIPT_DIR/app-adapted.wasm"
IMAGE="${IMAGE:-cargo-http-adapted:minikube}"

BUILD_IMAGE=1
for arg in "$@"; do
  case "$arg" in
    --no-image) BUILD_IMAGE=0 ;;
    -h|--help) echo "Usage: $0 [--no-image]"; exit 0 ;;
    *) echo "adapter/build.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in cargo cargo-component wac wasm-tools; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "adapter/build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "adapter/build.sh: [1/4] building the Part 2 Rust cargo provider (reused) ..."
( cd "$PART2/rust" && cargo component build --release )
PROVIDER="$(find "$PART2/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
[[ -s "$PROVIDER" ]] || { echo "adapter/build.sh: FAIL — provider not produced" >&2; exit 1; }

echo "adapter/build.sh: [2/4] building the shape-translation adapter ..."
cargo component build --release
ADAPTER="$(find "$SCRIPT_DIR/target" -name cargo_adapter_rust.wasm -not -path '*/deps/*' | head -1)"
[[ -s "$ADAPTER" ]] || { echo "adapter/build.sh: FAIL — adapter not produced" >&2; exit 1; }

echo "adapter/build.sh: [3/4] building the Part 3 http-rust front door (reused) ..."
( cd "$PART3/http-rust" && cargo component build --release )
HTTP="$(find "$PART3/http-rust/target" -name cargo_http_rust.wasm -not -path '*/deps/*' | head -1)"
[[ -s "$HTTP" ]] || { echo "adapter/build.sh: FAIL — http-rust not produced" >&2; exit 1; }

echo "adapter/build.sh: [4/4] composing app-adapted.wasm (wac plug: provider -> adapter -> http) ..."
TMP_PA="$(mktemp -t provider-adapter.XXXXXX.wasm)"
trap 'rm -f "$TMP_PA"' EXIT
wac plug --plug "$PROVIDER" "$ADAPTER" -o "$TMP_PA"
wac plug --plug "$TMP_PA" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "adapter/build.sh: wrote $OUT"
echo "adapter/build.sh: sha256: $SHA"
echo "adapter/build.sh: exports:"
wasm-tools component wit "$OUT" | grep -E '^\s*export' | head

if [[ "$BUILD_IMAGE" -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 || { echo "adapter/build.sh: FAIL — docker not found" >&2; exit 1; }
  echo "adapter/build.sh: packaging OCI image '$IMAGE' (FROM scratch) ..."
  docker build --provenance=false -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
  echo "adapter/build.sh: built image $IMAGE"
fi

echo "adapter/build.sh: OK — app-adapted.wasm exports wasi:http/incoming-handler (legacy round-trip interposed)"
