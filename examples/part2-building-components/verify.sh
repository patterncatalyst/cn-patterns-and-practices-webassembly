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
#      3 events -> list -> cargo-tracker history/status) AND the error taxonomy
#      (a recoverable cargo-error::not-found vs. an unrecoverable wasm trap).
#   5. Assert the Rust and Go components produce IDENTICAL observable output —
#      two independent implementations of one WIT contract, byte-for-byte equal.
#   6. World-conformance: each component's exported patterncatalyst:cargo
#      interfaces must match contracts/wit exactly.
#   7. Build BOTH consumer components (Rust cargo-component command; Go TinyGo
#      command). Each imports the cargo interfaces and exports wasi:cli/run.
#   8. Compose all four consumer x provider combinations with `wac plug` and
#      `wasmtime run` each composed component directly (no native host). Assert
#      each prints the expected normalized summary line — runtime output, NOT
#      artifact bytes (composed bytes are non-deterministic, wac#216).
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
GO_CONSUMER="$SCRIPT_DIR/consumer-go/cargo-consumer-go.wasm"

# The normalized one-line summary every consumer x provider composition must
# print. Derived from the shared scenario (USNYC -> DEHAM, 1200.5 kg, three
# handling events); identical across all four combos and both languages.
EXPECTED_LINE='booking=BOOKING-USNYC-DEHAM|cargo=CARGO-USNYC-DEHAM|weight=1200.5|price=1500.00 USD|status=not-routed|itinerary=BOOKING-USNYC-DEHAM VOY-001 planned|assigned=routed|events=3|tracker=CARGO-USNYC-DEHAM in-transit 3|history=received@USNYC,loaded@USNYC,unloaded@DEHAM'

require_cmd cargo
require_cmd cargo-component "install cargo-component"
require_cmd tinygo
require_cmd wasm-tools
require_cmd wit-bindgen-go
require_cmd go
require_cmd wac "install wac (cargo install wac-cli)"
require_cmd wasmtime

OUT_RUST="$(mktemp -t cargo-host-rust.XXXXXX.json)"
OUT_GO="$(mktemp -t cargo-host-go.XXXXXX.json)"
COMPOSE_DIR="$(mktemp -d -t cargo-compose.XXXXXX)"
register_cleanup "rm -f '$OUT_RUST' '$OUT_GO'"
register_cleanup "rm -rf '$COMPOSE_DIR'"

echo
echo "=== Step 1: build the Rust provider component (cargo-component) ==="
( cd "$SCRIPT_DIR/rust" && cargo component build --release )
RUST_WASM="$(find "$SCRIPT_DIR/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$RUST_WASM" "rust provider built"

echo
echo "=== Step 2: build the Go provider component (TinyGo -> component) ==="
bash "$SCRIPT_DIR/go/build.sh"
assert_file "$GO_WASM" "go provider built"

echo
echo "=== Step 3: build the native host ==="
( cd "$SCRIPT_DIR/host" && cargo build --release )
assert_file "$HOST_BIN" "host built"

echo
echo "=== Step 4: run the host against BOTH components (scenario + error taxonomy) ==="
"$HOST_BIN" "$RUST_WASM" "$FIXTURE" rust >"$OUT_RUST"
echo "lib.sh: ok — rust provider scenario + error/trap assertions passed"
"$HOST_BIN" "$GO_WASM" "$FIXTURE" go >"$OUT_GO"
echo "lib.sh: ok — go provider scenario + error/trap assertions passed"

echo
echo "=== Step 5: cross-language agreement (Rust output === Go output) ==="
if ! diff -u "$OUT_RUST" "$OUT_GO"; then
  echo "lib.sh: FAIL — Rust and Go components produced different results" >&2
  exit 1
fi
echo "lib.sh: ok — Rust and Go components produced byte-identical results"

echo
echo "=== Step 6: world-conformance against contracts/wit ==="
assert_component_matches_contract "$RUST_WASM" "$CONTRACT_DIR" "rust provider"
assert_component_matches_contract "$GO_WASM" "$CONTRACT_DIR" "go provider"

echo
echo "=== Step 7: build BOTH consumer components ==="
( cd "$SCRIPT_DIR/consumer-rust" && cargo component build --release )
RUST_CONSUMER="$(find "$SCRIPT_DIR/consumer-rust/target" -name 'cargo-consumer-rust.wasm' -not -path '*/deps/*' | head -1)"
assert_file "$RUST_CONSUMER" "rust consumer built"
bash "$SCRIPT_DIR/consumer-go/build.sh"
assert_file "$GO_CONSUMER" "go consumer built"

echo
echo "=== Step 8: compose all four consumer x provider combos and run each ==="
# wac plug: the PROVIDER (exports cargo) is the --plug; the CONSUMER (imports
# cargo, exports wasi:cli/run) is the socket. The composed component needs no
# native host — wasmtime runs it directly. Assert RUNTIME stdout, never bytes.
compose_run_assert() {
  local name="$1" consumer="$2" provider="$3"
  local composed="$COMPOSE_DIR/composed-$name.wasm"
  wac plug --plug "$provider" "$consumer" -o "$composed"
  local actual
  actual="$(wasmtime run "$composed")"
  assert_eq "$EXPECTED_LINE" "$actual" "composed[$name] runtime output"
}
compose_run_assert "rustC-rustP" "$RUST_CONSUMER" "$RUST_WASM"
compose_run_assert "rustC-goP"   "$RUST_CONSUMER" "$GO_WASM"
compose_run_assert "goC-rustP"   "$GO_CONSUMER"   "$RUST_WASM"
compose_run_assert "goC-goP"     "$GO_CONSUMER"   "$GO_WASM"

echo
echo "PASS — part2-building-components:"
echo "  * Rust and Go PROVIDER components each export world cargo and implement"
echo "    the booking + handling domain (incl. the cargo-tracker resource)"
echo "    identically; the native host drives both to the same observable result"
echo "    and distinguishes a recoverable cargo-error::not-found from a wasm trap."
echo "  * Rust and Go CONSUMER components each import the cargo interfaces and"
echo "    export wasi:cli/run; all four consumer x provider compositions run"
echo "    headless under wasmtime and print the identical normalized summary."
