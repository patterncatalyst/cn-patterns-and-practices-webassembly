---
title: "WASI Preview 2"
order: 4
part: "Foundations"
description: "What capabilities WASI Preview 2 grants a component, the host interfaces it defines, and the standard WASI worlds a component can target."
duration: "17 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why WASI exists as a standard set of host interfaces rather than each runtime inventing its own syscall surface, and what "Preview 2" (the 0.2.x line) versions.
- Name the core WASI interfaces (`wasi:io`, `wasi:cli`, `wasi:clocks`, `wasi:filesystem`, `wasi:random`) and the three later ones (`wasi:http`, `wasi:sockets`, `wasi:nn`), and say what each grants.
- Trace how a WASI world is expressed in WIT, and how the host decides what a guest can reach before the guest ever runs.
- Distinguish capability-based granting (a host handing a guest a specific, scoped handle) from ambient authority (a process asking the OS for whatever it wants).
- State, with a date attached, where the Rust and Go toolchains used here sit relative to the WASI 0.2 and 0.3 lines.

## Why this matters

A Wasm instance has no syscalls, no filesystem and no sockets, only linear memory and the functions the host imports. The Component Model gave that import boundary a grammar in WIT, but a grammar doesn't say what a real host offers. A component that imports `wasi:filesystem` declares intent and grants itself nothing. The host decides at instantiation whether to satisfy the import, with what, and how much. WASI is the standard set of interfaces the host implements, and Preview 2 is its current stable generation.

Every component in the series sits on WASI 0.2 worlds, stated or not. Reading a config file, logging to stdout, timing a call or serving HTTP all exercise a WASI interface, and the host granting it is making a security decision on the component's behalf.

{% include excalidraw.html file="04-capability-grant" alt="Diagram of the capability-grant model: a host process on the left holding a set of resource handles (a clock, a filesystem directory, a socket); an arrow from the host to a Wasm guest instance on the right, handing over only two of the three handles explicitly, each handle labeled with the specific resource it points to; a crossed-out dashed arrow from the guest directly to the OS kernel below, labeled 'no ambient syscalls, no direct path'; a small notation reading 'the guest cannot ask for what the host did not hand it'." caption="Figure 4.1: WASI capabilities are granted, not requested. The host decides what a guest holds before the guest runs." %}

## Capabilities

General-purpose operating systems run on ambient authority. A process doesn't present a ticket to open a file, bind a socket or read the clock. It asks the kernel, which checks permissions attached to the process (user ID, mode bits, a security module policy), not to the call site. A library compiled into that process inherits all of it. If the program can read `~/.ssh/`, so can every dependency linked into it, whether or not its author intended that or the application developer audited for it.

A capability model inverts this. A process holds, or doesn't hold, an unforgeable handle that already points at one resource, and the handle's type fixes the operations available. There is no path from "some code is running" to "I can open any file on this machine", because opening a file is an operation on a handle the process must already hold. A component with no filesystem capability in its imports can't open a file, and no policy check is needed to deny it, because no function exists in the instance for it to try. Denial happens at the level of what can be linked, before permission ever comes up.

WASI is where the sandbox and WIT imports meet. Each interface is scoped to one narrow kind of resource, such as a clock, a directory or an outbound TCP stream. A component imports it by name, and the host satisfies it with a concrete implementation or declines. If it declines, the component can't be instantiated with that world, or instantiates with a stub that errors on every call. The decision belongs to whatever holds the component, is made once at the boundary, and nothing inside the sandbox can widen it.

The consequence shows up with the first third-party dependency. A crate or module compiled into a component reaches only what the component's WIT imports declare and the host grants. A dependency can't quietly read an environment variable, because reading one is the capability `wasi:cli/environment`, and a component that never imports it can't call it. Capability security doesn't make a dependency trustworthy. It makes an untrustworthy dependency's blast radius exactly what it was handed, before it runs.

## The host interface

WASI is a family of self-contained WIT packages under the `wasi:` namespace, each covering one category of host resource and versioned together. Preview 2 expresses them with the Component Model's imports, exports and resource types. Preview 1 exposed a near-POSIX flat function table, which made new capability categories hard to add without breaking the ABI for everyone. In Preview 2 each capability is its own interface, so families can be added and can evolve independently.

| Interface | Grants | Notes |
|-----------|--------|-------|
| `wasi:io` | Streams and polling (`input-stream`, `output-stream`, `pollable`) | The plumbing under `wasi:cli` stdio and `wasi:filesystem` handles. Application code rarely imports it by name |
| `wasi:cli` | stdin, stdout, stderr, exit codes, environment variables, arguments | The `wasi:cli/command` world bundles these for a CLI-shaped workload |
| `wasi:clocks` | Wall-clock and monotonic time, as separate resources | Monotonic time never goes backward when the wall clock is adjusted; elapsed-time and calendar code have different needs |
| `wasi:filesystem` | Directory and file handles, scoped to a preopened directory | A component can't open `/etc/passwd` by building the path unless the host preopened a directory containing it, because resolution is confined to the handle it started from |
| `wasi:random` | Secure random bytes and a fast insecure source, as two interfaces | A reviewer can tell from the imports whether a component generates session tokens or jitters a retry delay |
| `wasi:http` | Incoming and outgoing HTTP requests and responses as WIT types | A component serves or makes HTTP calls without a socket library or its own HTTP framing |
| `wasi:sockets` | Raw TCP and UDP, scoped per address family and direction | The host decides at instantiation which addresses a component may attempt to reach |
| `wasi:nn` | Load a model and run inference, independent of backend | ONNX Runtime, OpenVINO or a vendor accelerator sits behind the host |

`wasi:http`, `wasi:sockets` and `wasi:nn` are large enough to get their own chapters later in the series. All eight follow one shape: a WIT package of resource types and operations, implemented by the host (Wasmtime, wasmCloud or any Preview 2 runtime) and granted to a specific instance as part of the world it runs against.

{% include excalidraw.html file="04-wasi-world-map" alt="Map of WASI Preview 2 interfaces split into two bands: a Foundations band covered in this section holding wasi:io, wasi:cli, wasi:clocks, wasi:filesystem, and wasi:random; a later band holding wasi:http, wasi:sockets, and wasi:nn; dashed arrows from a subset of both bands down into a box labeled 'the component's WIT world,' showing that a world imports only the interfaces it names, not the whole family." caption="Figure 4.2: The WASI Preview 2 family. A component's world imports a chosen subset, never the whole family." %}

## The WASI worlds

A world is a named bundle of imports and exports, the full contract a component is built against. WASI defines standard worlds so that author and host don't each enumerate which combination of `wasi:io`, `wasi:cli`, `wasi:clocks`, `wasi:filesystem` and `wasi:random` a plain command-line program needs. `wasi:cli/command` is that bundle. A component targets it the way a program links libc: it declares the world in its WIT and lets the toolchain (`cargo component` for Rust, `wasm-tools` with `wit-bindgen-go` for Go) wire the imports.

A world is a declaration, text checked at build time. Granting is what happens at instantiation, when the host reads the declaration and decides what to hand over for each import. The world says "this component needs a preopened directory and a monotonic clock". Only the host decides which directory, scoped how, and whether to honor the request. Recompiling against a bigger world, say adding `wasi:sockets` to a `wasi:cli/command` component, gains nothing until host configuration grants it. A traditional binary differs: adding an `#include` and calling `socket()` is sufficient, because the ambient authority was already there.

That gap between declaring and granting is the point of the model for deployment. Wasmtime and wasmCloud configuration decides, per component and per environment, which worlds are backed by a real implementation. A component on a cluster with no `wasi:filesystem` wired up can't read a file in production, whatever its code attempts. The decision is drawn at the world boundary and not left to policy checks scattered through host code.

An illustrative world, not one the cargo package ships, shows the shape:

```wit
// ILLUSTRATIVE: not part of the cargo-handling component.
// Shows how a world composes several wasi: interfaces into one named contract.
package example:sketch;

world cargo-gateway {
    import wasi:io/streams@0.2.x;
    import wasi:cli/environment@0.2.x;
    import wasi:clocks/wall-clock@0.2.x;
    import wasi:http/outgoing-handler@0.2.x;

    export handle-request: func(req: wasi:http/types.incoming-request) -> wasi:http/types.outgoing-response;
}
```

Reading it is reading a capability manifest. This component can write to its stdio streams, read its environment, check wall-clock time and make outbound HTTP calls. It has no filesystem import, so no build of it can open a file. It has no sockets import, so it can't open a raw TCP connection, and `wasi:http` is its only network path, outbound only. A reviewer asking what a compromised dependency could do answers from the WIT world without reading the Rust or Go source, a degree of static auditability ambient-authority platforms don't offer at this granularity.

## The 0.2 and 0.3 lines

As of 2026-10-20 the WASI 0.2.x line is at 0.2.12, released 2026-06-02, and remains the stable, production-targeted generation. Every interface above is 0.2.x. The 0.3 line (informally "Preview 3", though the project has moved away from that naming) is past research: 0.3.2 shipped 2026-10-13. Its headline feature is native async built into the interfaces, replacing the polling model 0.2 relies on (the `pollable` resource in `wasi:io`).

| | 0.2.x | 0.3.x |
|---|-------|-------|
| Latest as of 2026-10-20 | 0.2.12 (2026-06-02) | 0.3.2 (2026-10-13) |
| Concurrency | Polling with `pollable` | Async in the interfaces |
| Rust (`cargo component`) and Go (`wasm-tools` with `wit-bindgen-go`) toolchains here | Target it | Do not target it |

Toolchain support for 0.3 is landing incrementally, and its async model is a larger change than a patch bump. Moving to it is a stated version change, not an assumption carried forward.

> **Decision**
>
> Target the minimum WASI 0.2.x world a component's behavior requires, never a broader one assembled for convenience. A component that only computes and returns a value imports nothing beyond what `wasi:cli/command` bundles for arguments and stdio. A component that calls another service imports the outgoing handler of `wasi:http`, and nothing from `wasi:filesystem` or `wasi:sockets` unless it opens a file or a raw socket. A capability the component doesn't use is attack surface in the host configuration, open to any later code change or compromised dependency, with no world-level boundary left to catch the attempt. State the world explicitly in the component's own WIT package, so "what can this component touch" is answered by reading one file.

> **🤖 Explore with your agent**
>
> "Review the cargo consumer components in `examples/part2-building-components/consumer-rust` and `consumer-go`. List every `wasi:` interface each one imports, using `wasm-tools component wit` on the built `.wasm`, and apply the rule of the minimum WASI 0.2.x world: name any import the component's behavior does not need and say what the host would no longer have to grant."
>
> Check: the reply lists imports taken from the `wasm-tools component wit` output for each consumer, and every interface it proposes to drop is one the component's `main` never exercises.

## Build, run, observe

The composed consumer components in the components example are WASI command components. Build and run them with:

```bash
cd examples/part2-building-components
./verify.sh
```

The script builds the Rust and Go providers and consumers, composes all four consumer and provider pairs with `wac plug`, and runs each with `wasmtime run`. A passing run means each composed CLI ran under `wasmtime run` with no host-specific functions. The Rust provider imports WASI `0.2.3` and the Go components import `0.2.12`; `wac plug` leaves both as imports and Wasmtime satisfies any `0.2.x` import through semver-compatible linking, so no version shim is needed. To inspect what a component declares it needs, run `wasm-tools component wit` on any built `.wasm` and read its `import` lines against the world it was built for.

Experiments:

- Compare a provider's `wasm-tools component wit` output with a consumer's. The provider lists `export` lines for the cargo interfaces and the consumer lists matching `import` lines, with `wasi:cli/run` exported.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the WASI chapter covers Preview 1 to Preview 2's interface redesign in more implementation depth.
- Shashank Jain, *WebAssembly for Cloud* (Apress): worked examples instantiating WASI Preview 2 worlds across multiple host runtimes.
- [WASI documentation](https://wasi.dev): the authoritative, versioned reference for every interface and world named above.
- [WASI Preview 2 proposal and repository](https://github.com/WebAssembly/WASI/blob/main/preview2/README.md): the source-of-truth WIT definitions for `wasi:io`, `wasi:cli`, `wasi:clocks`, `wasi:filesystem`, `wasi:random`, `wasi:http`, `wasi:sockets`, and `wasi:nn`.
