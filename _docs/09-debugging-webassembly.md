---
title: "Debugging WebAssembly"
order: 9
part: "Building Components in Rust & Go"
description: "Inspect a component without running it, read a wasmtime trap backtrace from both the Rust and Go providers, and see exactly how far source-level debugging reaches today."
duration: "20 min read"
---

## Learning objectives

By the end of this chapter you can:

- Read a component's exported world straight off the compiled binary with `wasm-tools component wit`, without running it or trusting a README's description of what it should export.
- Use `wasm-tools print` and `wasm-tools objdump` to see the canonical-ABI glue (`canon lift`/`canon lower`) and the core module sections underneath a component, including whether DWARF debug info is present at all.
- Distinguish a recoverable `cargo-error` from an unrecoverable trap in a real wasmtime backtrace, for both the Rust and the Go provider, and explain why one backtrace resolves file:line and the other doesn't.
- Read what a component wrote to its own stderr on the way down, through the host's `inherit_stderr()` wiring, and know why that single wire is most of this book's "logging."
- State what source-level, breakpoint-based debugging of a component looks like today: a native-level gdbstub, not a WIT-aware step-through, and when it's worth reaching for over backtraces and stderr.

## Why this matters

The Rust and Go providers both implement the identical `world cargo`, and both compose with consumers through `wac`. None of that work needed to ask what happens when something goes wrong, because nothing did: `verify.sh` asserts a byte-identical summary from both languages and stops there. What happens when something does go wrong is the question here. `examples/part2-building-components/host/src/main.rs` already carries the answer in its last twenty lines, a deliberate `__TRAP__` sentinel that makes `get-cargo` panic, run last because a trap poisons the wasmtime `Store` the instance lives in. That one sentinel, built into both `rust/src/lib.rs` and `go/main.go` in lockstep, is the subject here: one failure, observed through six different tools, each one answering a question the others can't.

WebAssembly's debugging story in 2026 is uneven in a specific way. Static inspection is mature: `wasm-tools` reads a `.wasm` binary's own embedded types and prints them back with no ambiguity. Runtime backtraces are mature too, the most useful tool here: wasmtime resolves demangled function names on every trap, and resolves full source file:line when the underlying core module carries DWARF. What isn't mature, as of wasmtime 50 and TinyGo 0.43, is an IDE-integrated, WIT-aware, breakpoint-and-step workflow across the component boundary. That line falls exactly where the real output below, captured against the Part 2 components rather than a hypothetical, shows it.

{% include excalidraw.html file="09-symptom-to-tool" alt="Six rows, each a symptom box on the left, the cheapest tool that taps it in the middle, and a caveat box on the right. Row 1: need the shape before running it: wasm-tools component wit file.wasm prints the world and interfaces embedded in the binary. Row 2: need to see the ABI glue (canon lift/canon lower): wasm-tools print file.wasm WAT produces tens of thousands of lines, so grep for the export name. Row 3: is DWARF even present: wasm-tools objdump file.wasm shows per-section sizes, so look for debug_info under each module. Row 4: component trapped at runtime: wasmtime run or host plus WASMTIME_BACKTRACE_DETAILS=1 gives one frame per call, with file:line only if that module has DWARF. Row 5: need what the component wrote on its way down: WasiCtxBuilder inherit_stderr sends panic and log lines to the host process's own stderr. Row 6: need to pause and step through source: wasmtime run -g/--gdbstub PORT, an LLDB gdbstub, works at the native/core level only, with no WIT-aware source view yet. A caption below notes all six run against the same Part 2 artifacts with no rebuild or instrumentation required." caption="Figure 9.1: six symptoms against the Part 2 cargo components, the cheapest tool for each, and the caveat worth knowing before trusting the answer." %}

## Inspecting a component without running it

The cheapest debugging question is the one that never needs a running instance at all: what does this binary export and import? `wasm-tools component wit` answers it directly, reading the component's own embedded type section rather than any `.wit` source file on disk. Run against both Part 2 artifacts, it surfaces something the README's prose only asserts:

```text
# rust/target/wasm32-wasip1/release/cargo_rust.wasm
world root {
  import wasi:cli/environment@0.2.3;
  ...
  export patterncatalyst:cargo/types@0.1.0;
  export patterncatalyst:cargo/booking@0.1.0;
  export patterncatalyst:cargo/handling@0.1.0;
}

# go/cargo-go.wasm
world root {
  import wasi:cli/environment@0.2.12;
  ...
  export patterncatalyst:cargo/types@0.1.0;
  export patterncatalyst:cargo/booking@0.1.0;
  export patterncatalyst:cargo/handling@0.1.0;
}
```

Both components export the identical `patterncatalyst:cargo` interfaces at `0.1.0`, which is what composing them with `wac plug` depends on. The full, un-trimmed output also shows, and this one-command check catches before a composition step ever runs, the WASI minor-version skew between the two components: the Rust component imports `wasi:cli@0.2.3`, the Go component imports `wasi:cli@0.2.12`. `wasm-tools component wit` doesn't resolve that skew itself (wasmtime's semver-compatible component linking does, at instantiation); it's the fastest way to confirm the skew exists at all, before assuming two components built months apart against the same contract are importing identical WASI. The command tolerates an absolute or relative path to the `.wasm` file, and needs no WASI runtime, no host, and no `fixtures/scenario.json`. It reads the binary's type section and nothing else.

`wasm-tools print` goes one level deeper, printing the component's full WAT (WebAssembly Text) representation, canonical-ABI glue included. Against `cargo_rust.wasm`, a 150 KB binary, this produces 40,400 lines of text, most of it the exact same twelve WASI interfaces every component in this book imports, printed in full every time. That volume is the practical lesson: `wasm-tools print` is not a tool you read top to bottom; it's a tool you grep. Searching for `get-cargo` surfaces the exact canonical-ABI line that turns a type-erased core function into the typed WIT function the Component Model defines:

```wat
(alias core export 3 "patterncatalyst:cargo/booking@0.1.0#get-cargo" (core func (;54;)))
(alias core export 3 "cabi_post_patterncatalyst:cargo/booking@0.1.0#get-cargo" (core func (;55;)))
(func (;19;) (type 36) (canon lift (core func 54) (memory 0) (realloc 23) string-encoding=utf8 (post-return 55)))
```

`canon lift` is the component-model primitive this chapter's whole DWARF discussion hinges on. It wraps `core func 54`, an ordinary numbered function inside the one core module the build produced, declares the memory and string encoding needed to marshal its arguments and result, and names a `post-return` function for cleanup. Everything above this layer (WIT records, variants, resources) is erased by the time execution reaches `core func 54`; everything below it is where a debugger, if one exists for this boundary, has to attach. The file ends with a `@producers` section worth reading for provenance: `(processed-by "wit-component" "0.227.1") (processed-by "cargo-component" "0.21.1") (language "Rust" "")`, a verifiable record of exactly which toolchain versions produced the artifact sitting on disk, independent of whatever a `Cargo.toml` or a CI log claims.

`wasm-tools objdump` answers a narrower, faster question than either of the above: what sections exist, and how big are they? Run against both components, the difference is the first finding that matters here. The Rust core module's section list has no `.debug_*` entries at all, just `types`, `imports`, `functions`, `code`, `data`, and the `name` custom section cargo-component's toolchain always keeps. The Go core module's section list looks different:

```text
custom "name"                 |  14624 bytes | 1 count
custom ".debug_info"          | 151219 bytes | 1 count
custom ".debug_abbrev"        |   3926 bytes | 1 count
custom ".debug_aranges"       |     96 bytes | 1 count
custom ".debug_line"          |  81047 bytes | 1 count
custom ".debug_ranges"        |   7192 bytes | 1 count
custom ".debug_loc"           |  59892 bytes | 1 count
custom ".debug_str"           | 122690 bytes | 1 count
custom ".debug_pubnames"      | 162704 bytes | 1 count
custom ".debug_pubtypes"      |  11643 bytes | 1 count
```

TinyGo's `-target=wasip1` build embeds a full DWARF debug-info set by default: nearly 600 KB of it, more than two-thirds the size of the 812 KB Go core module itself. `cargo-component build --release` embeds none, because the crate's `Cargo.toml` sets no `[profile.release] debug = true`, and a plain `--release` profile strips debug info the same way it would for a native binary. That difference comes from a build default, not from either toolchain's capability, and it's the one `objdump` check that predicts, before anything ever traps, whether a backtrace against that artifact will resolve a file and a line number or stop at a function name.

## Where debug info lives

That `objdump` finding generalizes into a shape worth drawing once and reusing for every component this book builds: a component wraps one or more core modules, and DWARF, when it exists, lives inside exactly one of them, never at the component layer itself.

{% include excalidraw.html file="09-component-debug-layers" alt="Three bands top to bottom. Component boundary band: a single ink box reading patterncatalyst:cargo component, canon lift / canon lower glue, no debug info of its own, with dashed arrows down to two core modules. Core modules band: a left box, Core module 0, Rust cargo-component --release, custom name section only, no debug_info or debug_line (no profile.release.debug=true); a right box, Core module 0, Go TinyGo -target=wasip1, custom name plus full DWARF, debug_info/debug_line/debug_str embedded by default; and a dashed ghost box below spanning both, the wasi_snapshot_preview1 adapter vendored wasm, named functions only, no DWARF either side. Backtrace band: a left accent box, Rust TRAP backtrace, demangled crate/fn names 12 frames ending at booking#get-cargo, file:line not shown, no DWARF to read; a right accent box, Go TRAP backtrace, demangled fn names and file:line such as main.go:166:9, plus adapter fd_write assert noise on the way out. Solid arrows labeled symbolizer reads connect each core module box down to its matching backtrace outcome. A caption below notes interactive breakpoint stepping across this same boundary, wasmtime run -g/--gdbstub PORT, an LLDB gdbstub, attaches at the native/core level; there is no WIT-aware per-interface source view yet." caption="Figure 9.2: a component carries no debug info of its own; DWARF, when present, lives in exactly one core module, and wasmtime's trap symbolizer reads it from there directly." %}

The component wrapper (the `canon lift`/`canon lower` layer `wasm-tools print` showed above) has nothing to debug in the conventional sense: it has no local variables, no call stack frames of its own, only glue that marshals values across a memory boundary. The vendored `wasi_snapshot_preview1` adapter, the reactor or command shim the README's gotchas describe, is itself a small core module, compiled once by the Bytecode Alliance and vendored by SHA-256; it carries no DWARF either, because it's a fixed, audited binary, not something either component's build step produces fresh. The one place source-level information can exist at all is the core module holding your own compiled language's functions, and whether it's there depends entirely on what the build step chose to embed. The `objdump` check from the previous section is the one fact that determines what a backtrace is capable of showing, before anything has gone wrong yet.

## A trap backtrace, side by side

`host/src/main.rs` calls `get-cargo` with the sentinel id `__TRAP__` last in its scenario, specifically because a trap poisons the component instance in that `Store`, and no further export call will succeed against it afterward. Run with `WASMTIME_BACKTRACE_DETAILS=1` against the Rust provider, the panic surfaces first as the component's own stderr output, then as a wasmtime backtrace on the call itself:

```text
thread '<unnamed>' (1) panicked at src/lib.rs:171:13:
__TRAP__ sentinel: deliberate trap for the debugging/error chapter
[rust] trap: get-cargo("__TRAP__") -> wasmtime call returned Err (a trap): error while executing at wasm backtrace:
    0:   0xdc45 - cargo_rust.wasm!abort
    1:   0xc1a3 - cargo_rust.wasm!std[6755ea078148a6bd]::sys::pal::wasi::abort_internal
    2:   0xb5f1 - cargo_rust.wasm!std[6755ea078148a6bd]::process::abort
    3:   0xbae2 - cargo_rust.wasm!__rustc[3d2f79520d6fa809]::__rust_abort
    4:   0xa953 - cargo_rust.wasm!__rustc[3d2f79520d6fa809]::__rust_start_panic
    5:   0xb979 - cargo_rust.wasm!__rustc[3d2f79520d6fa809]::rust_panic
    6:   0xb034 - cargo_rust.wasm!std[6755ea078148a6bd]::panicking::panic_with_hook
    7:   0xab01 - cargo_rust.wasm!std[6755ea078148a6bd]::panicking::panic_handler::{closure#0}
    8:   0xaa9b - cargo_rust.wasm!std[6755ea078148a6bd]::sys::backtrace::__rust_end_short_backtrace::<...>
    9:   0xbbc5 - cargo_rust.wasm!__rustc[3d2f79520d6fa809]::rust_begin_unwind
   10:  0x1205b - cargo_rust.wasm!core[3aca2c77b46c341]::panicking::panic_fmt
   11:   0x3f78 - cargo_rust.wasm!patterncatalyst:cargo/booking@0.1.0#get-cargo
```

Twelve frames, every one of them demangled and named correctly: wasmtime reads the core module's `name` custom section to produce `cargo_rust.wasm!patterncatalyst:cargo/booking@0.1.0#get-cargo` at frame 11, the exact exported function the sentinel entered. What's missing, consistent with the previous section's `objdump` finding, is a file and a line number next to any frame; the Rust core module carries no DWARF, so wasmtime's symbolizer has nothing to map an address to a source location with. The panic message above the backtrace, `panicked at src/lib.rs:171:13`, does carry a file and a line, but that's Rust's own panic hook formatting its message from the string literal baked into `panic!("__TRAP__ sentinel: ...")`'s call site at compile time, not wasmtime reading DWARF after the fact. Those are two different mechanisms producing two different kinds of location information: the panic message is accurate because the source location is compiled into the string itself, a constant the panicking code carries with it regardless of what runs it, while the backtrace has no equivalent for the frames above it, because nothing in the artifact maps `0x3f78` back to a line of `lib.rs`.

The Go provider's trap, run through the identical host binary against `cargo-go.wasm`, shows the other side of that same difference:

```text
assertion failed at adapter line 2857[go] trap: get-cargo("__TRAP__") -> wasmtime call returned Err (a trap): error while executing at wasm backtrace:
    0:  0xc7de7 - wit-component:adapter:wasi_snapshot_preview1!...::macros::assert_fail
    1:  0xc8600 - wit-component:adapter:wasi_snapshot_preview1!fd_write
    2:  0xc9c13 - wit-component:shim!adapt-wasi_snapshot_preview1-fd_write
    3:   0xa7c5 - runtime.putchar
                    at /home/rsedor/.local/tinygo/src/runtime/runtime_tinygowasm.go:53:11
    4:   0xa6fd - runtime.printnl
                    at /home/rsedor/.local/tinygo/src/runtime/print.go:290:9
    5:   0xf285 - runtime.panicOrGoexit
                    at /home/rsedor/.local/tinygo/src/runtime/panic.go:95:9
    6:   0x3491 - runtime._panic
                    at /home/rsedor/.local/tinygo/src/runtime/panic.go:57:15
    7:  0x2409c - main.init#1$4
                    at .../go/main.go:166:9
                - example.com/cargo-go/internal/cargo/.../booking.wasm.go:45:29
    8:  0x23c43 - <goroutine wrapper>
                    at .../booking.wasm.go:41:1
```

Two things are happening here, and conflating them is the mistake worth avoiding. The first three frames are adapter frames specific to the reactor adapter: TinyGo's panic handler tries to print its panic message through `runtime.putchar`, which routes through the WASI `fd_write` import, which lands in the vendored `wasi_snapshot_preview1.reactor.wasm` adapter's own `fd_write` implementation. That implementation's internal invariant check trips (`assertion failed at adapter line 2857`) when called from inside a panic unwind, because its `fd_write` path assumes normal control flow, not a mid-unwind call. That assertion is what produces the trap, reproducibly, every time this sentinel path runs. Past those three frames, frame 3 onward is the opposite of the Rust case: every frame carries a real file and line number, `runtime_tinygowasm.go:53:11`, `panic.go:95:9`, and critically `main.go:166:9`, the exact line in `go/main.go` where the sentinel's `panic("__TRAP__ sentinel: ...")` call sits. That resolution is possible precisely because the previous section's `objdump` check found `.debug_info` and `.debug_line` already baked into this core module by default. wasmtime's symbolizer reads those sections the same way it reads the `name` section, and when DWARF is present, the result is a full source-level backtrace with no additional configuration required.

The practical rule those two backtraces leave behind: `WASMTIME_BACKTRACE_DETAILS=1` is worth setting on every run of this book's hosts, because it costs nothing and sometimes resolves file:line without further work. Whether it does depends on a build decision made long before the trap, not on anything the host or the flag controls.

## Logging from a component: stderr via inherit_stderr

Both backtraces above were preceded by a line the component itself wrote, not something wasmtime synthesized. `host/src/main.rs` builds its `WasiCtx` with `WasiCtxBuilder::new().inherit_stderr().build()`, which means every byte either component writes to its own WASI stderr stream lands, unmodified, on the host process's real stderr. That's the entire mechanism behind `thread '<unnamed>' (1) panicked at src/lib.rs:171:13:` appearing in the Rust run's output and `assertion failed at adapter line 2857` appearing in the Go run's: in the Rust case, it's the standard library's own panic hook formatting a message and writing it through WASI's `fd_write`; in the Go case, it's TinyGo's runtime doing the equivalent through the adapter. Neither host-side Rust program printed those strings. `cargo-host`'s own `eprintln!` calls are the `[rust]`/`[go]`-prefixed lines surrounding them; the un-prefixed lines are the components' own voice, piped straight through.

This is also, in practice, most of what "logging" means for a component in this book. There is no structured logging framework wired in yet (cluster-level observability is covered later), so a component that wants visibility writes to stdout or stderr the same way any ordinary command-line program would, through whatever its language's standard library already provides, and the host decides whether to surface that stream or swallow it. `inherit_stderr()` is an opt-in the host chooses per `WasiCtxBuilder`; a host that omits it gets a component that runs with no visible output no matter how much it tries to print, because WASI's capability model treats a stream as something a host grants access to, not something a guest can assume. For a host built to run untrusted or sandboxed components, that's a control point, not an oversight: the same ambient-authority argument behind WASI's capability-based design applies here just as directly. A component's ability to write a log line at all is a capability the embedding host hands it, not a default the component can count on.

## Source-level debugging today: what's here, what isn't

Everything in this chapter so far, `wasm-tools`' three subcommands, a wasmtime backtrace, and `inherit_stderr()`, is static inspection or post-mortem output. None of it lets you pause a running component mid-call and step one WIT function at a time through its source, the way an IDE debugger does for a native process. Wasmtime 50's CLI does ship machinery aimed in that direction: `-g`/`--gdbstub <[ADDR:]PORT>` attaches the built-in gdbstub debugger component, listening on a TCP address, and `wasmtime run --help` describes the other side of that connection directly: "A debugger (e.g. LLDB) can then connect via `process connect --plugin=wasm connect://<ADDR>:<PORT>`." Alongside it, `-D coredump=<file>` writes a core dump to disk after a trap, and `-D debugger=<path>` can load an arbitrary debugger component and attach it to the main module, a more general hook the gdbstub is one built-in example of.

What these flags provide, as of this wasmtime release, is a native-level debugging surface. An LLDB session attached through the gdbstub sees wasm instructions, linear memory addresses, and whatever DWARF the active core module happens to carry (the same DWARF `objdump` already showed is present for the Go build and absent for the Rust one), not a WIT-aware view that understands `patterncatalyst:cargo/booking`'s typed function signatures, a component's resource table, or the canonical-ABI marshaling `canon lift` performs on the way in. No interactive LLDB session was run against either provider here; the gap comes directly from the CLI's own `--help` text and the Component Model's current state. Stepping through `get-cargo`'s Rust or Go source, one statement at a time, from inside an IDE attached to a running wasmtime instance, the way a developer debugs a native Rust or Go binary today, is not yet a turnkey workflow for this stack. It exists as native-level primitives a sufficiently motivated setup could build on, not as a documented recipe either toolchain ships out of the box.

That gap is why this chapter's other tools carry more weight than they might in a native-language debugging chapter. A `wasm-tools objdump` check that confirms DWARF is present, a `WASMTIME_BACKTRACE_DETAILS=1` backtrace that resolves file:line when it is, and a component's own stderr piped through `inherit_stderr()` cover the large majority of what this book's examples need to diagnose. Recoverable errors are already visible as `Ok(Err(cargo-error::...))` values the host's own `match` arms print directly, and traps are already visible as the backtraces this chapter walked through twice. The one case that would benefit most from interactive stepping, a bug whose cause isn't obvious from a backtrace's last frame or a stderr line, where you need to watch state change call by call, is also the case these tools can't yet reach past the gdbstub's native-level view.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for the cheapest tool that answers the question you have, in this order: <code>wasm-tools component wit</code> for "what does this export," <code>wasm-tools objdump</code> for "does this artifact even carry DWARF" (check this before a trap, not after; it predicts whether a backtrace will resolve file:line), a wasmtime backtrace with <code>WASMTIME_BACKTRACE_DETAILS=1</code> for "what broke and where," and a component's own stderr via <code>inherit_stderr()</code> for anything a component chose to log on its own. Those four cover every failure this book's Part 2 examples produce, recoverable <code>cargo-error</code> and unrecoverable trap alike, and they require no setup beyond a host that already wires WASI in. Reach for <code>wasmtime run -g/--gdbstub &lt;[ADDR:]PORT&gt;</code> only when a backtrace's last resolvable frame and a stderr line can't localize the bug: it's real and it ships in wasmtime 50, but it attaches at the native/core level with whatever DWARF happens to be embedded, not a WIT-aware, per-interface source view, and setting up an LLDB session against it is a heavier investment than this book's examples have needed so far. If a component's build doesn't embed DWARF in the first place (the default for a <code>cargo-component --release</code> build, confirmed directly by <code>objdump</code> earlier in this chapter), reach for <code>[profile.release] debug = true</code> before reaching for a debugger at all. TinyGo's default already does the equivalent, which is the entire reason the Go trap resolved <code>main.go:166:9</code> and the Rust one didn't.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model's binary structure and canonical ABI the `canon lift` inspection and DWARF-boundary explanation above build directly on.
- Shashank Jain, *WebAssembly for Cloud* (Apress): cross-language component tooling and the operational realities of running polyglot components in production, including the observability gap stderr-only logging leaves at the cluster level.
- [DWARF Debugging Information Format](https://dwarfstd.org/): the debug-info format `wasm-tools objdump` reports on and wasmtime's backtrace symbolizer reads, when a toolchain embeds it.
- [Wasmtime CLI reference: debug options](https://docs.wasmtime.dev/cli-options.html): the authoritative, versioned list behind the `-D debug-info`, `-D coredump`, `-D debugger`, and `-g`/`--gdbstub` flags used above.
- [wasm-tools repository](https://github.com/bytecodealliance/wasm-tools): `component wit`, `print`, and `objdump`'s full option surfaces beyond what these examples exercise.
