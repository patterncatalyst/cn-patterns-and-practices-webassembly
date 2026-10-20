#!/usr/bin/env bash
# examples/part2-building-components/consumer-go/build.sh
#
# Build the Go cargo CONSUMER into a WebAssembly *command* component that
# IMPORTS `world cargo-consumer` from the repository contract
# (../../../contracts/wit) and exports `wasi:cli/run`, so that — once composed
# with a `cargo` provider via `wac plug` — it is directly `wasmtime run`-able.
#
# Pipeline (see README.md for the why):
#   1. wit-bindgen-go regenerates the consumer-side bindings from the contract.
#   2. TinyGo compiles main.go to a wasip1 *command* core module (default
#      buildmode => exports _start, unlike the provider's reactor _initialize).
#   3. wasm-tools embeds the contract's `cargo-consumer` world (imports only)
#      into the core module, then wraps it as a component, adapting wasip1 ->
#      wasip2 with the vendored *command* adapter (NOT the reactor adapter): the
#      command adapter synthesizes the `wasi:cli/run` export that calls _start.
#
# Re-runnable from a clean state. Requires on PATH: tinygo, wasm-tools,
# wit-bindgen-go, go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# wit-bindgen-go and `wasm-tools component embed` read the WIT package through a
# wasmtime filesystem sandbox that only reaches paths relative to the current
# directory, so these stay relative (see README gotcha).
CONTRACT_DIR="../../../contracts/wit"
ADAPTER="adapters/wasi_snapshot_preview1.command.wasm"
OUT="cargo-consumer-go.wasm"

for tool in tinygo wasm-tools wit-bindgen-go go; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

if [[ ! -f "$ADAPTER" ]]; then
  echo "build.sh: FAIL — vendored command adapter missing: $ADAPTER" >&2
  echo "build.sh: download it from" \
       "https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasi_snapshot_preview1.command.wasm" >&2
  exit 1
fi

echo "build.sh: [1/4] generating consumer-side Go bindings from the contract ..."
wit-bindgen-go generate -o internal/cargo \
  -p example.com/cargo-consumer-go/internal/cargo \
  --world cargo-consumer "$CONTRACT_DIR"

echo "build.sh: [2/4] tinygo build (wasip1 command core module) ..."
tinygo build -target=wasip1 -o core.wasm .

echo "build.sh: [3/4] embedding the cargo-consumer world ..."
wasm-tools component embed "$CONTRACT_DIR" --world cargo-consumer core.wasm -o embedded.wasm

echo "build.sh: [4/4] creating the command component (wasip1 -> wasip2 via command adapter) ..."
wasm-tools component new embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" \
  -o "$OUT"

rm -f core.wasm embedded.wasm

echo "build.sh: wrote $OUT"
wasm-tools validate "$OUT"
echo "build.sh: OK — $OUT is a valid component"
