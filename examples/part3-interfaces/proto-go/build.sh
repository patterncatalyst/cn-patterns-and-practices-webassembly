#!/usr/bin/env bash
# examples/part3-interfaces/proto-go/build.sh
#
# Build the TinyGo protobuf codec component: EXPORTS `codec.get-cargo` and
# IMPORTS the cargo booking interface. Uses the reflection-free wire codec in
# wire.go (the reflection-based google.golang.org/protobuf traps at runtime under
# TinyGo 0.43 — see README). Reactor pipeline, same as the part2 Go provider.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WIT_DIR="wit"
ADAPTER="adapters/wasi_snapshot_preview1.reactor.wasm"
OUT="cargo-proto-go.wasm"

for tool in tinygo wasm-tools wit-bindgen-go go; do
  command -v "$tool" >/dev/null 2>&1 || { echo "build.sh: FAIL — '$tool' not on PATH" >&2; exit 1; }
done
[[ -f "$ADAPTER" ]] || { echo "build.sh: FAIL — reactor adapter missing: $ADAPTER" >&2; exit 1; }

echo "build.sh: [1/4] generating Go bindings from the local WIT tree ..."
wit-bindgen-go generate -o internal/proto \
  -p example.com/proto-go/internal/proto \
  --world cargo-proto "$WIT_DIR"

echo "build.sh: [2/4] tinygo build (wasip1 reactor core module) ..."
tinygo build -target=wasip1 -buildmode=c-shared -o core.wasm .

echo "build.sh: [3/4] embedding the cargo-proto world ..."
wasm-tools component embed "$WIT_DIR" --world cargo-proto core.wasm -o embedded.wasm

echo "build.sh: [4/4] creating the component (wasip1 -> wasip2 via reactor adapter) ..."
wasm-tools component new embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" \
  -o "$OUT"

rm -f core.wasm embedded.wasm
echo "build.sh: wrote $OUT"
wasm-tools validate "$OUT"
echo "build.sh: OK — $OUT is a valid component"
