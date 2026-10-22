#!/usr/bin/env bash
# examples/part5-kubernetes/kafka-host/build.sh
#
# Build `kafka-app.wasm` — the composite the native `cargo-kafka-host` binary
# embeds — and then the host binary itself. Two `wac plug` sources, reused via
# their own build.sh recipes, no crate forked or edited:
#
#   part2 rust provider  (exports patterncatalyst:cargo/*)
#        +                 -> wac plug ->  kafka-app.wasm  (exports
#   ../kafka-handler      (imports patterncatalyst:cargo/*,                 wasmcloud:messaging/{types,handler}@0.2.0)
#                          exports wasmcloud:messaging/{types,handler}@0.2.0)
#
# This is the SAME provider ../build.sh plugs under the HTTP front door and
# ../kafka-handler deploys standalone into the wasmCloud lattice (where wadm's
# `link` trait satisfies the same import at deploy time instead). Here the
# import is satisfied at BUILD time, because this path has no lattice: the
# native host below is a plain Kubernetes Deployment, and
# `wasmtime::component::Component::from_file` only ever loads one self-contained
# component — it does not resolve cross-component links.
#
# Output: ./kafka-app.wasm (gitignored, see .gitignore) +
# ./target/release/cargo-kafka-host (the native host binary; Cargo.lock
# committed for reproducible builds).
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PART2="$SCRIPT_DIR/../../part2-building-components"
KAFKA_HANDLER="$SCRIPT_DIR/../kafka-handler"
OUT="$SCRIPT_DIR/kafka-app.wasm"

for tool in cargo cargo-component wac wasm-tools; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "kafka-host/build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "kafka-host/build.sh: [1/4] building the Part 2 Rust cargo provider (reused, not edited) ..."
( cd "$PART2/rust" && cargo component build --release )
PROVIDER="$(find "$PART2/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
[[ -s "$PROVIDER" ]] || { echo "kafka-host/build.sh: FAIL — part2 provider not produced" >&2; exit 1; }

echo "kafka-host/build.sh: [2/4] building the ch23 kafka-handler (reused, not edited; runs its own build.sh) ..."
( cd "$KAFKA_HANDLER" && ./build.sh )
HANDLER="$(find "$KAFKA_HANDLER/target/wasm32-wasip1/release" -maxdepth 1 -name cargo_kafka_handler_rust.wasm | head -1)"
[[ -s "$HANDLER" ]] || { echo "kafka-host/build.sh: FAIL — kafka-handler not produced" >&2; exit 1; }

echo "kafka-host/build.sh: [3/4] composing kafka-app.wasm (wac plug: provider -> kafka-handler) ..."
wac plug --plug "$PROVIDER" "$HANDLER" -o "$OUT"
wasm-tools validate "$OUT"

WIT="$(wasm-tools component wit "$OUT")"
if ! grep -q 'export wasmcloud:messaging/types@0.2.0;' <<<"$WIT" \
  || ! grep -q 'export wasmcloud:messaging/handler@0.2.0;' <<<"$WIT"; then
  echo "kafka-host/build.sh: FAIL — kafka-app.wasm does not export wasmcloud:messaging/{types,handler}@0.2.0" >&2
  echo "$WIT" >&2
  exit 1
fi
if grep -qE '^\s*import patterncatalyst:' <<<"$WIT"; then
  echo "kafka-host/build.sh: FAIL — kafka-app.wasm still imports patterncatalyst:cargo/* (plug left it unsatisfied)" >&2
  echo "$WIT" >&2
  exit 1
fi

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "kafka-host/build.sh: wrote $OUT"
echo "kafka-host/build.sh: sha256: $SHA"
echo "kafka-host/build.sh: exports/imports:"
grep -E '^\s*(export|import)' <<<"$WIT"

echo "kafka-host/build.sh: [4/4] building the native cargo-kafka-host binary ..."
cargo build --release
BIN="$SCRIPT_DIR/target/release/cargo-kafka-host"
[[ -x "$BIN" ]] || { echo "kafka-host/build.sh: FAIL — cargo-kafka-host binary not produced" >&2; exit 1; }
echo "kafka-host/build.sh: wrote $BIN"

echo "kafka-host/build.sh: OK — kafka-app.wasm exports wasmcloud:messaging/{types,handler}@0.2.0, imports only wasi; cargo-kafka-host built"
