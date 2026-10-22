#!/usr/bin/env bash
# examples/part6-deviations/wasi-nn/fetch-model.sh
#
# Fetch the OpenVINO MobileNetV2 fixture — the same mobilenet.xml/mobilenet.bin
# pair wasmtime's own wasi-nn test suite downloads for its OpenVINO backend
# tests (crates/wasi-nn/tests/check/openvino.rs, `are_artifacts_available`,
# wasmtime v50.0.0) — into model/mobilenet/, renamed to model.xml/model.bin.
#
# That rename is not cosmetic: `BackendFromDir::load_from_dir` (crates/
# wasi-nn/src/backend/openvino.rs) hard-codes those two file names, and
# `InMemoryRegistry::load` (crates/wasi-nn/src/registry/in_memory.rs) names
# the graph after the DIRECTORY's basename — `mobilenet` here — which is
# exactly the name `graph::load-by-name("mobilenet")` in src/main.rs looks
# up. Get the directory name or the file names wrong and load-by-name fails
# at runtime, not at build time.
#
# Model artifacts are gitignored (see .gitignore) and fetched here, not
# committed — matching this crate's house convention of gitignoring built or
# downloaded binary artifacts and committing only source + lockfiles.
#
# Idempotent: re-running skips files already present with the correct hash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/model/mobilenet"
BASE_URL="https://download.01.org/openvinotoolkit/fixtures/mobilenet"

mkdir -p "$MODEL_DIR"

# (remote file, local file, sha256) — hashes captured from the upstream
# artifacts at first fetch (2026-10-22) and pinned here; re-verified on every
# run, including cached ones, so a corrupted or silently-changed upstream
# file is caught rather than used.
ARTIFACTS=(
  "mobilenet.xml model.xml b28eafd9f8cdf3e265dae4be2eacc4849c0d4693fde584ceca3541bcb4d79e6f"
  "mobilenet.bin model.bin 8371f708ef167a783ed01fc6635f4f05e76f720db95e954aff3cba3ed4f29924"
)

verify() {
  local file="$1" expected="$2"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

for entry in "${ARTIFACTS[@]}"; do
  set -- $entry
  remote_name="$1"
  local_name="$2"
  expected_sha="$3"
  dest="$MODEL_DIR/$local_name"

  if [[ -f "$dest" ]] && verify "$dest" "$expected_sha"; then
    echo "fetch-model.sh: $local_name already present and verified, skipping"
    continue
  fi

  echo "fetch-model.sh: fetching $remote_name -> $dest"
  curl -fsSL -o "$dest.part" "$BASE_URL/$remote_name"
  mv "$dest.part" "$dest"

  if ! verify "$dest" "$expected_sha"; then
    echo "fetch-model.sh: FAIL — sha256 mismatch for $dest" >&2
    echo "fetch-model.sh: expected $expected_sha" >&2
    echo "fetch-model.sh: got      $(sha256sum "$dest" | awk '{print $1}')" >&2
    rm -f "$dest"
    exit 1
  fi
  echo "fetch-model.sh: verified $local_name ($expected_sha)"
done

echo "fetch-model.sh: OK — $MODEL_DIR has model.xml + model.bin, ready for"
echo "fetch-model.sh: wasmtime run -S nn-graph=openvino::\"$MODEL_DIR\" (see run.sh)"
