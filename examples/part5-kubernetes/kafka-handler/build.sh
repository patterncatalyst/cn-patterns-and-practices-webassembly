#!/usr/bin/env bash
# examples/part5-kubernetes/kafka-handler/build.sh
#
# Build the ch23 Kafka message handler component. Offline: `cargo component
# build --release` resolves `patterncatalyst:cargo` via the
# ../../../contracts/wit path dependency and `wasmcloud:messaging` via the
# vendored wit/deps/messaging package — no network fetch.
#
# Unlike sidecar-filter/adapter (which `wac plug` three crates into one
# composite .wasm for a single Pod), this component is deployed STANDALONE
# into the wasmCloud lattice: wadm links it to the `messaging-kafka` capability
# provider (source -> this component, on wasmcloud:messaging/handler) and to a
# deployed cargo provider component (this component -> provider, on
# patterncatalyst:cargo/handling) at deploy time — see
# ../k8s/wasmcloud/wadm-kafka.yaml and ../openshift/wadm-kafka.yaml. No `wac
# plug` step is needed or run here.
#
# Output: target/wasm32-wasip1/release/cargo_kafka_handler_rust.wasm
# (gitignored, like the sibling sidecar-filter/adapter build outputs).
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

for tool in cargo cargo-component wasm-tools; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "kafka-handler/build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "kafka-handler/build.sh: building the ch23 Kafka message handler component ..."
cargo component build --release

OUT="$(find "$SCRIPT_DIR/target/wasm32-wasip1/release" -maxdepth 1 -name 'cargo_kafka_handler_rust.wasm' | head -1)"
[[ -s "$OUT" ]] || { echo "kafka-handler/build.sh: FAIL — component not produced" >&2; exit 1; }
wasm-tools validate "$OUT"

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "kafka-handler/build.sh: wrote $OUT"
echo "kafka-handler/build.sh: sha256: $SHA"
echo "kafka-handler/build.sh: exports/imports:"
wasm-tools component wit "$OUT" | grep -E '^\s*(export|import) (patterncatalyst|wasmcloud)'

echo "kafka-handler/build.sh: OK — exports wasmcloud:messaging/{types,handler}@0.2.0, imports patterncatalyst:cargo/{types,handling}@0.1.0"
