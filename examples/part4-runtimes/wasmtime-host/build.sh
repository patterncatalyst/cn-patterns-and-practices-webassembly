#!/usr/bin/env bash
# examples/part4-runtimes/wasmtime-host/build.sh
#
# Build the ch14 embedding example and run it. Two crates:
#   guest/ — a WebAssembly component (cargo-component) that targets the LOCAL
#            host-demo world (wit/host-world.wit): it IMPORTS host-caps and
#            EXPORTS run. The repository contract (contracts/wit) is untouched.
#   host/  — a native Rust host embedding the wasmtime 50 component runtime that
#            drives the guest through four scenarios and asserts each Store/Engine
#            control fires: a host-provided import, fuel exhaustion, epoch
#            interruption, and a ResourceLimiter memory-growth denial.
#
# The host exits non-zero on any missed assertion, so this script is a CI gate.
# Re-runnable from a clean checkout. Both Cargo.lock files are committed.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

for tool in cargo cargo-component wasm-tools; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "build.sh: [1/3] building the guest component ..."
( cd guest && cargo component build --release )
GUEST="$(find "$SCRIPT_DIR/guest/target" -name 'host_demo_guest.wasm' -not -path '*/deps/*' | head -1)"
if [[ ! -s "$GUEST" ]]; then
  echo "build.sh: FAIL — guest component not produced" >&2
  exit 1
fi
wasm-tools validate "$GUEST"
echo "build.sh: guest component: $GUEST"

echo "build.sh: [2/3] building the native host ..."
( cd host && cargo build --release )
HOST="$SCRIPT_DIR/host/target/release/host-demo-host"
if [[ ! -x "$HOST" ]]; then
  echo "build.sh: FAIL — host binary not produced" >&2
  exit 1
fi

echo "build.sh: [3/3] running the host against the guest (asserts each control) ..."
"$HOST" "$GUEST"

echo "build.sh: OK — wasmtime-host (ch14) clean run + fuel + epoch + resource limiter all asserted"
