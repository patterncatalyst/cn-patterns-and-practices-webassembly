#!/usr/bin/env bash
# examples/part3-interfaces/verify.sh
#
# End-to-end check for Part 3 (Interfaces: HTTP and gRPC, plus networking).
# Reuses the Part 2 provider components by BUILDING them with their own recipes
# (single source of truth) and never edits contracts/wit.
#
#   GATE A (ch11): Rust wasi-http component composed with the Part 2 Rust
#     provider serves GET /cargo/{id} under `wasmtime serve`; curl asserts the
#     JSON body and the 404 path.
#   GATE B (ch11): the same in TinyGo, composed with the Part 2 Go provider.
#   GATE C (ch12):
#     1. prost-in-Wasm: the Rust proto component (prost inside the sandbox)
#        composed with the Rust provider; a native host does a protobuf round
#        trip and asserts the decoded fields.
#     2. the same proof for the TinyGo proto component (reflection-free wire
#        codec), driven by the identical native host.
#     3. the tonic gRPC bridge: `cargo test` runs an in-process tonic client
#        against the bridge (gRPC in front of the Wasm provider).
#   GATE D (ch13): the Rust wasi-sockets client reconnects with backoff under
#     `wasmtime run -S inherit-network` once a listener appears, and is denied
#     without the grant. The TinyGo sockets component is built and validated
#     (its runtime limitation is documented in the README).
#
# Exits non-zero on any failure. Reproducible from a clean checkout.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/lib.sh
source "$SCRIPT_DIR/../_lib/lib.sh"

PART2="$SCRIPT_DIR/../part2-building-components"

require_cmd cargo
require_cmd cargo-component "install cargo-component"
require_cmd tinygo
require_cmd wasm-tools
require_cmd wit-bindgen-go
require_cmd go
require_cmd wac "install wac (cargo install wac-cli)"
require_cmd wasmtime
require_cmd protoc "install protoc (libprotoc)"
require_cmd curl
require_cmd python3

# Expected JSON body for GET /cargo/CARGO-USNYC-DEHAM — identical across the Rust
# and TinyGo front doors.
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

COMPOSE_DIR="$(mktemp -d -t part3-compose.XXXXXX)"
register_cleanup "rm -rf '$COMPOSE_DIR'"

# ---------------------------------------------------------------------------
# Build the Part 2 providers with their own recipes (single source of truth).
# ---------------------------------------------------------------------------
echo
echo "=== Build the Part 2 provider components (reused, not edited) ==="
( cd "$PART2/rust" && cargo component build --release )
RUST_PROVIDER="$(find "$PART2/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$RUST_PROVIDER" "part2 rust provider"
bash "$PART2/go/build.sh"
GO_PROVIDER="$PART2/go/cargo-go.wasm"
assert_file "$GO_PROVIDER" "part2 go provider"

# ---------------------------------------------------------------------------
# Serve helper: start `wasmtime serve` in the background, wait until it answers,
# run a curl, and assert. Cleans the server up via the EXIT trap.
# ---------------------------------------------------------------------------
serve_assert() {
  local label="$1" composed="$2" port="$3"
  local base="http://127.0.0.1:$port"
  local log="$COMPOSE_DIR/serve-$label.log"

  wasmtime serve -S cli "$composed" --addr "127.0.0.1:$port" >"$log" 2>&1 &
  local pid=$!
  register_cleanup "kill $pid 2>/dev/null"

  local i
  for i in $(seq 1 50); do
    if curl -s -o /dev/null "$base/cargo/CARGO-USNYC-DEHAM"; then break; fi
    sleep 0.1
  done

  local body code
  body="$(curl -s "$base/cargo/CARGO-USNYC-DEHAM")"
  assert_eq "$EXPECTED_JSON" "$body" "$label GET /cargo/CARGO-USNYC-DEHAM body"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base/cargo/NOPE")"
  assert_eq "404" "$code" "$label GET /cargo/NOPE status"

  kill "$pid" 2>/dev/null || true
}

echo
echo "=== GATE A (ch11): Rust wasi-http serve ==="
( cd "$SCRIPT_DIR/http-rust" && cargo component build --release )
HTTP_RUST="$(find "$SCRIPT_DIR/http-rust/target" -name cargo_http_rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$HTTP_RUST" "http-rust component"
wac plug --plug "$RUST_PROVIDER" "$HTTP_RUST" -o "$COMPOSE_DIR/composed-http-rust.wasm"
serve_assert "http-rust" "$COMPOSE_DIR/composed-http-rust.wasm" 18080

echo
echo "=== GATE B (ch11): TinyGo wasi-http serve ==="
bash "$SCRIPT_DIR/http-go/build.sh"
assert_file "$SCRIPT_DIR/http-go/cargo-http-go.wasm" "http-go component"
wac plug --plug "$GO_PROVIDER" "$SCRIPT_DIR/http-go/cargo-http-go.wasm" -o "$COMPOSE_DIR/composed-http-go.wasm"
serve_assert "http-go" "$COMPOSE_DIR/composed-http-go.wasm" 18081

echo
echo "=== GATE C.1 (ch12): protobuf-in-Wasm (prost, Rust) round trip ==="
( cd "$SCRIPT_DIR/proto-component/proto-rust" && cargo component build --release )
PROTO_RUST="$(find "$SCRIPT_DIR/proto-component/proto-rust/target" -name cargo_proto_rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$PROTO_RUST" "proto-rust component"
( cd "$SCRIPT_DIR/proto-component/proto-host" && cargo build --release )
PROTO_HOST="$SCRIPT_DIR/proto-component/proto-host/target/release/cargo-proto-host"
assert_file "$PROTO_HOST" "proto-host"
wac plug --plug "$RUST_PROVIDER" "$PROTO_RUST" -o "$COMPOSE_DIR/composed-proto-rust.wasm"
"$PROTO_HOST" "$COMPOSE_DIR/composed-proto-rust.wasm"
echo "lib.sh: ok — prost-in-Wasm (Rust) protobuf round trip asserted"

echo
echo "=== GATE C.2 (ch12): protobuf-in-Wasm (reflection-free wire codec, TinyGo) round trip ==="
bash "$SCRIPT_DIR/proto-go/build.sh"
assert_file "$SCRIPT_DIR/proto-go/cargo-proto-go.wasm" "proto-go component"
wac plug --plug "$GO_PROVIDER" "$SCRIPT_DIR/proto-go/cargo-proto-go.wasm" -o "$COMPOSE_DIR/composed-proto-go.wasm"
"$PROTO_HOST" "$COMPOSE_DIR/composed-proto-go.wasm"
echo "lib.sh: ok — reflection-free protobuf (TinyGo) round trip asserted"

echo
echo "=== GATE C.3 (ch12): gRPC bridge (tonic) client round trip ==="
( cd "$SCRIPT_DIR/grpc-bridge" && cargo test --release -- --nocapture )
echo "lib.sh: ok — tonic client round trip through the Wasm provider asserted"

echo
echo "=== GATE D (ch13): wasi-sockets reconnect (Rust) ==="
( cd "$SCRIPT_DIR/sockets-rust" && cargo component build --release )
SOCKETS_RUST="$(find "$SCRIPT_DIR/sockets-rust/target" -name sockets-client-rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$SOCKETS_RUST" "sockets-rust component"

# D.1 — capability withheld: no network grant -> access denied, non-zero exit.
DENY_OUT="$(wasmtime run "$SOCKETS_RUST" 18090 2 50 2>&1 || true)"
assert_contains "access-denied" "$DENY_OUT" "sockets-rust without grant is denied"

# D.2 — capability granted + listener appears after a delay -> reconnect succeeds.
SOCK_PORT=18091
( sleep 1.5; python3 -I -c 'import socket;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",'"$SOCK_PORT"'));s.listen();c,_=s.accept();c.close();s.close()' ) &
LISTENER_PID=$!
register_cleanup "kill $LISTENER_PID 2>/dev/null"
CONNECT_OUT="$(wasmtime run -S inherit-network "$SOCKETS_RUST" $SOCK_PORT 20 100 2>&1)"
wait "$LISTENER_PID" 2>/dev/null || true
assert_contains "connected to 127.0.0.1:$SOCK_PORT" "$CONNECT_OUT" "sockets-rust reconnects after backoff"
echo "$CONNECT_OUT" | sed 's/^/    sockets-rust: /'

echo
echo "=== GATE D (ch13): wasi-sockets (TinyGo) builds + validates (runtime gap documented) ==="
bash "$SCRIPT_DIR/sockets-go/build.sh"
assert_file "$SCRIPT_DIR/sockets-go/sockets-client-go.wasm" "sockets-go component (build+validate only; see README)"

echo
echo "PASS — part3-interfaces:"
echo "  * ch11: Rust AND TinyGo wasi-http components serve GET /cargo/{id} under"
echo "    wasmtime serve, composed with the Part 2 providers, identical JSON."
echo "  * ch12: protobuf runs server-side INSIDE a component (prost in Rust, a"
echo "    reflection-free wire codec in TinyGo); the tonic bridge terminates gRPC"
echo "    in front of the unchanged Wasm provider."
echo "  * ch13: the Rust wasi-sockets client reconnects with backoff under an"
echo "    explicit network grant and is denied without it; the TinyGo sockets"
echo "    component builds and validates (runtime gap documented in README)."
