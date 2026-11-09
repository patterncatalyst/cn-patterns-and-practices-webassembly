---
title: "Debugging WebAssembly"
order: 9
part: "Building Components in Rust & Go"
description: "Inspect a component without running it, read a wasmtime trap backtrace from the Rust and Go providers, and see how far source-level debugging reaches today."
duration: "20 min read"
---

## Learning objectives

By the end of this chapter you can:

- Read a component's world from the compiled binary with `wasm-tools component wit`, without running it.
- Use `wasm-tools print` and `wasm-tools objdump` to see the `canon lift` glue and the core module sections, including whether DWARF is present.
- Tell a recoverable `cargo-error` from a trap in a wasmtime backtrace, for the Rust and Go providers, and explain why one backtrace resolves file and line and the other doesn't.
- Read what a component wrote to its own stderr through the host's `inherit_stderr()`.
- State what breakpoint debugging of a component looks like today, and when it's worth reaching for.

## Why this matters

When a component fails, the first question is which tool answers the question cheaply. The host in `examples/part2-building-components/host/src/main.rs` ends with a `__TRAP__` sentinel that makes `get-cargo` panic. It runs last because a trap poisons the wasmtime `Store`. Both providers implement the sentinel in lockstep, so one failure can be read through six tools, each answering a question the others can't.

Static inspection is mature: `wasm-tools` reads a binary's embedded types and prints them back. Runtime backtraces are mature: wasmtime demangles function names on every trap and resolves file and line when the core module carries DWARF. What isn't mature, as of wasmtime 50 and TinyGo 0.43, is an IDE-integrated, WIT-aware breakpoint workflow across the component boundary.

{% include excalidraw.html file="09-symptom-to-tool" alt="Six rows, each a symptom box on the left, the cheapest tool that taps it in the middle, and a caveat box on the right. Row 1: need the shape before running it: wasm-tools component wit file.wasm prints the world and interfaces embedded in the binary. Row 2: need to see the ABI glue (canon lift/canon lower): wasm-tools print file.wasm WAT produces tens of thousands of lines, so grep for the export name. Row 3: is DWARF even present: wasm-tools objdump file.wasm shows per-section sizes, so look for debug_info under each module. Row 4: component trapped at runtime: wasmtime run or host plus WASMTIME_BACKTRACE_DETAILS=1 gives one frame per call, with file:line only if that module has DWARF. Row 5: need what the component wrote on its way down: WasiCtxBuilder inherit_stderr sends panic and log lines to the host process's own stderr. Row 6: need to pause and step through source: wasmtime run -g/--gdbstub PORT, an LLDB gdbstub, works at the native/core level only, with no WIT-aware source view yet. A caption below notes all six run against the same Part 2 artifacts with no rebuild or instrumentation required." caption="Figure 9.1: Six symptoms, the cheapest tool for each, and the caveat to know before trusting the answer." %}

## Inspecting a component without running it

`wasm-tools component wit` reads the type section embedded in the binary rather than any `.wit` file on disk, so it needs no host and no fixtures:

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

Both components export the same `patterncatalyst:cargo` interfaces at `0.1.0`, which is what composing them with `wac plug` depends on. The full output also exposes a WASI minor-version skew: the Rust component imports `wasi:cli@0.2.3` and the Go component `wasi:cli@0.2.12`. The command doesn't resolve the skew (wasmtime's semver-compatible linking does at instantiation). It confirms the skew exists before you assume two components import identical WASI.

`wasm-tools print` prints the full WAT, canonical ABI glue included. For `cargo_rust.wasm`, a 150 KB binary, that is 40,400 lines, mostly the same twelve WASI interfaces every component imports. Grep it, don't read it. Searching for `get-cargo` finds the line that turns a core function into the typed WIT function:

```wat
(alias core export 3 "patterncatalyst:cargo/booking@0.1.0#get-cargo" (core func (;54;)))
(alias core export 3 "cabi_post_patterncatalyst:cargo/booking@0.1.0#get-cargo" (core func (;55;)))
(func (;19;) (type 36) (canon lift (core func 54) (memory 0) (realloc 23) string-encoding=utf8 (post-return 55)))
```

`canon lift` wraps `core func 54`, an ordinary numbered function in the one core module the build produced. It declares the memory and string encoding needed to marshal arguments and the result, and names a `post-return` function for cleanup. WIT records, variants and resources are erased by the time execution reaches that function, and that is where a debugger has to attach. The file ends with a `@producers` section, `(processed-by "wit-component" "0.227.1") (processed-by "cargo-component" "0.21.1") (language "Rust" "")`, which records the toolchain versions that produced the artifact on disk.

`wasm-tools objdump` lists sections and sizes. The Rust core module has no `.debug_*` sections, only `types`, `imports`, `functions`, `code`, `data` and the `name` custom section. The Go core module looks different:

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

TinyGo's `-target=wasip1` embeds a full DWARF set by default: nearly 600 KB, more than two thirds of the 812 KB Go core module. `cargo-component build --release` embeds none, because the crate sets no `[profile.release] debug = true`. That is a build default, not a toolchain limit, and it is the check that predicts whether a backtrace resolves file and line before anything traps.

## Where debug info lives

A component wraps one or more core modules, and DWARF, when it exists, lives inside exactly one of them, never at the component layer.

{% include excalidraw.html file="09-component-debug-layers" alt="Three bands top to bottom. Component boundary band: a single ink box reading patterncatalyst:cargo component, canon lift / canon lower glue, no debug info of its own, with dashed arrows down to two core modules. Core modules band: a left box, Core module 0, Rust cargo-component --release, custom name section only, no debug_info or debug_line (no profile.release.debug=true); a right box, Core module 0, Go TinyGo -target=wasip1, custom name plus full DWARF, debug_info/debug_line/debug_str embedded by default; and a dashed ghost box below spanning both, the wasi_snapshot_preview1 adapter vendored wasm, named functions only, no DWARF either side. Backtrace band: a left accent box, Rust TRAP backtrace, demangled crate/fn names 12 frames ending at booking#get-cargo, file:line not shown, no DWARF to read; a right accent box, Go TRAP backtrace, demangled fn names and file:line such as main.go:166:9, plus adapter fd_write assert noise on the way out. Solid arrows labeled symbolizer reads connect each core module box down to its matching backtrace outcome. A caption below notes interactive breakpoint stepping across this same boundary, wasmtime run -g/--gdbstub PORT, an LLDB gdbstub, attaches at the native/core level; there is no WIT-aware per-interface source view yet." caption="Figure 9.2: A component carries no debug info of its own. DWARF, when present, lives in one core module, and wasmtime reads it from there." %}

The component wrapper has no locals and no frames of its own, only glue that marshals values across a memory boundary. The vendored `wasi_snapshot_preview1` adapter is a fixed, audited core module and carries no DWARF either. Source-level information can exist only in the core module holding your own compiled functions, and only if the build embedded it. The `objdump` result fixes what a backtrace can show.

## A trap backtrace, side by side

Run with `WASMTIME_BACKTRACE_DETAILS=1` against the Rust provider, the panic appears first as the component's own stderr output, then as a backtrace on the call:

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

All twelve frames are demangled, because wasmtime reads the `name` custom section. Frame 11, `patterncatalyst:cargo/booking@0.1.0#get-cargo`, is the exported function the sentinel entered. No frame has a file or line, since the Rust core module has no DWARF. The `panicked at src/lib.rs:171:13` line does have one, but it comes from Rust's panic hook formatting a location compiled into the `panic!` call site, not from wasmtime reading DWARF. Two mechanisms, two kinds of location.

The Go provider, through the same host binary, shows the other side:

```text
assertion failed at adapter line 2857[go] trap: get-cargo("__TRAP__") -> wasmtime call returned Err (a trap): error while executing at wasm backtrace:
    0:  0xc7de7 - wit-component:adapter:wasi_snapshot_preview1!...::macros::assert_fail
    1:  0xc8600 - wit-component:adapter:wasi_snapshot_preview1!fd_write
    2:  0xc9c13 - wit-component:shim!adapt-wasi_snapshot_preview1-fd_write
    3:   0xa7c5 - runtime.putchar
                    at ~/.local/tinygo/src/runtime/runtime_tinygowasm.go:53:11
    4:   0xa6fd - runtime.printnl
                    at ~/.local/tinygo/src/runtime/print.go:290:9
    5:   0xf285 - runtime.panicOrGoexit
                    at ~/.local/tinygo/src/runtime/panic.go:95:9
    6:   0x3491 - runtime._panic
                    at ~/.local/tinygo/src/runtime/panic.go:57:15
    7:  0x2409c - main.init#1$4
                    at .../go/main.go:166:9
                - example.com/cargo-go/internal/cargo/.../booking.wasm.go:45:29
    8:  0x23c43 - <goroutine wrapper>
                    at .../booking.wasm.go:41:1
```

The first three frames belong to the reactor adapter. TinyGo's panic handler prints its message through `runtime.putchar` to the WASI `fd_write` import, which lands in the adapter's own `fd_write`. That implementation's invariant check trips (`assertion failed at adapter line 2857`) because it assumes normal control flow, not a call from inside a panic unwind, and the assertion produces the trap every time. From frame 3 on, every frame has a file and line, including `main.go:166:9`, the line of the sentinel `panic`. That works because `.debug_info` and `.debug_line` are already in the core module.

Set `WASMTIME_BACKTRACE_DETAILS=1` on every run: it costs nothing and sometimes resolves file and line. Whether it does was decided at build time.

## Logging from a component

Both backtraces were preceded by a line the component wrote. The host builds its `WasiCtx` with `WasiCtxBuilder::new().inherit_stderr().build()`, so every byte a component writes to its WASI stderr lands unmodified on the host's stderr. The `thread '<unnamed>' (1) panicked` line is Rust's panic hook writing through `fd_write`; the `assertion failed` line is TinyGo's runtime doing the same through the adapter. The `[rust]` and `[go]` prefixed lines are the host's own `eprintln!`.

That is most of what logging means for a component here: write to stdout or stderr like any command-line program, and let the host decide whether to surface the stream. A host that omits `inherit_stderr()` gets a component with no visible output however much it prints. WASI treats a stream as a capability the host grants, so the ability to write a log line at all is something the embedder hands the component.

## Source-level debugging today

Everything above is static inspection or post-mortem output. None of it pauses a running component and steps through source. Wasmtime 50's CLI has machinery aimed that way:

| Flag | What it does |
| --- | --- |
| `-g` / `--gdbstub <[ADDR:]PORT>` | Attaches the built-in gdbstub debugger component on a TCP address; a debugger such as LLDB connects with `process connect --plugin=wasm connect://<ADDR>:<PORT>` |
| `-D coredump=<file>` | Writes a core dump to disk after a trap |
| `-D debugger=<path>` | Loads an arbitrary debugger component and attaches it to the main module |

This is a native-level surface. An LLDB session through the gdbstub sees wasm instructions, linear memory addresses and whatever DWARF the active core module carries (present for Go, absent for Rust by default). It has no WIT-aware view of `patterncatalyst:cargo/booking` signatures, resource tables or the marshaling `canon lift` performs. No interactive LLDB session was run against either provider; the gap comes from the CLI's own `--help` text and the Component Model's current state. Stepping through `get-cargo` one statement at a time from an IDE is not yet a turnkey workflow for this stack.

So the other tools carry more weight than in a native debugging workflow. An `objdump` check for DWARF, a backtrace that resolves file and line when it's there, and stderr through `inherit_stderr()` cover the failures these examples produce. Recoverable errors are `Ok(Err(cargo-error::...))` values the host prints from its `match` arms, and traps are the backtraces above. The case that would benefit most from stepping, a bug that a backtrace's last frame doesn't explain, is the one these tools can't reach past the gdbstub.

> **Decision**
>
> Reach for the cheapest tool that answers the question, in this order: `wasm-tools component wit` for what a binary exports, `wasm-tools objdump` for whether it carries DWARF (check before a trap, not after), a backtrace with `WASMTIME_BACKTRACE_DETAILS=1` for what broke and where, and the component's stderr through `inherit_stderr()` for anything it logged. Use `wasmtime run -g` only when the last resolvable frame and a stderr line can't localize the bug; it attaches at the native level, not per WIT interface. If a `cargo-component --release` build has no DWARF, set `[profile.release] debug = true` before reaching for a debugger. TinyGo's default already embeds it, which is why the Go trap resolved `main.go:166:9` and the Rust one didn't.

> **🤖 Explore with your agent**
>
> "In examples/part2-building-components, set `[profile.release] debug = true` in rust/Cargo.toml, rebuild the Rust provider with `cargo component build --release`, and run `wasm-tools objdump` on cargo_rust.wasm to confirm `.debug_info` is now present. Then run the host with `WASMTIME_BACKTRACE_DETAILS=1` against it and report whether the `get-cargo` trap frames now show file and line, comparing against the Go provider's `main.go:166:9`."
>
> Check: `wasm-tools objdump rust/target/wasm32-wasip1/release/cargo_rust.wasm | grep debug_info` prints a line, and the host's `[rust] trap:` backtrace gains `at ...lib.rs:` lines.

## Build, run, observe

```bash
cd examples/part2-building-components && ./verify.sh
wasm-tools component wit rust/target/wasm32-wasip1/release/cargo_rust.wasm
wasm-tools objdump go/cargo-go.wasm | grep debug_
```

The script builds both providers and the host and runs the host against each. The host's trap call comes last and prints the backtrace to stderr. Set `WASMTIME_BACKTRACE_DETAILS=1` when running the host directly to see frames with file and line where DWARF exists.

- Run `wasm-tools objdump` on the Rust and Go artifacts: only the Go module lists `.debug_*` sections.
- Omit `inherit_stderr()` in `host/src/main.rs`: the panic and assertion lines no longer appear.
- Set `[profile.release] debug = true` for the Rust provider: its backtrace frames can then resolve to source locations.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model's binary structure and the canonical ABI behind the `canon lift` inspection and the DWARF boundary above.
- Shashank Jain, *WebAssembly for Cloud* (Apress): cross-language component tooling and the observability gap that stderr-only logging leaves at the cluster level.
- [DWARF Debugging Information Format](https://dwarfstd.org/): the debug-info format `wasm-tools objdump` reports and wasmtime's symbolizer reads.
- [Wasmtime CLI reference: debug options](https://docs.wasmtime.dev/cli-options.html): the versioned list behind `-D debug-info`, `-D coredump`, `-D debugger` and `-g`/`--gdbstub`.
- [wasm-tools repository](https://github.com/bytecodealliance/wasm-tools): the full option surfaces of `component wit`, `print` and `objdump`.
