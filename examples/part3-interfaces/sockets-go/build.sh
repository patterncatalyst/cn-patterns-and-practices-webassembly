#!/usr/bin/env bash
# examples/part3-interfaces/sockets-go/build.sh
#
# Build the TinyGo outbound TCP client as a *command* component (ch13). Command
# pipeline (static bump-arena cabi_realloc, command adapter) — same as the part2
# Go consumer. Requires: tinygo, wasm-tools, wit-bindgen-go, go.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WIT_DIR="wit"
ADAPTER="adapters/wasi_snapshot_preview1.reactor.wasm"
OUT="sockets-client-go.wasm"

for tool in tinygo wasm-tools wit-bindgen-go go; do
  command -v "$tool" >/dev/null 2>&1 || { echo "build.sh: FAIL — '$tool' not on PATH" >&2; exit 1; }
done
[[ -f "$ADAPTER" ]] || { echo "build.sh: FAIL — command adapter missing: $ADAPTER" >&2; exit 1; }

echo "build.sh: [1/4] generating Go bindings from the local WIT tree ..."
wit-bindgen-go generate -o internal/sock \
  -p example.com/sockets-go/internal/sock \
  --world sockets-client-go "$WIT_DIR"

echo "build.sh: [2/4] tinygo build (wasip1 reactor core module) ..."
tinygo build -target=wasip1 -buildmode=c-shared -o core.wasm .

echo "build.sh: [3/4] embedding the sockets-client-go world ..."
wasm-tools component embed "$WIT_DIR" --world sockets-client-go core.wasm -o embedded.wasm

echo "build.sh: [4/4] creating the reactor component (wasip1 -> wasip2 via reactor adapter) ..."
wasm-tools component new embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" \
  -o "$OUT"

rm -f core.wasm embedded.wasm
echo "build.sh: wrote $OUT"
wasm-tools validate "$OUT"
echo "build.sh: OK — $OUT is a valid component"
