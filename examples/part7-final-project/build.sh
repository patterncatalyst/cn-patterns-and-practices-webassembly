#!/usr/bin/env bash
# examples/part7-final-project/build.sh
#
# Assemble the final project's buildable core: two deployable composites of
# the same cargo domain, one per language, by reusing existing components
# verbatim.
#
#   cargo-rust.wasm = part3 http-rust  (wasi:http front door, Rust/cargo-component)
#                      wac plug
#                      part2 rust      (cargo provider, exports patterncatalyst:cargo/*)
#
#   cargo-go.wasm   = part3 http-go    (wasi:http front door, TinyGo)
#                      wac plug
#                      part2 go        (cargo provider, exports patterncatalyst:cargo/*)
#
# This is the two-language-one-contract thesis made concrete: both composites
# implement the identical contracts/wit world and must serve byte-identical
# JSON. Nothing here forks or edits a component or contracts/wit — each side is
# rebuilt with its own upstream recipe (part2/part3's own build.sh) and the two
# halves are plugged together with `wac plug`, exactly as
# examples/part4-runtimes/wasmcloud/build.sh already does for the Rust side
# (that script's output, app.wasm, is the same composite as cargo-rust.wasm
# here).
#
# Steps: build both providers + both front doors -> wac plug each pair ->
# validate + surface-check (exports wasi:http/incoming-handler, imports only
# wasi:*) -> print sha256 -> smoke-test each under `wasmtime serve` (GET
# /cargo/{id} + 404) -> package each as a `FROM scratch` OCI image.
#
# Flags:
#   --no-image   skip the OCI image build (just build/validate/smoke the wasm)
#   --load       after packaging, `minikube image load` both images into the
#                `part5` profile (author-only; requires that profile running)
#
# Re-runnable from a clean checkout. Requires on PATH: cargo, cargo-component,
# tinygo, wit-bindgen-go, go, wasm-tools, wac, wasmtime, curl, and (unless
# --no-image) docker.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=../_lib/lib.sh
source "$SCRIPT_DIR/../_lib/lib.sh"

PART2="$SCRIPT_DIR/../part2-building-components"
PART3="$SCRIPT_DIR/../part3-interfaces"

RUST_OUT="$SCRIPT_DIR/cargo-rust.wasm"
GO_OUT="$SCRIPT_DIR/cargo-go.wasm"

BUILD_IMAGE=1
DO_LOAD=0
for arg in "$@"; do
  case "$arg" in
    --no-image) BUILD_IMAGE=0 ;;
    --load) DO_LOAD=1 ;;
    -h|--help) echo "Usage: $0 [--no-image] [--load]"; exit 0 ;;
    *) echo "build.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

require_cmd cargo
require_cmd cargo-component "install cargo-component"
require_cmd tinygo
require_cmd wit-bindgen-go
require_cmd go
require_cmd wasm-tools
require_cmd wac "install wac (cargo install wac-cli)"
require_cmd wasmtime
require_cmd curl

# ---------------------------------------------------------------------------
# Surface check: the composite must export wasi:http/incoming-handler and, now
# that wac plug has satisfied the cargo import, must import nothing but
# wasi:* — no patterncatalyst:* import may survive composition.
# ---------------------------------------------------------------------------
assert_http_composite() {
  local wasm="$1" label="$2"
  local wit
  wit="$(wasm-tools component wit "$wasm")"
  if ! grep -q 'export wasi:http/incoming-handler' <<<"$wit"; then
    echo "build.sh: FAIL — $label does not export wasi:http/incoming-handler" >&2
    exit 1
  fi
  local bad
  bad="$(grep -E '^\s*import ' <<<"$wit" | grep -v 'import wasi:' || true)"
  if [[ -n "$bad" ]]; then
    echo "build.sh: FAIL — $label still imports a non-wasi interface after wac plug:" >&2
    echo "$bad" >&2
    exit 1
  fi
  echo "build.sh: ok — $label exports wasi:http/incoming-handler, imports only wasi:*"
}

# ---------------------------------------------------------------------------
# Smoke test: serve the composite with `wasmtime serve -S cli`, curl the
# canonical id (expect the exact JSON) and an unknown id (expect 404).
# ---------------------------------------------------------------------------
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

serve_assert() {
  local label="$1" composed="$2" port="$3"
  local base="http://127.0.0.1:$port"
  local log
  log="$(mktemp -t "serve-$label.XXXXXX.log")"
  register_cleanup "rm -f '$log'"

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
  wait "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Rust composite
# ---------------------------------------------------------------------------
echo
echo "=== Rust: building the part2 provider + part3 http-rust front door ==="
( cd "$PART2/rust" && cargo component build --release )
RUST_PROVIDER="$(find "$PART2/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$RUST_PROVIDER" "part2 rust provider"

( cd "$PART3/http-rust" && cargo component build --release )
RUST_HTTP="$(find "$PART3/http-rust/target" -name cargo_http_rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$RUST_HTTP" "part3 http-rust front door"

echo "build.sh: wac plug (rust provider -> http-rust front door) -> $RUST_OUT"
wac plug --plug "$RUST_PROVIDER" "$RUST_HTTP" -o "$RUST_OUT"
wasm-tools validate "$RUST_OUT"
assert_http_composite "$RUST_OUT" "cargo-rust.wasm"
echo "build.sh: cargo-rust.wasm sha256: $(sha256sum "$RUST_OUT" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Go composite
# ---------------------------------------------------------------------------
echo
echo "=== Go: building the part2 provider + part3 http-go front door ==="
bash "$PART2/go/build.sh"
GO_PROVIDER="$PART2/go/cargo-go.wasm"
assert_file "$GO_PROVIDER" "part2 go provider"

bash "$PART3/http-go/build.sh"
GO_HTTP="$PART3/http-go/cargo-http-go.wasm"
assert_file "$GO_HTTP" "part3 http-go front door"

echo "build.sh: wac plug (go provider -> http-go front door) -> $GO_OUT"
wac plug --plug "$GO_PROVIDER" "$GO_HTTP" -o "$GO_OUT"
wasm-tools validate "$GO_OUT"
assert_http_composite "$GO_OUT" "cargo-go.wasm"
echo "build.sh: cargo-go.wasm sha256: $(sha256sum "$GO_OUT" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Smoke: both composites serve the identical JSON + 404, proving the
# two-language-one-contract thesis before packaging.
# ---------------------------------------------------------------------------
echo
echo "=== Smoke: wasmtime serve + curl, both languages ==="
serve_assert "cargo-rust" "$RUST_OUT" 18180
echo "build.sh: ok — cargo-rust.wasm served the exact JSON and 404'd on an unknown id"
serve_assert "cargo-go" "$GO_OUT" 18181
echo "build.sh: ok — cargo-go.wasm served the exact JSON and 404'd on an unknown id"

# ---------------------------------------------------------------------------
# Packaging: one `FROM scratch` image per composite, built from the same
# parameterized Containerfile. --provenance=false keeps each a single, plain
# OCI manifest (no attestation manifest list) — the wasmtime shim only reads
# the one-layer scratch rootfs. No registry push: `minikube image load` (under
# --load) copies straight into the node's containerd store, matching the
# docker-driver + containerd convention used throughout Part 5.
# ---------------------------------------------------------------------------
if [[ "$BUILD_IMAGE" -eq 1 ]]; then
  require_cmd docker
  echo
  echo "=== Packaging: FROM scratch OCI images (cargo-rust:final, cargo-go:final) ==="
  docker build --provenance=false --build-arg WASM=cargo-rust.wasm \
    -t cargo-rust:final -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
  echo "build.sh: built image cargo-rust:final"
  docker build --provenance=false --build-arg WASM=cargo-go.wasm \
    -t cargo-go:final -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
  echo "build.sh: built image cargo-go:final"

  if [[ "$DO_LOAD" -eq 1 ]]; then
    PROFILE="part5"
    require_cmd minikube
    if minikube status -p "$PROFILE" >/dev/null 2>&1; then
      echo "build.sh: loading cargo-rust:final and cargo-go:final into minikube profile '$PROFILE' ..."
      minikube image load cargo-rust:final cargo-go:final -p "$PROFILE"
      echo "build.sh: loaded both images into profile '$PROFILE'"
    else
      echo "build.sh: --load given but minikube profile '$PROFILE' is not running — skipping image load" >&2
    fi
  fi
elif [[ "$DO_LOAD" -eq 1 ]]; then
  echo "build.sh: --load given with --no-image — nothing to load, skipping" >&2
fi

echo
echo "build.sh: OK — cargo-rust.wasm and cargo-go.wasm each validate, export"
echo "  wasi:http/incoming-handler, import only wasi:*, and serve byte-identical"
echo "  JSON for GET /cargo/{id} (404 for an unknown id)."
