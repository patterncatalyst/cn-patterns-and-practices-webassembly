#!/usr/bin/env bash
# examples/part6-deviations/wasi-nn/run.sh
#
# THE USER'S LIVE PATH. This script documents — and runs — the exact command
# order for OpenVINO-backed wasi-nn inference. It requires two things this
# repository does not install:
#
#   1. OpenVINO 2026.4.1 on the host (the `openvino` crate v0.11.0 that
#      `wasmtime-wasi-nn`'s openvino backend links against is a binding over
#      the real OpenVINO runtime libraries — there is no pure-Rust OpenVINO).
#      Install OpenVINO's APT/YUM repo or the generic archive per Intel's
#      instructions, then confirm `ldconfig -p | grep openvino` resolves.
#
#   2. `wasmtime` v50.0.0 built FROM SOURCE with the `wasi-nn` feature, which
#      only compiles the OpenVINO backend when OpenVINO is already on the
#      host (the crate's build.rs probes for it):
#
#        git clone --branch v50.0.0 --depth 1 \
#          https://github.com/bytecodealliance/wasmtime
#        cd wasmtime
#        cargo build --release --features wasi-nn
#        install -m 0755 target/release/wasmtime ~/.local/bin/wasmtime
#        wasmtime --version   # wasmtime-cli 50.0.0
#
#      The prebuilt `wasmtime` CLI released on GitHub does NOT ship wasi-nn —
#      it is excluded from the default release build precisely because it
#      pulls in OpenVINO at link time. Building from source is the only path.
#
# wasi-nn is a PRE-1.0 WASI proposal (package version
# `0.2.0-rc-2024-10-28`, an explicit release-candidate tag, not `0.2.x`
# stable) — treat the WIT in wit/deps/wasi-nn/ as something that moves with
# the wasmtime version it was vendored from, not a frozen interface.
#
# This script builds the model and the component, then runs it. It does NOT
# install OpenVINO or build wasmtime — both are assumed already on PATH.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "run.sh: FAIL — 'wasmtime' not found on PATH; build it from source with --features wasi-nn (see header comment)" >&2
  exit 1
fi
if ! wasmtime run -S help 2>&1 | grep -q '\bnn\b'; then
  echo "run.sh: FAIL — this wasmtime binary was not built with --features wasi-nn (run 'wasmtime run -S help' and look for 'nn')" >&2
  exit 1
fi

echo "run.sh: [1/3] fetching the OpenVINO MobileNetV2 fixture ..."
./fetch-model.sh

echo "run.sh: [2/3] building the component ..."
./build.sh

WASM="$SCRIPT_DIR/target/wasm32-wasip1/release/cargo-wasi-nn.wasm"
MODEL_DIR="$SCRIPT_DIR/model/mobilenet"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

echo "run.sh: [3/3] running inference (OpenVINO backend, graph loaded by name 'mobilenet') ..."
# Flag spelling confirmed against wasmtime v50.0.0's own CLI option
# definitions (crates/cli-flags/src/opt.rs, impl WasmtimeOptionValue for
# WasiNnGraph: `const VAL_HELP: &'static str = "=<format>::<dir>";`, split on
# the literal "::"). This has changed across wasmtime releases — re-check
# `wasmtime run -S help` on YOUR build before trusting this spelling on a
# different wasmtime version.
#
#   -S nn                                   enable the wasi:nn imports
#   -S nn-graph=openvino::<dir>              preload <dir> as an OpenVINO
#                                            graph, registered under <dir>'s
#                                            basename ("mobilenet" here) —
#                                            see fetch-model.sh's header
#                                            comment for why the directory
#                                            name and the model.xml/model.bin
#                                            file names both matter
#   --dir HOST::GUEST                       preopen the fixtures directory
#                                            read-only at /fixtures
wasmtime run \
  -S nn \
  -S nn-graph="openvino::${MODEL_DIR}" \
  --dir "${FIXTURES_DIR}::/fixtures" \
  "$WASM" \
  /fixtures/cargo.jpg
