#!/usr/bin/env bash
# examples/part4-runtimes/wasmcloud/prove-same-bytes.sh
#
# ch16 proof: ONE component artifact (app.wasm), ONE sha256, runs on BOTH
# runtimes and serves identical results:
#
#   * wasmtime serve -S cli app.wasm          (the standalone runtime)
#   * wasmCloud (httpserver provider -> app.wasm, via wadm)   [capture-evidence.sh]
#
# This script proves the wasmtime side here and records app.wasm's sha256. The
# wasmCloud side is proven live by capture-evidence.sh, which records the sha256
# of the SAME app.wasm it deploys. Equal sha256 on both sides == same bytes.
#
# Run ./build.sh first (it writes app.wasm). Exits non-zero on any mismatch.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=../../_lib/lib.sh
source "$SCRIPT_DIR/../../_lib/lib.sh"

require_cmd wasmtime
require_cmd curl
require_cmd sha256sum

APP="$SCRIPT_DIR/app.wasm"
assert_file "$APP" "app.wasm (run ./build.sh first)"

EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

SHA="$(sha256sum "$APP" | awk '{print $1}')"
echo "app.wasm sha256: $SHA"

PORT=18210
wasmtime serve -S cli "$APP" --addr "127.0.0.1:$PORT" >"$SCRIPT_DIR/.serve.log" 2>&1 &
PID=$!
register_cleanup "kill $PID 2>/dev/null"
register_cleanup "rm -f '$SCRIPT_DIR/.serve.log'"

for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/cargo/CARGO-USNYC-DEHAM" && break
  sleep 0.1
done

BODY="$(curl -s "http://127.0.0.1:$PORT/cargo/CARGO-USNYC-DEHAM")"
assert_eq "$EXPECTED_JSON" "$BODY" "wasmtime serve GET /cargo/CARGO-USNYC-DEHAM"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/cargo/NOPE")"
assert_eq "404" "$CODE" "wasmtime serve GET /cargo/NOPE"

kill $PID 2>/dev/null || true

echo
echo "PASS — same-bytes (ch16):"
echo "  app.wasm ($SHA) serves the cargo JSON under 'wasmtime serve'."
echo "  capture-evidence.sh deploys the SAME app.wasm to wasmCloud and records"
echo "  the same sha256 — one artifact, two runtimes, identical behavior."
