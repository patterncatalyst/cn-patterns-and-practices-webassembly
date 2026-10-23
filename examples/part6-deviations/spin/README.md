# cargo-spin (chapter 26: WebAssembly for other backend architectures)

A Fermyon **Spin** HTTP component serving the cargo domain: `GET /cargo/{id}`
returns the same canonical record every earlier example returns, built from
`spin-sdk = "=7.0.0"`'s `#[http_service]` entrypoint composed with the
**unchanged** `examples/part2-building-components/rust` provider via `wac
plug`. `contracts/wit` stays pristine: the provider is reused, not forked,
the same posture every earlier example tree holds to.

```
part2 rust provider  (exports patterncatalyst:cargo/*, UNEDITED)
     +                 -> wac plug ->  cargo-spin.wasm  (exports
this crate's handler  (imports patterncatalyst:cargo/*,       wasi:http/handler@0.3.0)
                       exports wasi:http/handler@0.3.0)
```

## The teaching point: Spin's own composition mechanism, and a real ABI surprise

Every earlier wac-composed example in this book hand-wires a provider's
exports into a consumer's imports with `wac plug`, run from a `build.sh`. Spin
has a native equivalent, **component dependencies**, that does the same
thing through the manifest instead of a CLI invocation:

```toml
[component.cargo-spin.dependencies]
"patterncatalyst:cargo" = { path = "/absolute/path/to/cargo_rust.wasm" }
```

`spin build` reads that section, decodes the referenced component's exports,
writes a `spin-dependencies.wit` file into the crate directory, and
`spin_sdk::dependencies!()` (called once, in `src/lib.rs`) bindgens it into
callable Rust functions: `patterncatalyst::cargo::booking::book_cargo(..)`,
`get_cargo(..)`, generated at the crate root, no `bindings::` module prefix.
`spin up` and `spin registry push` can satisfy that same dependency at load
time, via the identical `wac`-based graph composition internally (see
`crates/compose` in the Spin source); no hand-run `wac plug` required for a
`spin up`-only workflow.

This crate still runs `wac plug` itself, in `build.sh`, for one reason:
packaging. The CRC runtime image (`Dockerfile`) ships exactly two files:
`spin.toml` and `cargo-spin.wasm`, the same "one pre-composed artifact"
shape as every other Part 5/6 runtime image in this book, rather than a raw
handler plus a provider file plus a dependency-aware manifest. `build.sh`
therefore runs two manifests: a gitignored, generated `spin-build.toml` that
declares the dependency (so `spin build` regenerates `spin-dependencies.wit`
and compiles the handler), and the committed `spin.toml` (dependency-free,
`source = "cargo-spin.wasm"`) that both `spin up` and the Dockerfile read.

The real surprise is the export, not the import. `spin-sdk = "=7.0.0"`'s
`#[http_service]` macro targets `wasi:http@0.3.0/handler`, the **wasip3**
async HTTP world, not the `wasi:http/incoming-handler@0.2.x` every other
HTTP example in this book exports (`examples/part3-interfaces/http-rust`,
every Part 5 Kubernetes deploy target, the wasmCloud and Istio deviations).
Spin's own `trigger-http` (v4.2.4) runs both ABIs natively (compare
`crates/trigger-http/src/wasip3.rs` against `.../wasi.rs` in the Spin source),
so `spin up`/SpinKube serve this component correctly. What it means in
practice:

| | `part3-interfaces/http-rust` | `part6-deviations/spin` (this crate) |
|---|---|---|
| HTTP export | `wasi:http/incoming-handler@0.2.x` | `wasi:http/handler@0.3.0` (wasip3) |
| Written against | raw `wit-bindgen` bindings, hand-rolled Guest impl | `spin-sdk`'s `#[http_service]` + `Request`/`Response` |
| Runs under | `wasmtime serve`, any 0.2.x host | `spin up` / SpinKube only (0.3.0-aware host) |
| Domain import composition | `wac plug`, same tool, same shape | `wac plug` (manual, for packaging) **or** Spin's own dependency composer |
| `patterncatalyst:cargo` interface | unaffected: no `wasi:http` dependency | unaffected: no `wasi:http` dependency |

The `patterncatalyst:cargo` composition is identical in both crates; only the
HTTP-facing ABI differs, because that is what the pinned SDK version ships.
`cargo-spin.wasm` is a Spin artifact: `spin up` and SpinKube serve it
directly, while a `wasmtime serve` pipeline or another wasi:http 0.2.x host
(the way `part3-interfaces/http-rust` runs) expects the older ABI instead.

## Prerequisites

- Rust 1.99.1 with the `wasm32-wasip2` target (`rustup target add wasm32-wasip2`).
- `cargo-component` 0.21.1 (builds the Part 2 provider this crate composes with).
- `wac` 0.12.0, `wasm-tools` 1.262.0.
- Spin CLI **v4.2.4**, installed from the pinned release (see below), not a
  package-manager install; this book pins exact binaries per chapter.
- `gh` (GitHub CLI, authenticated) only for `./build.sh --push`.

No `libcurl`/C toolchain prerequisites: unlike `../../part5-kubernetes/
kafka-host`, nothing here links `librdkafka`.

### Installing the pinned Spin CLI

```sh
curl -fsSL -o spin.tar.gz \
  https://github.com/fermyon/spin/releases/download/v4.2.4/spin-v4.2.4-linux-amd64.tar.gz
echo "519ba201e0105dc83a17a4ea9ca6605c80286cbfaf40c1d7505d068bfea83cf1  spin.tar.gz" | sha256sum -c -
tar xzf spin.tar.gz spin
install -m 0755 spin ~/.local/bin/spin
spin --version   # spin 4.2.4
```

The SHA-256 above is copied verbatim from the release's own
`checksums-v4.2.4.txt`; the Dockerfile verifies the same binary against the
same hash at image-build time, so the host toolchain and the runtime image
never drift apart.

## Build

```sh
./build.sh          # build + wac plug + validate; no push
./build.sh --push   # also: spin registry push ghcr.io/patterncatalyst/cargo-spin:spinkube
```

`build.sh` builds the Part 2 provider from its own, unmodified recipe, writes
a throwaway `spin-build.toml` declaring the dependency on that freshly built
provider, runs `spin build -f spin-build.toml` (which regenerates
`spin-dependencies.wit` and compiles the handler to `wasm32-wasip2`), then
`wac plug`s the two into `cargo-spin.wasm`. It validates the result with
`wasm-tools validate`, asserts the export is `wasi:http/handler@0.3.0` and
that every remaining import is `wasi:*` (no `patterncatalyst:*` left
unsatisfied), and prints the sha256. `--push` additionally logs into
`ghcr.io` with `gh auth token` and runs `spin registry push` against the
committed `spin.toml`. This is never run automatically; the orchestrator runs
the live push.

`cargo-spin.wasm`, `spin-build.toml`, and `spin-dependencies.wit` are
regenerated every run and gitignored; `Cargo.lock` is committed for
reproducible builds.

## Deploy targets

This chapter runs the same artifact on both substrates this book always
compares, by two different mechanisms, the same constraint Part 6's Istio
chapter and Ch19's wasmCloud-operator move already established: a privileged
node-level install does not fit the `restricted-v2` SCC the CRC chapters hold
to.

### minikube: SpinKube

`containerd-shim-spin` (the KWasm successor, installed via the
`runtime-class-manager` Helm chart), the `spin-operator`, and a `SpinApp`
custom resource (`core.spinkube.dev/v1alpha1`) run `cargo-spin.wasm` the way
Part 5's `containerd-shim-wasmtime` runs `app.wasm`: a `RuntimeClass`-scoped
pod with no userland, except the control loop is now `spin-operator`
reconciling a `SpinApp`, not a bare `Deployment` with a `RuntimeClassName`.
Installing the shim, the operator, and the `SpinApp` manifest is this
chapter's cluster-facing half; this directory supplies the artifact
(`cargo-spin.wasm`) and its registry reference
(`ghcr.io/patterncatalyst/cargo-spin:spinkube`) that manifest points at.

### CRC: Spin runtime in a restricted-v2 container

`Dockerfile` packages the pinned `spin` v4.2.4 binary on `debian:trixie-slim`,
`COPY`s in `spin.toml` and `cargo-spin.wasm`, and runs as the fixed numeric
uid `10001` (a `runAsNonRoot: true` securityContext can only verify a
*numeric* user, the same convention `../../part5-kubernetes/kafka-host/
Containerfile` uses):

```sh
docker build --provenance=false -t ghcr.io/patterncatalyst/cargo-spin-runtime:crc -f Dockerfile .
```

`ENTRYPOINT` is `spin up --listen 0.0.0.0:8080 -f /app/spin.toml`. `spin up`
writes a wasmtime compilation cache under `$HOME/.cache`, so the image sets
`ENV HOME=/app` (owned by uid 10001) rather than leaving `HOME` to resolve to
a nonexistent or unwritable home directory. Without it, the container exits
immediately with `failed to
create cache directory`. Fronting this with an edge-TLS Route (the pattern
every other CRC chapter here uses) is the cluster-facing half of this target,
layered on top of the image this directory builds.

## Verify (no cluster)

```sh
./build.sh
wasm-tools validate cargo-spin.wasm
wasm-tools component wit cargo-spin.wasm | grep -E '^\s*(import|export)'
# expect: only `import wasi:*` lines, and `export wasi:http/handler@0.3.0;`

spin up --listen 127.0.0.1:3000 -f spin.toml &
curl -s http://127.0.0.1:3000/cargo/CARGO-USNYC-DEHAM
# {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/cargo/NOPE
# 404
kill %1
```
