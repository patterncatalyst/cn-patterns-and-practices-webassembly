#!/usr/bin/env bash
# examples/part4-runtimes/wasmcloud/build.sh
#
# Build the DEPLOYABLE component `app.wasm` for the ch15 wasmCloud example.
#
# Single source of truth: this reuses the EXACT Part 3 recipe — the Part 2 Rust
# `cargo` provider composed under the Part 3 `http-rust` front door via
# `wac plug` — so the artifact that wasmCloud runs is byte-for-byte the same
# component that `wasmtime serve` runs (ch16's same-bytes claim). It does NOT
# fork or edit the component; it rebuilds the upstream crates with their own
# recipes and plugs them together.
#
#   part2 rust provider  (exports patterncatalyst:cargo/*)
#        +                 -> wac plug ->  app.wasm  (exports wasi:http/incoming-handler)
#   part3 http-rust       (imports patterncatalyst:cargo/*, exports wasi:http)
#
# Output: ./app.wasm (next to this script). Re-runnable from a clean checkout.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PART2="$SCRIPT_DIR/../../part2-building-components"
PART3="$SCRIPT_DIR/../../part3-interfaces"
OUT="$SCRIPT_DIR/app.wasm"

for tool in cargo cargo-component wac wasm-tools; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "build.sh: [1/3] building the Part 2 Rust cargo provider (reused, not edited) ..."
( cd "$PART2/rust" && cargo component build --release )
PROVIDER="$(find "$PART2/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
if [[ ! -s "$PROVIDER" ]]; then
  echo "build.sh: FAIL — part2 rust provider not produced" >&2
  exit 1
fi

echo "build.sh: [2/3] building the Part 3 http-rust front door (reused, not edited) ..."
( cd "$PART3/http-rust" && cargo component build --release )
HTTP="$(find "$PART3/http-rust/target" -name cargo_http_rust.wasm -not -path '*/deps/*' | head -1)"
if [[ ! -s "$HTTP" ]]; then
  echo "build.sh: FAIL — part3 http-rust component not produced" >&2
  exit 1
fi

echo "build.sh: [3/3] composing app.wasm (wac plug: provider -> http front door) ..."
wac plug --plug "$PROVIDER" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"

echo "build.sh: wrote $OUT"
echo "build.sh: sha256: $(sha256sum "$OUT" | awk '{print $1}')"
echo "build.sh: exported interfaces:"
wasm-tools component wit "$OUT" | grep -E '^\s*(export|world)' | head -10
echo "build.sh: OK — app.wasm is a valid component exporting wasi:http/incoming-handler"
