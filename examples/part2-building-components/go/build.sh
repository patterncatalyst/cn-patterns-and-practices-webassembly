#!/usr/bin/env bash
# examples/part2-building-components/go/build.sh
#
# Build the Go cargo provider into a WebAssembly component that exports
# `world cargo` from the repository contract (../../../contracts/wit).
#
# Pipeline (see README.md for the why):
#   1. wit-bindgen-go has already generated internal/cargo from the contract
#      (regenerated here so a clean checkout is self-contained).
#   2. TinyGo compiles main.go to a wasip1 *reactor* core module
#      (-buildmode=c-shared => exports _initialize, not _start). Standard
#      `go build` (GOARCH=wasm) cannot be used: its //go:wasmexport rejects the
#      pointerful result/variant returns wit-bindgen-go emits, and GOARCH=wasm32
#      (which would allow them) has no buildable target on the installed Go.
#   3. wasm-tools embeds the contract's `cargo` world into the core module and
#      then wraps it as a component, adapting wasip1 -> wasip2 with the vendored
#      reactor adapter.
#
# Re-runnable from a clean state. Requires on PATH: tinygo, wasm-tools,
# wit-bindgen-go, go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# wit-bindgen-go and `wasm-tools component embed` read the WIT package through a
# wasmtime filesystem sandbox that only reaches paths relative to the current
# directory — an absolute path fails with "failed to find a pre-opened file
# descriptor". build.sh cd's to this directory, so these stay relative.
CONTRACT_DIR="../../../contracts/wit"
ADAPTER="adapters/wasi_snapshot_preview1.reactor.wasm"
OUT="cargo-go.wasm"

for tool in tinygo wasm-tools wit-bindgen-go go; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

if [[ ! -f "$ADAPTER" ]]; then
  echo "build.sh: FAIL — vendored adapter missing: $ADAPTER" >&2
  echo "build.sh: download it from" \
       "https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasi_snapshot_preview1.reactor.wasm" >&2
  exit 1
fi

echo "build.sh: [1/4] generating Go bindings from the contract ..."
wit-bindgen-go generate -o internal/cargo \
  -p example.com/cargo-go/internal/cargo \
  --world cargo "$CONTRACT_DIR"

echo "build.sh: [2/4] tinygo build (wasip1 reactor core module) ..."
tinygo build -target=wasip1 -buildmode=c-shared -o core.wasm .

echo "build.sh: [3/4] embedding the cargo world ..."
wasm-tools component embed "$CONTRACT_DIR" --world cargo core.wasm -o embedded.wasm

echo "build.sh: [4/4] creating the component (wasip1 -> wasip2 via adapter) ..."
wasm-tools component new embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" \
  -o "$OUT"

rm -f core.wasm embedded.wasm

echo "build.sh: wrote $OUT"
wasm-tools validate "$OUT"
echo "build.sh: OK — $OUT is a valid component"
