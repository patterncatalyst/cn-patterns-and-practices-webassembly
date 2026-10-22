# examples/part6-deviations/istio-wasmfilter/Dockerfile
#
# Packages the proxy-wasm filter as the OCI image shape Istio's WasmPlugin
# `url: oci://...` fetcher expects: a `/plugin.wasm` file at the image root.
# This is NOT the shape used elsewhere in this repo (Part 5's `/app.wasm`
# Component Model images consumed by the containerd wasmtime shim) — Istio's
# proxy-wasm image fetcher looks specifically for `plugin.wasm` by convention,
# because it is pulling a filter artifact for Envoy, not a deployable
# workload for a wasm-aware container runtime.
#
# build.sh writes the module to
# target/wasm32-wasip1/release/cargo_wasmfilter.wasm first; this Dockerfile
# copies it in under the expected name. See README.md for the push recipe
# (`docker buildx build --push` or `wash push`) and how a WasmPlugin resource
# references the resulting oci:// ref.
FROM scratch
COPY target/wasm32-wasip1/release/cargo_wasmfilter.wasm /plugin.wasm
