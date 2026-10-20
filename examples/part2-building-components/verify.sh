#!/usr/bin/env bash
# examples/part2-building-components/verify.sh
#
# End-to-end check for the two-language WebAssembly cargo example:
#
#   1. Build the Rust provider component (cargo-component).
#   2. Build the Go provider component (TinyGo + wasm-tools + reactor adapter).
#   3. Build the native Rust host.
#   4. Run the host against BOTH components over one shared fixture; each run
#      asserts the domain scenario (book -> get -> routes -> assign -> register
#      3 events -> list -> cargo-tracker history/status) against the fixture.
#   5. Assert the Rust and Go components produce IDENTICAL observable output —
#      two independent implementations of one WIT contract, byte-for-byte equal.
#   6. World-conformance: each component's exported patterncatalyst:cargo
#      interfaces must match contracts/wit exactly.
#
# Exits non-zero on any failure. Reproducible from a clean checkout.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/lib.sh
source "$SCRIPT_DIR/../_lib/lib.sh"

CONTRACT_DIR="$SCRIPT_DIR/../../contracts/wit"
FIXTURE="$SCRIPT_DIR/fixtures/scenario.json"
GO_WASM="$SCRIPT_DIR/go/cargo-go.wasm"
HOST_BIN="$SCRIPT_DIR/host/target/release/cargo-host"

require_cmd cargo
require_cmd cargo-component "install cargo-component"
require_cmd tinygo
require_cmd wasm-tools
require_cmd wit-bindgen-go
require_cmd go

OUT_RUST="$(mktemp -t cargo-host-rust.XXXXXX.json)"
OUT_GO="$(mktemp -t cargo-host-go.XXXXXX.json)"
register_cleanup "rm -f '$OUT_RUST' '$OUT_GO'"

echo
echo "=== Step 1: build the Rust component (cargo-component) ==="
( cd "$SCRIPT_DIR/rust" && cargo component build --release )
RUST_WASM="$(find "$SCRIPT_DIR/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$RUST_WASM" "rust component built"

echo
echo "=== Step 2: build the Go component (TinyGo -> component) ==="
bash "$SCRIPT_DIR/go/build.sh"
assert_file "$GO_WASM" "go component built"

echo
echo "=== Step 3: build the native host ==="
( cd "$SCRIPT_DIR/host" && cargo build --release )
assert_file "$HOST_BIN" "host built"

echo
echo "=== Step 4: run the host against BOTH components (scenario assertions) ==="
"$HOST_BIN" "$RUST_WASM" "$FIXTURE" rust >"$OUT_RUST"
echo "lib.sh: ok — rust component scenario passed"
"$HOST_BIN" "$GO_WASM" "$FIXTURE" go >"$OUT_GO"
echo "lib.sh: ok — go component scenario passed"

echo
echo "=== Step 5: cross-language agreement (Rust output === Go output) ==="
if ! diff -u "$OUT_RUST" "$OUT_GO"; then
  echo "lib.sh: FAIL — Rust and Go components produced different results" >&2
  exit 1
fi
echo "lib.sh: ok — Rust and Go components produced byte-identical results"

echo
echo "=== Step 6: world-conformance against contracts/wit ==="
assert_component_matches_contract "$RUST_WASM" "$CONTRACT_DIR" "rust"
assert_component_matches_contract "$GO_WASM" "$CONTRACT_DIR" "go"

echo
echo "PASS — part2-building-components: the Rust and the Go component each"
echo "export world cargo, implement the booking + handling domain (including"
echo "the cargo-tracker resource) identically, and the single native host runs"
echo "both across the component boundary to the same observable result."
