---
title: "Setup"
order: 0
part: "Prerequisites"
description: "Install and verify the Rust and Go build toolchain the Part 2 to 4 examples compile against: cargo-component, TinyGo, wit-bindgen-go, wasm-tools and wasmtime, checked by check-prereqs.sh."
duration: "10 min read"
---

## Learning objectives

By the end of this chapter you can:

- Install Rust 1.99.1 with the `wasm32-wasip2` target and build `cargo-component` 0.21.1 from source, since no prebuilt Linux binary exists for it.
- Install Go 1.26.9, TinyGo 0.43.0, and `wit-bindgen-go` v0.7.0, and explain why TinyGo compiles the Go component instead of the standard Go toolchain.
- Install `wasm-tools` 1.262.0 and `wasmtime` 50.0.0 as pinned, checksum-verified release binaries, plus the wasip1 to p2 reactor adapter the Go build needs.
- Run `check-prereqs.sh` and fix a failing check from the install command it prints.
- Run the build, inspect, run, verify loop against `examples/part2-building-components/` for both languages, then clean up.

## Why this matters

Every hands-on component chapter gives you Rust source and Go source that implement the same WIT contract, plus a command that builds, runs and checks each. That only works if the toolchain underneath is exact. Everything here is pinned to the versions the Part 2 examples were built and verified against on 2026-10-20.

Only the **build toolchain** is covered: the compilers, binding generators and inspection tools that turn `contracts/wit/` and two languages' source into `.wasm` components and a native host that calls them. wasmCloud and `wash` are installed in the runtime part, and minikube, OpenShift Local (CRC) and the Grafana LGTM stack in the deployment part, each when its first chapter needs it.

{% include excalidraw.html file="00-toolchain-map" alt="Diagram showing one shared WIT contract at the top feeding two separate toolchains below it. The Rust toolchain column shows Rust 1.99.1 with the wasm32-wasip2 target feeding cargo-component 0.21.1, which both generates bindings and builds the component in one step, producing cargo_rust.wasm. The Go toolchain column shows Go 1.26.9 and wit-bindgen-go v0.7.0 generating bindings, feeding TinyGo 0.43.0, which compiles the component (not standard go build), producing cargo-go.wasm via a wasm-tools embed and adapt step. Both columns converge on a shared band of pinned binaries (wasm-tools 1.262.0 and the wasip1-to-p2 reactor adapter), and below that, a shared wasmtime 50.0.0 runtime that runs both components. A note at the bottom says wasmCloud, minikube, OpenShift Local and the observability stack are set up in later parts." caption="Figure 0.1: The build toolchain: two languages, one contract, one host runtime." %}

## Installing Rust and cargo-component

Rust comes from `rustup`, pinned to **1.99.1** stable. No nightly is needed: stable already supports `wasm32-wasip2` and everything `cargo-component` uses. If a later chapter needs a nightly-only feature, it pins a dated nightly (`nightly-2026-MM-DD`), never a floating channel.

```bash
# Rust 1.99.1, stable channel (no nightly needed)
rustup toolchain install stable
rustup default stable
rustc --version   # rustc 1.99.1 (...)

# The Component Model target: builds compile to wasm32-wasip2, the
# WASI Preview 2 target cargo-component and wasmtime both expect.
rustup target add wasm32-wasip2
```

`cargo-component` 0.21.1 has no prebuilt Linux binary. It ships as source through `cargo install`, so the first install compiles the crate and its dependencies, which takes a few minutes.

```bash
# No prebuilt binary exists for cargo-component; this compiles from source.
cargo install cargo-component --locked --version 0.21.1
cargo-component --version   # cargo-component 0.21.1
```

`--locked` builds against the dependency versions in the tool's own `Cargo.lock` instead of re-resolving against crates.io, so two machines get the same binary. `cargo-component` is the only tool the Rust component needs beyond `cargo`: one command reads `contracts/wit/`, generates bindings for the `cargo` world and builds the component.

## Installing Go, TinyGo, and wit-bindgen-go

Go installs the standard way, pinned to **1.26.9**. The binding generator comes from `go install` at an exact tag.

```bash
# Go 1.26.9, standard install, no special build tags
# (download from https://go.dev/dl/ or your platform's package manager)
go version   # go version go1.26.9 ...
```

```bash
go install go.bytecodealliance.org/cmd/wit-bindgen-go@v0.7.0
wit-bindgen-go version   # wit-bindgen-go version v0.7.0
```

`wit-bindgen-go` generates a Go package of structs and signatures for the `cargo` world. The generated code imports `go.bytecodealliance.org/cm`, the Canonical ABI support types (`cm.Result`, variants, options). Pin it to **v0.3.0** in the component's `go.mod`. The module is a monorepo, and the `v0.4.0` through `v0.7.0` tags were cut on the root module rather than the `/cm` subpackage, so Go rejects them for that import path. `check-prereqs.sh` cannot catch this one because it lives in `go.sum`, not on `PATH`.

**Install TinyGo 0.43.0: it, not the standard `go build`, compiles the Go component.**

```bash
# TinyGo 0.43.0, confirmed working against Go 1.26.9 / LLVM 22.1.4
# (install per https://tinygo.org/getting-started/install/)
tinygo version   # tinygo version 0.43.0 ...
```

The standard toolchain's `GOOS=wasip1 GOARCH=wasm` target cannot compile what `wit-bindgen-go` generates. The generated bindings mark exports with `//go:wasmexport`, and Go refuses to export a function that returns a pointer to a pointer-containing type, which is exactly what a WIT `result` or `variant` lowers to. Standard Go uses 64-bit pointers even on wasm, while the Canonical ABI needs 32-bit pointers at that boundary. A `GOARCH=wasm32` mode would fix that, but it has no buildable mode on this Go release. TinyGo targets 32-bit wasm natively, so it compiles the same generated bindings. The Go source does not change; only the compiler that produces the `.wasm` does.

## Pinned binaries: wasm-tools, wasmtime, and the adapter

Two tools sit under both languages. `wasm-tools` inspects, validates, embeds and adapts components and WIT packages. `wasmtime` is the runtime that runs a built component from a terminal. Both are release binaries verified against a published SHA-256 before anything touches the archive. The `wasm-tools` step is the one the repository's CI uses for WIT validation.

```bash
# wasm-tools 1.262.0, pinned release binary, checksum-verified
# (mirrors .github/workflows/contracts.yml's install step)
WASM_TOOLS_VERSION="1.262.0"
WASM_TOOLS_SHA256="655b8df67d54c3ef9b52fc237c4e94bbfbb5f5f43825245cb0940a7002a9ed65"
archive="wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux.tar.gz"
curl -fsSL -o "/tmp/${archive}" \
  "https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/${archive}"
echo "${WASM_TOOLS_SHA256}  /tmp/${archive}" | sha256sum -c -
tar -xzf "/tmp/${archive}" -C /tmp
sudo install -m 0755 "/tmp/wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux/wasm-tools" /usr/local/bin/wasm-tools
wasm-tools --version   # wasm-tools 1.262.0 (...)
```

`wasmtime` 50.0.0 installs the same way. The release publishes a `SHA256SUMS` file next to every archive; verify the download against the matching line. The native host in `examples/part2-building-components/host` depends on `wasmtime` as a library through `Cargo.toml` (`wasmtime = "50"`), pinned by `Cargo.lock`, so it needs no binary; the CLI is for running a component directly.

One more pinned binary is vendored into the repository: the **wasip1 to p2 reactor adapter**, `wasi_snapshot_preview1.reactor.wasm` from the wasmtime v50.0.0 release. TinyGo emits WASI Preview 1 and has no wasip2 target, so an adapter bridges to the Preview 2 ABI that `contracts/wit` and the host expect. It sits at `examples/part2-building-components/go/adapters/` with its SHA-256 recorded in the `README.md` beside the code. It is the **reactor** variant, not the **command** variant, because the Go core module exports `_initialize`, not `_start`. `wasm-tools component new --adapt` applies it during the Go build.

## check-prereqs.sh

Run `scripts/check-prereqs.sh` first on a fresh machine. It installs nothing. It confirms each tool is on `PATH` at or above its pinned version, and reports every gap in one pass:

```bash
$ ./scripts/check-prereqs.sh
checking the Part 2-4 build toolchain ...

rustc              1.99.1     OK  (pin 1.99.1)
cargo              1.99.1     OK  (pin 1.99.1)
cargo-component    0.21.1     OK  (pin 0.21.1)
go                 1.26.9     OK  (pin 1.26.9)
tinygo             0.43.0     OK  (pin 0.43.0)
wit-bindgen-go     0.7.0      OK  (pin v0.7.0)
wasm-tools         1.262.0    OK  (pin 1.262.0)
wasmtime           50.0.0     OK  (pin 50.0.0)
wasm32-wasip2      installed  OK

all checks passed: Part 2-4 build toolchain is ready
```

A failing check prints its own line and the install command that fixes it, then keeps checking:

```text
cargo-component    missing    not found
    install: cargo install cargo-component --locked --version 0.21.1   # built from source, no prebuilt linux binary
```

Versions are compared with a dotted-version-aware sort (`sort -V`), so `1.10.0` ranks above `1.9.0`. The `wasm32-wasip2` check is a `rustup target list --installed` lookup rather than a binary. The script exits non-zero on any gap, which makes it a safe guard at the front of any example's `verify.sh`.

## Version matrix

| Tool | Pinned version |
|---|---|
| Rust (stable) | 1.99.1 |
| `cargo-component` | 0.21.1 |
| Go | 1.26.9 |
| TinyGo | 0.43.0 |
| `wit-bindgen-go` | v0.7.0 |
| `go.bytecodealliance.org/cm` | v0.3.0 |
| `wasm-tools` | 1.262.0 |
| `wasmtime` | 50.0.0 |

The policy behind the table: pin every tool to its latest stable release at survey time, exactly, never a floating major or a `latest` tag, and bump it only as a deliberate, reviewed change.

## The dev loop

Every component chapter repeats one loop against `examples/part2-building-components/`, once per language.

{% include excalidraw.html file="00-dev-loop" alt="Diagram of a five-step loop. Step 1, build: cargo component build --release for Rust, or ./go/build.sh (TinyGo) for Go. Step 2, inspect: wasm-tools component wit on the built .wasm file, to see its exported interfaces. Step 3, run: the native cargo-host binary, given the .wasm file, the shared scenario.json fixture, and a language label. Step 4, verify: ./verify.sh, which runs both languages' build and run steps, diffs the Rust output against the Go output, and checks each component's exported interfaces against contracts/wit. Step 5, teardown: cargo clean and removing the generated .wasm artifacts between runs. check-prereqs.sh runs once before step 1." caption="Figure 0.2: The dev loop: build, inspect, run, verify, teardown." %}

**Build** is `cargo component build --release` in `rust/`, or `./build.sh` in `go/`, which runs `wit-bindgen-go generate`, then `tinygo build -target=wasip1 -buildmode=c-shared`, then `wasm-tools component embed` and `component new --adapt` to turn TinyGo's reactor core module into a component. **Inspect** is `wasm-tools component wit` on the built `.wasm` (`target/wasm32-wasip1/release/cargo_rust.wasm` or `cargo-go.wasm`), which prints the exported interfaces as WIT, the fastest way to confirm `world cargo` exports `types`, `booking` and `handling`. **Run** is the native host, built once with `cargo build --release` in `host/`:

```bash
./host/target/release/cargo-host rust/target/wasm32-wasip1/release/cargo_rust.wasm \
  fixtures/scenario.json rust
./host/target/release/cargo-host go/cargo-go.wasm \
  fixtures/scenario.json go
```

**Verify** is `./verify.sh`: it builds both components and the host, runs each, requires the two JSON summaries to be byte-identical, and checks both components' exports against `contracts/wit`. A pass means two independently compiled components produced identical results from identical input.

## Teardown

Nothing the loop produces needs to survive between runs; `examples/part2-building-components/.gitignore` names it all. Clean the Rust and host `target/` trees (incremental build output, never checked in) and the Go side's three generated artifacts, which TinyGo and `wasm-tools` write straight into `go/`; `build.sh` regenerates them.

```bash
# Rust and host build artifacts
( cd examples/part2-building-components/rust && cargo clean )
( cd examples/part2-building-components/host && cargo clean )

# Go's generated outputs (build.sh regenerates all three from a clean state)
rm -f examples/part2-building-components/go/core.wasm \
      examples/part2-building-components/go/embedded.wasm \
      examples/part2-building-components/go/cargo-go.wasm
```

Neither step touches the vendored adapter in `go/adapters/` or anything under `contracts/wit/`.

> **Decision**
>
> Pin every tool exactly and verify release binaries by SHA-256. Build the Go component with TinyGo, not standard Go, because `wasip1/wasm` cannot export the pointer-containing result and variant types `wit-bindgen-go` generates.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning, 2026): the toolchain landscape across languages.
- Shashank Jain, *WebAssembly for Cloud* (Apress, 2024): contract-first component tooling and the binding-generator pattern both `cargo-component` and `wit-bindgen-go` follow.
- [cargo-component](https://github.com/bytecodealliance/cargo-component): the Rust binding generator and component builder.
- [wit-bindgen-go](https://github.com/bytecodealliance/wit-bindgen-go): the Go binding generator and the `cm` module pin.
- [TinyGo](https://tinygo.org/): the compiler for the Go component, and its WebAssembly target documentation.
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) and [wasmtime](https://github.com/bytecodealliance/wasmtime) release pages: the pinned binaries and the source of the reactor adapter.
