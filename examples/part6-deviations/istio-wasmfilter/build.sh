#!/usr/bin/env bash
# examples/part6-deviations/istio-wasmfilter/build.sh
#
# Build the proxy-wasm HTTP filter for chapter 25 (Istio + Wasm).
#
# This is deliberately the SIMPLEST build in the repo: a plain
# `cargo build --release --target wasm32-wasip1`, no `cargo component build`,
# no `wac plug`, no WIT. The crate targets the Envoy proxy-wasm ABI via the
# `proxy-wasm` crate's `main!` macro, which emits the `proxy_on_*` exports
# Envoy's proxy-wasm host calls directly — a different ABI, built with a
# different toolchain invocation, than every Component Model example in
# Parts 2-5 of this book. That contrast is the point of this crate.
#
# Output: ./target/wasm32-wasip1/release/cargo_wasmfilter.wasm
# (crate name `cargo-wasmfilter` -> cargo normalizes dashes to underscores in
# the compiled artifact's file name.)
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUT="$SCRIPT_DIR/target/wasm32-wasip1/release/cargo_wasmfilter.wasm"

for tool in cargo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "build.sh: building the proxy-wasm HTTP filter (plain cargo, wasm32-wasip1) ..."
cargo build --release --target wasm32-wasip1

if [[ ! -s "$OUT" ]]; then
  echo "build.sh: FAIL — $OUT not produced" >&2
  exit 1
fi

if command -v wasm-tools >/dev/null 2>&1; then
  echo "build.sh: validating as a core wasm module (NOT a component) ..."
  wasm-tools validate "$OUT"
fi

SIZE="$(du -h "$OUT" | cut -f1)"
SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "build.sh: wrote $OUT ($SIZE)"
echo "build.sh: sha256: $SHA"
echo "build.sh: OK — a plain proxy-wasm core module, no Component Model, no cargo-component"
