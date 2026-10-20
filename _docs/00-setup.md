---
title: "Setup"
order: 0
part: "Prerequisites"
description: "Install and verify the Rust and Go build toolchain every Part 2-4 example compiles against: cargo-component, TinyGo, wit-bindgen-go, wasm-tools, and wasmtime, checked by check-prereqs.sh."
duration: "14 min read"
---

## Learning objectives

By the end of this chapter you can:

- Install Rust 1.99.1 with the `wasm32-wasip2` target and build `cargo-component` 0.21.1 from source, since no prebuilt Linux binary exists for it.
- Install Go 1.26.9, TinyGo 0.43.0, and `wit-bindgen-go` v0.7.0, and explain why TinyGo compiles the Go component instead of the standard Go toolchain.
- Install `wasm-tools` 1.262.0 and `wasmtime` 50.0.0 as pinned, checksum-verified release binaries, plus the wasip1→p2 reactor adapter the Go build needs.
- Run `check-prereqs.sh`, read what each OK/missing line actually checks, and fix a failing check from the install command the script prints.
- Run the build → inspect → run → verify loop against `examples/part2-building-components/` for both languages, then tear it down cleanly.

## Why this matters

Every hands-on chapter from Chapter 6 forward hands you two things: Rust source and Go source that both implement the same WIT contract, and a command that builds, runs, and checks each one. None of that is worth anything if the toolchain underneath it is a guess. This chapter pins the toolchain exactly, installs it on a clean machine, and gives you a script that answers one question before you type a single `cargo component build`: is everything this book's examples actually need already on `PATH`, at the version the examples were built and verified against?

That scope is narrow by design. This chapter covers the **build toolchain** only: the compilers, binding generators, and inspection tools Parts 2 through 4 use to turn `contracts/wit/` and two languages' source into running `.wasm` components and a native host that calls them. It does not cover wasmCloud or its `wash` CLI, which Part 4's runtime chapters install and use directly once components exist to run on a distributed host. It does not cover minikube, OpenShift Local (CRC), or the Grafana LGTM observability stack, which Part 5's deployment chapters bring up once there's a cluster to deploy to. Pulling those installs forward into this chapter would mean asking you to set up a Kubernetes cluster before you've built a single component to run on it, scope creep this site's own convention rules out. Each of those pieces gets its own setup section, in its own part, at the point its first chapter actually needs it.

What stays constant from here forward is everything below: the exact Rust and Go toolchain versions, the two pinned release binaries both languages build against, and the `check-prereqs.sh` script that confirms all of it before any chapter's own `verify.sh` runs. Every version number quoted in this chapter is a live, confirmed install on the authoring machine, not a planned pin: the same toolchain `examples/part2-building-components/` was built and verified against on 2026-10-20, recorded in `_plans/version-matrix.md`.

{% include excalidraw.html file="00-toolchain-map" alt="Diagram showing one shared WIT contract at the top feeding two separate toolchains below it. The Rust toolchain column shows Rust 1.99.1 with the wasm32-wasip2 target feeding cargo-component 0.21.1, which both generates bindings and builds the component in one step, producing cargo_rust.wasm. The Go toolchain column shows Go 1.26.9 and wit-bindgen-go v0.7.0 generating bindings, feeding TinyGo 0.43.0, which compiles the component (not standard go build), producing cargo-go.wasm via a wasm-tools embed and adapt step. Both columns converge on a shared band of pinned binaries — wasm-tools 1.262.0 and the wasip1-to-p2 reactor adapter — and below that, a shared wasmtime 50.0.0 runtime that runs both components. A note at the bottom says wasmCloud/wash and minikube/CRC/the LGTM stack are set up in their own later parts." caption="Figure 0.1 — The build toolchain: two languages, one contract, one host runtime." %}

## Installing Rust and cargo-component

Rust installs the normal way, through `rustup`, and this site pins to **1.99.1**, the current stable release at the time the Part 2 examples were built. There is no nightly toolchain anywhere in this chapter's install: stable Rust 1.99.1 already supports the `wasm32-wasip2` target and everything `cargo-component` needs, so a nightly channel would add a moving target for no feature this book's examples use. If a later chapter introduces a Wasm feature that needs a nightly-only capability, it pins a dated nightly (`nightly-2026-MM-DD`) at that point, not a floating `nightly` channel adopted here as a blanket default.

```bash
# Rust 1.99.1, stable channel (no nightly needed)
rustup toolchain install stable
rustup default stable
rustc --version   # rustc 1.99.1 (...)

# The Component Model target: builds compile to wasm32-wasip2, the
# WASI Preview 2 target cargo-component and wasmtime both expect.
rustup target add wasm32-wasip2
```

`cargo-component` is the harder install, and it's worth saying why up front: **there is no prebuilt Linux binary for `cargo-component` 0.21.1.** Unlike `wasm-tools` and `wasmtime` below, which ship signed release tarballs for every major platform, `cargo-component` is distributed as source only through `cargo install`, which means the install step compiles the whole crate and its dependency tree on your machine. That takes a few minutes the first time and is slower than downloading a binary, but it's the only path to this version. There's nothing to skip here, no faster alternative to reach for instead.

```bash
# No prebuilt binary exists for cargo-component; this compiles from source.
cargo install cargo-component --locked --version 0.21.1
cargo-component --version   # cargo-component 0.21.1
```

`--locked` matters here the same way it matters in any Rust install: it tells Cargo to build against the exact dependency versions recorded in `cargo-component`'s own `Cargo.lock`, rather than re-resolving its dependency graph against whatever's newest on crates.io today. Two machines running this exact command on two different days both end up with the identical `cargo-component` binary, built from the identical dependency tree, which is the entire point of pinning a tool by version in the first place. Once installed, `cargo-component` is the only tool the Rust side of Chapter 6 needs beyond `cargo` itself: it reads `contracts/wit/`, generates Rust bindings for the `cargo` world, and builds the component in one step, covered in full when Chapter 6 walks through `examples/part2-building-components/rust/`.

## Installing Go, TinyGo, and wit-bindgen-go

Go installs the standard way from the official distribution, pinned to **1.26.9**. Everything past that first command is where the Go toolchain story gets less standard than it looks, so it's worth being direct about the shape of it before Chapter 7 covers the mechanism in depth.

```bash
# Go 1.26.9, standard install, no special build tags
# (download from https://go.dev/dl/ or your platform's package manager)
go version   # go version go1.26.9 ...
```

The binding generator comes next, installed the normal `go install` way, pinned to an exact tag:

```bash
go install go.bytecodealliance.org/cmd/wit-bindgen-go@v0.7.0
wit-bindgen-go version   # wit-bindgen-go version v0.7.0
```

`wit-bindgen-go` reads `contracts/wit/` the same way `cargo-component` does on the Rust side, and generates a Go package of structs and function signatures for the `cargo` world. Those generated bindings import one more package worth pinning explicitly: `go.bytecodealliance.org/cm`, the Canonical ABI support types (`cm.Result`, variant and option representations) every generated signature uses. Pin it to **v0.3.0** specifically, not whatever `go get` resolves to by default. The `go.bytecodealliance.org` module is a monorepo, and the `v0.4.0` through `v0.7.0` tags were cut on the repository's *root* module rather than the `/cm` subpackage, so Go's module resolution rejects them for the `go.bytecodealliance.org/cm` import path entirely; only `v0.3.0` resolves. This is in a component's own `go.mod`, not a global install step, but it belongs in this chapter because it's exactly the kind of version mismatch `check-prereqs.sh` can't catch (it lives in a `go.sum`, not on `PATH`) and exactly the kind of thing worth knowing about before Chapter 7 hands you a `go.mod` that already has it pinned.

**Now the toolchain's real deviation: install TinyGo 0.43.0, because it, not the standard `go build` you just installed, compiles the Go component.**

```bash
# TinyGo 0.43.0, confirmed working against Go 1.26.9 / LLVM 22.1.4
# (install per https://tinygo.org/getting-started/install/)
tinygo version   # tinygo version 0.43.0 ...
```

Why a second compiler for one language: the standard Go 1.26 toolchain's `GOOS=wasip1 GOARCH=wasm` target cannot compile the code `wit-bindgen-go` generates. Go's `//go:wasmexport` directive, which the generated bindings use to mark exported functions, refuses to export a function that returns a pointer to a pointer-containing type, exactly the shape a WIT `result` or `variant` lowers to in Go. The restriction exists because standard Go uses 64-bit pointers even when targeting 32-bit wasm, and the Component Model's Canonical ABI needs 32-bit pointers at that boundary; there's a `GOARCH=wasm32` mode that would resolve the mismatch, but it has no buildable build mode on this Go release. TinyGo targets 32-bit wasm as a first-class target rather than a cross-compilation mode bolted onto a 64-bit runtime, so it compiles the identical generated bindings without hitting that restriction at all. Nothing about the Go **source** changes as a result: `wit-bindgen-go`'s output and the `cm` module are exactly the same regardless of which compiler reads them. Only which compiler turns that source into a `.wasm` binary changes. Chapter 7 walks through this exact failure, the compiler error message that names it, and the rest of the Go build pipeline in full; this chapter's job is only to make sure TinyGo is on `PATH` before you get there.

## Pinned binaries: wasm-tools, wasmtime, and the adapter

Two tools sit underneath both languages rather than belonging to either one: `wasm-tools`, the Bytecode Alliance's Swiss-army CLI for inspecting, validating, embedding, and adapting WebAssembly components and WIT packages, and `wasmtime`, the Bytecode Alliance's own Wasm runtime, which both the native host in `examples/part2-building-components/host` and this chapter's own manual checks use to actually run a built component. Both are pinned to an exact release and installed as release binaries rather than compiled from source, and both get their checksum verified against the published SHA-256 before anything on your machine touches the downloaded archive. That is the same pattern the repository's own `contracts` CI job uses to install `wasm-tools` for the WIT validation gate, so the install step you run by hand mirrors exactly what CI runs unattended.

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

`wasmtime` installs the same way, from its own release page, pinned to **50.0.0**. The release publishes a `SHA256SUMS` file alongside every platform's archive; download that file from the same `v50.0.0` release tag and verify your downloaded archive against the matching line before installing, exactly as the `wasm-tools` step above verifies against one checksum pinned inline. A native Rust program depending on `wasmtime` as a *library* (the host in `examples/part2-building-components/host` does exactly this, through `Cargo.toml`'s `wasmtime = "50"` dependency) gets its own version pinned and locked through `Cargo.lock` the normal Cargo way and needs no separate binary install; the `wasmtime` CLI installed here is for running a component directly from a terminal, independent of that host binary, which is what the manual checks in this chapter and the next few chapters reach for.

One more binary is pinned, and it's small enough to vendor directly into the repository rather than download at build time: the **wasip1→p2 reactor adapter**, shipped as an artifact of the wasmtime v50.0.0 release itself (`wasi_snapshot_preview1.reactor.wasm`). TinyGo's compiler output targets WASI Preview 1, and there is no TinyGo wasip2 target yet, so turning that output into a component that speaks WASI Preview 2, the version `contracts/wit` and the host both expect, needs an adapter module that bridges the two ABIs. `examples/part2-building-components/go/adapters/wasi_snapshot_preview1.reactor.wasm` is that adapter, already checked into the repository with its SHA-256 recorded in the example's own `README.md`, specifically the **reactor** variant rather than the **command** variant, because the Go core module TinyGo produces is a reactor (it exports `_initialize`, not `_start`) rather than a one-shot command binary. `wasm-tools component new` is the tool that actually applies this adapter during the Go build, in the exact step Chapter 7 walks through.

## check-prereqs.sh

`scripts/check-prereqs.sh` is the first thing to run on a fresh machine, before touching any example directory. It installs nothing; it only confirms that every tool this chapter just walked through is on `PATH`, at a version new enough to match what the examples were built against, and it reports every gap in one pass rather than stopping at the first missing tool and leaving the rest a mystery.

```bash
$ ./scripts/check-prereqs.sh
checking the Part 2-4 build toolchain (Ch0) ...

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

A missing or under-pinned tool prints its own line and the exact install command that fixes it, then keeps checking everything after it, rather than treating the first gap as a reason to stop reporting:

```text
cargo-component    missing    not found
    install: cargo install cargo-component --locked --version 0.21.1   # built from source, no prebuilt linux binary
```

Each check in the script follows the same three-step shape: confirm the binary exists on `PATH`, extract its reported version from the tool's own `--version` (or `version`) output with a small regular expression, and compare that version against a pinned minimum with a dotted-version-aware sort, the same `sort -V` trick used anywhere a plain string comparison would wrongly rank `1.9.0` above `1.10.0`. The one check that isn't a binary-on-`PATH` lookup is `wasm32-wasip2`, which is a `rustup` target rather than a standalone tool, checked instead through `rustup target list --installed`. The script exits non-zero the instant any single check fails to find its tool or falls under its pinned minimum, which is what makes it safe to drop into the front of any example's `verify.sh` as a guard clause: a CI run or a reader's terminal that doesn't pass `check-prereqs.sh` never gets far enough to hit a confusing `cargo-component` or `wasm-tools` error with no indication of which tool or version actually caused it.

## Version matrix

`_plans/version-matrix.md` is the single source of truth for every pinned version in this site, build toolchain and deployment tier alike, each one tied to the date it was last verified against the upstream release it names. This chapter's own pins are a subset of that table: the rows confirmed and installed on 2026-10-20, the same date the Part 2 examples were built and verified.

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

Don't treat the table above as the canonical copy; it's a summary scoped to this chapter's build toolchain. `_plans/version-matrix.md` carries the full picture, including the WASI Preview 2/3 status this site tracks, the Kubernetes deployment tier snapshot Part 5 re-verifies live when its chapters land, and the dependency policy itself: pin every tool to its upstream latest stable release at the time it's surveyed, exactly, never a floating major or a `latest` tag, and bump it only as a deliberate, reviewed change rather than a side effect of unrelated work.

## The dev loop

Every hands-on chapter from Chapter 6 on repeats the same four-step loop against `examples/part2-building-components/`, once per language, and this is the first point in the site worth walking through it end to end rather than one command at a time.

{% include excalidraw.html file="00-dev-loop" alt="Diagram of a five-step loop. Step 1, build: cargo component build --release for Rust, or ./go/build.sh (TinyGo) for Go. Step 2, inspect: wasm-tools component wit on the built .wasm file, to see its exported interfaces. Step 3, run: the native cargo-host binary, given the .wasm file, the shared scenario.json fixture, and a language label. Step 4, verify: ./verify.sh, which runs both languages' build and run steps, diffs the Rust output against the Go output, and checks each component's exported interfaces against contracts/wit. Step 5, teardown: cargo clean and removing the generated .wasm artifacts between runs. A note states check-prereqs.sh runs once before step 1." caption="Figure 0.2 — The dev loop: build, inspect, run, verify, teardown." %}

**Build** means `cargo component build --release` from `examples/part2-building-components/rust/`, or `./build.sh` from the `go/` directory, which itself runs `wit-bindgen-go generate`, then `tinygo build -target=wasip1 -buildmode=c-shared`, then the `wasm-tools component embed` and `component new --adapt` steps that turn TinyGo's reactor core module into a real component. **Inspect** means running `wasm-tools component wit` against whichever `.wasm` file the build step just produced (`target/wasm32-wasip1/release/cargo_rust.wasm` for Rust, `cargo-go.wasm` for Go), which prints the component's exported interfaces back out as WIT text, the fastest way to confirm a build actually exports `world cargo`'s three interfaces (`types`, `booking`, `handling`) before running anything against it. **Run** means invoking the native host, `cargo-host`, built once from `examples/part2-building-components/host/` with a plain `cargo build --release`, and pointed at either language's `.wasm` file plus the shared `fixtures/scenario.json`:

```bash
./host/target/release/cargo-host rust/target/wasm32-wasip1/release/cargo_rust.wasm \
  fixtures/scenario.json rust
./host/target/release/cargo-host go/cargo-go.wasm \
  fixtures/scenario.json go
```

**Verify** folds all three of those steps into one command, `./verify.sh`, which builds both components, builds the host, runs the host against each component in turn, diffs the two JSON summaries for byte-for-byte equality, and checks both components' exported interfaces against `contracts/wit` using the shared `assert_component_matches_contract` helper in `examples/_lib/lib.sh`. Running `verify.sh` is the single command Chapter 6, Chapter 7, and Chapter 8 all converge on as "did this work," because a pass means two independently built, independently compiled components (one from a crate with its own `Cargo.toml`, one from a TinyGo build with its own adapter step) produced identical observable results from identical input, which is the entire claim this site makes about building the same domain twice.

## Teardown

Nothing this loop produces needs to survive between runs, and `examples/part2-building-components/.gitignore` already names exactly what to clean: `rust/target/`, `host/target/`, and the Go side's three generated artifacts, `go/core.wasm`, `go/embedded.wasm`, and `go/cargo-go.wasm`. The cleanest teardown is two commands:

```bash
# Rust and host build artifacts
( cd examples/part2-building-components/rust && cargo clean )
( cd examples/part2-building-components/host && cargo clean )

# Go's generated outputs (build.sh regenerates all three from a clean state)
rm -f examples/part2-building-components/go/core.wasm \
      examples/part2-building-components/go/embedded.wasm \
      examples/part2-building-components/go/cargo-go.wasm
```

`cargo clean` removes an entire `target/` tree rather than a single binary, which is the right scope here: both the Rust component's build and the host's build accumulate incremental compilation artifacts and dependency build output that have no reason to persist once you're done with a session, and nothing in either `target/` directory is checked into the repository. The Go side has no `target/` equivalent; TinyGo and `wasm-tools` write their three outputs directly into `go/`, so removing them by name is the direct equivalent of `cargo clean` for that side, and `build.sh` regenerates all three from scratch on its next run regardless of whether the previous run's outputs were cleaned up first. Neither cleanup step touches `go/adapters/wasi_snapshot_preview1.reactor.wasm`, the vendored adapter checked into the repository to stay, or anything under `contracts/wit/`, which no build step in this loop ever writes to.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>This chapter pins Rust 1.99.1 with the <code>wasm32-wasip2</code> target and <code>cargo-component</code> 0.21.1 built from source (no prebuilt Linux binary exists for it), Go 1.26.9 with <code>wit-bindgen-go</code> v0.7.0 and the <code>go.bytecodealliance.org/cm</code> v0.3.0 module, and <code>wasm-tools</code> 1.262.0 plus <code>wasmtime</code> 50.0.0 as release binaries verified by SHA-256 before install: the same pinned-and-verified pattern the repository's own CI uses for <code>wasm-tools</code>, extended here to every tool a reader installs by hand. The one deviation that earns this callout rather than a footnote: TinyGo 0.43.0, not the standard Go 1.26 toolchain, compiles the Go component, because standard Go's <code>wasip1/wasm</code> target cannot export the pointer-containing result and variant types <code>wit-bindgen-go</code> generates, and <code>wasm32</code> mode has no buildable build mode on this Go release. That's a real constraint on the installed toolchain, not a style preference. The Go <strong>source</strong>, the generated bindings, and the <code>cm</code> module are identical regardless of which compiler reads them, and Chapter 7 is where that constraint and its fix get the full treatment this chapter only has room to name.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning, 2026) — the toolchain landscape across languages this chapter's Rust and Go install steps are drawn from.
- Shashank Jain, *WebAssembly for Cloud* (Apress, 2024) — contract-first component tooling and the binding-generator pattern both `cargo-component` and `wit-bindgen-go` follow.
- [cargo-component](https://github.com/bytecodealliance/cargo-component) — the Rust binding generator and component builder this chapter installs from source.
- [wit-bindgen-go](https://github.com/bytecodealliance/wit-bindgen-go) — the Go binding generator, and the `go.bytecodealliance.org/cm` module pin this chapter calls out.
- [TinyGo](https://tinygo.org/) — the compiler that builds the Go component, and its WebAssembly target documentation.
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) and [wasmtime](https://github.com/bytecodealliance/wasmtime) release pages — the pinned, checksum-verified binaries this chapter installs, and the source of the wasip1→p2 reactor adapter vendored into `examples/part2-building-components/go/adapters/`.
