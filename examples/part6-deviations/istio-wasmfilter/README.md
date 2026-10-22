# istio-wasmfilter (chapter 25: Istio + Wasm)

A proxy-wasm HTTP filter for Envoy, loaded into an Istio sidecar via a
`WasmPlugin` resource. It denies any request missing an `x-cargo-tenant`
header with a local 403 JSON response, and stamps
`x-cargo-filtered-by: cargo-wasmfilter` on every response that makes it
through — enough for a `curl` to prove the filter ran.

## The teaching point

This crate is a **proxy-wasm core module** — the Envoy ABI — not a
Component Model component. Compare it against
`examples/part5-kubernetes/sidecar-filter`, which solves a similar
"inspect/allow/deny a request" problem but as a WIT component composed with
`wac` and run by the containerd `wasmtime` shim. The two crates are
deliberately parallel so the differences are the point:

| | `part5-kubernetes/sidecar-filter` | `part6-deviations/istio-wasmfilter` (this crate) |
|---|---|---|
| ABI | Component Model (WIT) | proxy-wasm (Envoy) |
| Crate deps | `wit-bindgen-rt` | `proxy-wasm` |
| Build | `cargo component build` | `cargo build --target wasm32-wasip1` |
| Target | `wasm32-wasip1` (component via adapter) | `wasm32-wasip1` (plain core module) |
| Generated code | `src/bindings.rs` from WIT | none — the crate's traits *are* the ABI |
| Host | containerd `wasmtime` shim (runwasi) | Envoy's proxy-wasm VM inside `istio-proxy` |
| Composition | `wac plug` into `app.wasm` | none — loaded directly by Envoy |

There is no `wit/` directory, no `cargo-component`, and no `bindings.rs` in
this crate on purpose. If you find yourself reaching for any of those here,
you've drifted back into the Component Model path this chapter is
contrasting against.

## Build

```sh
./build.sh
```

Produces `target/wasm32-wasip1/release/cargo_wasmfilter.wasm` (a plain core
wasm module — `wasm-tools validate` accepts it, `wasm-tools component wit`
correctly rejects it, since it carries no component-type custom sections).

## Package as an OCI image and load it with a WasmPlugin

Istio's `WasmPlugin.spec.url: oci://...` fetcher pulls an OCI image and reads
a `/plugin.wasm` file from its root — that's the whole contract. Two ways to
produce that image:

### Option A — `docker buildx` (same tool this repo already uses for Part 5)

```sh
docker buildx build --provenance=false \
  -t ghcr.io/patterncatalyst/cargo-wasmfilter:istio \
  -f Dockerfile .
docker push ghcr.io/patterncatalyst/cargo-wasmfilter:istio
```

The `Dockerfile` here is a one-line `FROM scratch` + `COPY ... /plugin.wasm`,
the same minimal-image pattern as `examples/part5-kubernetes/Dockerfile`
(`/app.wasm` there) — just a different expected file name, because the
*consumer* is different (Envoy's wasm fetcher vs. the containerd wasmtime
shim).

### Option B — `wash push` (wasmCloud's OCI tooling, already in this book's toolchain)

```sh
wash push ghcr.io/patterncatalyst/cargo-wasmfilter:istio \
  target/wasm32-wasip1/release/cargo_wasmfilter.wasm
```

`wash push` pushes the raw `.wasm` as a generic OCI artifact rather than a
Docker-style layered image. Istio's fetcher accepts both; pick Option A if
you want the artifact to also be `docker pull`-able for debugging, Option B
if you want one tool (`wash`) for every wasm OCI push in the book.

### Load it with a WasmPlugin

```yaml
apiVersion: extensions.istio.io/v1alpha1
kind: WasmPlugin
metadata:
  name: cargo-wasmfilter
  namespace: datamesh
spec:
  selector:
    matchLabels:
      app: cargo
  url: oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio
  phase: AUTHN
  pluginConfig: {}
```

Istio's sidecar injector pulls the image, extracts `/plugin.wasm`, and loads
it into Envoy's proxy-wasm VM for every pod matching the selector — no
container image for the workload itself changes; the filter runs in the
sidecar's Envoy process, alongside (not instead of) the app's own wasm
component story from Parts 2-5.

## Verify (no cluster)

```sh
./build.sh                                             # compiles + validates
wasm-tools validate target/wasm32-wasip1/release/cargo_wasmfilter.wasm
wasm-tools component wit target/wasm32-wasip1/release/cargo_wasmfilter.wasm  # expected to FAIL: not a component
```
