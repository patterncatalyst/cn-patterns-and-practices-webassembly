#!/usr/bin/env bash
# examples/part3-interfaces/http-go/build.sh
#
# Build the TinyGo HTTP front door into a WebAssembly component that EXPORTS
# `wasi:http/incoming-handler` (reactor) and IMPORTS the cargo booking
# interface. Pipeline mirrors the part2 Go provider:
#   1. wit-bindgen-go regenerates bindings from the local WIT tree (wit/, which
#      includes the vendored wasi 0.2.8 set + a read-only copy of the cargo
#      contract under wit/deps/cargo).
#   2. TinyGo compiles main.go to a wasip1 *reactor* core module
#      (-buildmode=c-shared => exports _initialize). incoming-handler is a
#      reactor export, so the handler must be live before any request — the
#      heap-backed cabi_realloc is safe here (a reactor finishes _initialize
#      before any export runs).
#   3. wasm-tools embeds the local `cargo-http-go` world and wraps the module as
#      a component, adapting wasip1 -> wasip2 with the vendored reactor adapter.
#
# Re-runnable from a clean state. Requires on PATH: tinygo, wasm-tools,
# wit-bindgen-go, go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WIT_DIR="wit"
ADAPTER="adapters/wasi_snapshot_preview1.reactor.wasm"
OUT="cargo-http-go.wasm"

for tool in tinygo wasm-tools wit-bindgen-go go; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

if [[ ! -f "$ADAPTER" ]]; then
  echo "build.sh: FAIL — vendored reactor adapter missing: $ADAPTER" >&2
  exit 1
fi

echo "build.sh: [1/4] generating Go bindings from the local WIT tree ..."
wit-bindgen-go generate -o internal/http \
  -p example.com/cargo-http-go/internal/http \
  --world cargo-http-go "$WIT_DIR"

echo "build.sh: [2/4] tinygo build (wasip1 reactor core module) ..."
tinygo build -target=wasip1 -buildmode=c-shared -o core.wasm .

echo "build.sh: [3/4] embedding the cargo-http-go world ..."
wasm-tools component embed "$WIT_DIR" --world cargo-http-go core.wasm -o embedded.wasm

echo "build.sh: [4/4] creating the component (wasip1 -> wasip2 via reactor adapter) ..."
wasm-tools component new embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" \
  -o "$OUT"

rm -f core.wasm embedded.wasm

echo "build.sh: wrote $OUT"
wasm-tools validate "$OUT"
echo "build.sh: OK — $OUT is a valid component"
