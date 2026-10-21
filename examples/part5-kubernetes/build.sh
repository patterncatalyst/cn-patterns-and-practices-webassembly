#!/usr/bin/env bash
# examples/part5-kubernetes/build.sh
#
# Build the DEPLOYABLE component `app.wasm` for the Part 5 (Kubernetes) example
# and package it as a thin OCI image the containerd `wasmtime` shim can load.
#
# Single source of truth: this reuses the EXACT Part 2/3/4 recipe — the Part 2
# Rust `cargo` provider composed under the Part 3 `http-rust` front door via
# `wac plug` — so the artifact that runs on Kubernetes (containerd + the runwasi
# `containerd-shim-wasmtime` shim) is byte-for-byte the same component that
# `wasmtime serve` runs in Part 3 and that wasmCloud runs in Part 4
# (sha256 eff7f5ee…). It does NOT fork or edit the component; it rebuilds the
# upstream crates with their own recipes and plugs them together.
#
#   part2 rust provider  (exports patterncatalyst:cargo/*)
#        +                 -> wac plug ->  app.wasm  (exports wasi:http/incoming-handler)
#   part3 http-rust       (imports patterncatalyst:cargo/*, exports wasi:http)
#
#        app.wasm  ──docker build (FROM scratch, COPY app.wasm /app.wasm)──>  OCI image
#        ──minikube image load──>  the node's containerd store  ──shim──>  wasmtime serve
#
# The runwasi wasmtime shim auto-detects a component that targets the
# `wasi:http/proxy` world and runs it behind a hyper server (the same behaviour
# as `wasmtime serve`), listening on 0.0.0.0:8080 inside the Pod. The container
# command's single argument is the in-rootfs path to the module (/app.wasm) —
# see k8s/base/deployment.yaml.
#
# Output: ./app.wasm (gitignored) + the loaded OCI image. Re-runnable from a
# clean checkout. Pass --no-image to only (re)build app.wasm.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PART2="$SCRIPT_DIR/../part2-building-components"
PART3="$SCRIPT_DIR/../part3-interfaces"
OUT="$SCRIPT_DIR/app.wasm"
IMAGE="${IMAGE:-cargo-http-wasm:minikube}"

BUILD_IMAGE=1
for arg in "$@"; do
  case "$arg" in
    --no-image) BUILD_IMAGE=0 ;;
    -h|--help) echo "Usage: $0 [--no-image]"; exit 0 ;;
    *) echo "build.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

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

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "build.sh: wrote $OUT"
echo "build.sh: sha256: $SHA"
echo "build.sh: exported interfaces:"
wasm-tools component wit "$OUT" | grep -E '^\s*(export|world)' | head -10

if [[ "$BUILD_IMAGE" -eq 1 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "build.sh: FAIL — docker not found on PATH (needed to package the OCI image)" >&2
    exit 1
  fi
  echo "build.sh: packaging OCI image '$IMAGE' (FROM scratch, COPY app.wasm /app.wasm) ..."
  # --provenance=false: keep it a single, plain OCI manifest. BuildKit otherwise
  # adds an attestation manifest + manifest list, which the Wasm shim does not
  # need and which complicates `minikube image load` / `ctr run` platform
  # resolution. A one-layer scratch image is all the shim reads.
  docker build --provenance=false -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
  echo "build.sh: built image $IMAGE"
fi

echo "build.sh: OK — app.wasm is a valid component exporting wasi:http/incoming-handler"
