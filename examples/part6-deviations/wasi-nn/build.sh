#!/usr/bin/env bash
# examples/part6-deviations/wasi-nn/build.sh
#
# Build-only: compiles the command component and statically validates its
# WIT surface. Does NOT run inference — that requires OpenVINO and a
# wasmtime built with --features wasi-nn, neither of which this script
# installs (see run.sh and README.md). This script succeeds on stable Rust
# with no OpenVINO present, because the guest only IMPORTS wasi:nn; those
# imports resolve at `wasmtime run` time on the host, not at compile time.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

for tool in cargo wasm-tools; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "wasi-nn/build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done
if ! cargo component --version >/dev/null 2>&1; then
  echo "wasi-nn/build.sh: FAIL — 'cargo component' subcommand not found on PATH" >&2
  exit 1
fi

echo "wasi-nn/build.sh: [1/3] cargo component build --release ..."
cargo component build --release

WASM="$SCRIPT_DIR/target/wasm32-wasip1/release/cargo-wasi-nn.wasm"
[[ -s "$WASM" ]] || { echo "wasi-nn/build.sh: FAIL — component not produced at $WASM" >&2; exit 1; }

echo "wasi-nn/build.sh: [2/3] wasm-tools validate ..."
wasm-tools validate "$WASM"

WIT="$(wasm-tools component wit "$WASM")"

if ! grep -q 'import wasi:nn/graph@0.2.0-rc-2024-10-28;' <<<"$WIT"; then
  echo "wasi-nn/build.sh: FAIL — component does not import wasi:nn/graph@0.2.0-rc-2024-10-28" >&2
  echo "$WIT" >&2
  exit 1
fi
if ! grep -q 'export wasi:cli/run@0.2.3;' <<<"$WIT"; then
  echo "wasi-nn/build.sh: FAIL — component does not export wasi:cli/run@0.2.3" >&2
  echo "$WIT" >&2
  exit 1
fi
NON_WASI_IMPORTS="$(grep -E '^\s*import ' <<<"$WIT" | grep -vE '^\s*import wasi:' || true)"
if [[ -n "$NON_WASI_IMPORTS" ]]; then
  echo "wasi-nn/build.sh: FAIL — component imports something other than wasi:*:" >&2
  echo "$NON_WASI_IMPORTS" >&2
  exit 1
fi

echo "wasi-nn/build.sh: [3/3] OK — imports only wasi:*, imports wasi:nn/graph@0.2.0-rc-2024-10-28, exports wasi:cli/run@0.2.3"

SHA="$(sha256sum "$WASM" | awk '{print $1}')"
echo "wasi-nn/build.sh: wrote $WASM"
echo "wasi-nn/build.sh: sha256: $SHA"
echo "wasi-nn/build.sh: imports/exports:"
grep -E '^\s*(import|export)' <<<"$WIT"

echo "wasi-nn/build.sh: build-only — run ./run.sh for the live OpenVINO inference path (requires the user's own wasmtime-from-source + OpenVINO build)."
