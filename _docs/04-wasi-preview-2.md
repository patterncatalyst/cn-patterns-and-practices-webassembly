---
title: "WASI Preview 2"
order: 4
part: "Foundations"
description: "What capabilities WASI Preview 2 grants a component, the host interfaces it defines, and the standard WASI worlds a component can target."
duration: "17 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why WASI exists as a standard set of host interfaces rather than each runtime inventing its own syscall surface, and what "Preview 2" (the 0.2.x line) actually versions.
- Name the core WASI worlds (`wasi-io`, `wasi-cli`, `wasi-clock`, `wasi-filesystem`, `wasi-random`) and the three later-chapter worlds (`wasi-http`, `wasi-sockets`, `wasi-nn`), and say what each grants.
- Trace how a WASI world is expressed in WIT, and how the host decides what a guest can reach before the guest ever runs.
- Distinguish capability-based granting (a host handing a guest a specific, scoped handle) from ambient authority (a process reaching out and asking the OS for whatever it wants), and say why that distinction is the chapter's real subject.
- State, with a date attached, where the Rust and Go toolchains this site uses sit relative to the WASI 0.2 and 0.3 lines.

## Why this matters

Chapter 2 described the sandbox a Wasm module runs inside: no syscalls, no filesystem, no sockets, nothing reachable except linear memory and whatever functions the host explicitly imports into the instance. Chapter 3 gave that import boundary a name and a grammar: WIT, and the interfaces and worlds a component declares to describe what it needs from its environment and what it offers in return. Neither chapter said what a real host actually offers. A component that imports `wasi:filesystem` is declaring intent, not granting itself access; something on the other side of that import has to decide, at instantiation time, whether to satisfy it, with what, and how much. That something is WASI, and Preview 2 is the current, stable version of the interfaces it standardizes.

This matters now because every component this site builds from Chapter 6 forward (the Rust cargo-handling service, its Go counterpart, every runtime that hosts either of them) sits on top of WASI Preview 2 worlds whether the chapter says so explicitly or not. A component that reads a configuration file, logs to stdout, measures elapsed time, or later serves HTTP is exercising a WASI interface, and the host granting that interface is making a security decision on the component's behalf every time it does. Getting this chapter's model right, with capabilities granted narrowly, named explicitly, and never assumed, is what keeps a sandboxed component sandboxed once it starts doing anything useful at all.

{% include excalidraw.html file="04-capability-grant" alt="Diagram of the capability-grant model: a host process on the left holding a set of resource handles (a clock, a filesystem directory, a socket); an arrow from the host to a Wasm guest instance on the right, handing over only two of the three handles explicitly, each handle labeled with the specific resource it points to; a crossed-out dashed arrow from the guest directly to the OS kernel below, labeled 'no ambient syscalls, no direct path'; a small notation reading 'the guest cannot ask for what the host did not hand it'." caption="Figure 4.1 — WASI capabilities are granted, not requested: the host decides what a guest holds before the guest ever runs." %}

## Capabilities

Every general-purpose operating system built since the 1970s runs on ambient authority. A process doesn't present a ticket to open a file, bind a socket, or read the clock; it asks the kernel directly, and the kernel checks a permission model (user ID, file mode bits, a security module policy) attached to the *process*, not to the specific thing the code at that call site is trying to do. The access control is coarse by construction: a process either has the rights a user grants it, broadly, for the duration it runs, or it doesn't. A library pulled in by `npm install` or `pip install` and compiled into that process inherits exactly the same ambient rights as the rest of the program. If the program can read `~/.ssh/`, so can every dependency linked into it, whether or not the dependency's author ever intended that, and whether or not the application developer who vendored it ever audited for it.

A capability-based model inverts this. Instead of a process asking an ambient authority "can I open this file," a process holds (or doesn't hold) an unforgeable handle, a capability, that already points at one specific resource, and the only operations available are the ones that handle's type supports. There is no path from "I have some code running" to "I can open any file on this machine," because opening a file isn't a privilege attached to the process; it's an operation performed *on* a handle the process would have had to already be holding. A component with no filesystem capability in its import set cannot open a file, not because a policy check denies it, but because there is no function in its instance that would let it try. The denial happens at the level of what's linkable, before the question of permission ever comes up.

This is the model Chapter 2 introduced for the sandbox itself (no syscalls reachable from inside a Wasm instance, under any circumstance) and the model Chapter 3's WIT imports describe the shape of. WASI is where the two meet: it's the standard set of interfaces a host can implement, each one scoped to a narrow kind of resource (a clock, a directory, an outbound TCP stream), that a component imports by name and a host satisfies by handing over a concrete implementation, or declines to satisfy, in which case the component simply can't be instantiated with that world, or instantiates with a stub that errors on every call. Either way, the decision belongs to whatever is holding the component, made once, at the boundary, and nothing inside the sandbox can expand it.

The practical consequence shows up the first time a component depends on code from someone else. A Rust crate or Go module compiled into a component for this site's cargo-handling domain can only reach the capabilities that crate's own WIT imports declare and the host actually grants. There's no equivalent of a `pip` package quietly reading an environment variable it was never told to look for, because reading an environment variable *is* a WASI capability (`wasi:cli/environment`), and a component that never imports it cannot call it, no matter what the code inside tries to do. Capability-based security doesn't make a dependency trustworthy. It makes an untrustworthy dependency's blast radius equal to exactly what it was handed, provably, before it ran.

## The host interface

WASI is not one interface; it's a family of them, each one a self-contained WIT package covering one category of host resource, versioned together under the `wasi:` namespace. "Preview 2" names the generation of this family that stabilized the interfaces in terms of the Component Model (Chapter 3's imports, exports, and resource types) rather than the flat function-table ABI Preview 1 used. The practical difference matters here: Preview 1 exposed something close to a fixed POSIX-shaped syscall table, which made it hard to add new capability categories without breaking the ABI for everyone. Preview 2 expresses each capability as its own WIT interface (a `clock` interface with its own resource types and functions, a `filesystem` interface with its own, and so on), so new capability families can be added, and existing ones can evolve, without touching unrelated ones.

A handful of interfaces form the base nearly every component needs regardless of domain:

- **`wasi:io`** — the foundational streams and polling primitives (`input-stream`, `output-stream`, a `pollable` resource) that almost every other WASI interface builds on top of. A component rarely imports `wasi:io` directly by name in application code, but it's the plumbing underneath `wasi:cli`'s stdio and `wasi:filesystem`'s file handles alike.
- **`wasi:cli`** — the command-line environment: standard input, output, and error streams, process exit codes, environment variables, and command-line arguments. A component built to run as a CLI-shaped workload (this site's early examples, before Chapter 11 moves to HTTP) targets the `wasi:cli/command` world, which bundles exactly these interfaces into one named contract.
- **`wasi:clocks`** — wall-clock time and monotonic time, each as its own resource rather than one ambiguous `time()` call, because a component measuring elapsed duration and a component reading the current date have different correctness requirements (monotonic time never goes backward even if the wall clock is adjusted; wall-clock time can).
- **`wasi:filesystem`** — directory and file handles, scoped from the start: a host grants a component a *preopened directory* (a specific subtree), not access to a root filesystem with path traversal left to the component's good behavior. A component cannot open `/etc/passwd` by constructing that path string unless the host explicitly preopened a directory containing it, because path resolution inside a WASI filesystem capability is confined to the directory handle it started from.
- **`wasi:random`** — a source of cryptographically secure random bytes and an insecure-but-fast pseudorandom source, kept as two separate interfaces so a component (and anyone reviewing its imports) can tell at a glance whether it's generating session tokens or just jittering a retry delay.

Three more interfaces exist in the WASI Preview 2 family and matter enormously to this site, but each one gets a dedicated later chapter rather than a paragraph here, because each one is a bigger surface than a Foundations chapter can responsibly cover:

- **`wasi:http`** — incoming and outgoing HTTP requests and responses as native WIT types, which is what lets a component serve or make HTTP calls without linking a socket library and reimplementing HTTP framing inside the sandbox. Chapter 11 builds this site's first HTTP-serving component directly against this interface.
- **`wasi:sockets`** — raw TCP and UDP, instance-level network permission scoped per address family and per outbound/inbound direction, with the host deciding at instantiation time which addresses a component may even attempt to reach. Chapter 13 covers this interface in the context of reconnect and resilience.
- **`wasi:nn`** — a portable interface for loading a model and running inference from inside a component, independent of which inference backend (ONNX Runtime, OpenVINO, a vendor-specific accelerator) the host actually wires up underneath it. Chapter 27 is a full chapter on it.

Each of these interfaces, base or deferred, follows the same shape: a WIT package defining resource types and the operations valid on them, implemented by whatever host is running the component (wasmtime, wasmCloud, or any other Preview-2-compliant runtime), and granted to a specific component instance as part of assembling the *world* that component runs against.

{% include excalidraw.html file="04-wasi-world-map" alt="Map of WASI Preview 2 interfaces split into two bands: a Foundations band covered in this chapter holding wasi:io, wasi:cli, wasi:clocks, wasi:filesystem, and wasi:random; a later-chapters band holding wasi:http (Chapter 11), wasi:sockets (Chapter 13), and wasi:nn (Chapter 27); dashed arrows from a subset of both bands down into a box labeled 'this component's WIT world,' showing that a world imports only the interfaces it names, not the whole family." caption="Figure 4.2 — The WASI Preview 2 family: a component's world imports a chosen subset, never the whole family." %}

## The WASI worlds

A WIT world, as Chapter 3 described it, is a named bundle of imports and exports: the full contract a component is built against, not a single interface in isolation. WASI defines a handful of standard worlds precisely so a component author and a host don't have to independently enumerate which exact combination of `wasi:io`, `wasi:cli`, `wasi:clocks`, `wasi:filesystem`, and `wasi:random` a "plain command-line program" needs; the `wasi:cli/command` world already names that bundle. A component targets `wasi:cli/command` the same way a traditional program links against libc: by declaring the world in its own WIT definition and letting the toolchain (`cargo component` for Rust, `wasm-tools` paired with `wit-bindgen-go` for Go) wire the imports through.

This is also where the chapter's two foundational ideas meet directly. A WIT world is a *declaration*: text, checked at build time, naming exactly which interfaces a component imports and exports. WASI capability-granting is what happens at *instantiation* time, when a host reads that declaration and decides what concrete implementation, if any, to hand over for each imported interface. The world says "this component needs a preopened directory and a monotonic clock." The host is the only thing that decides which directory, scoped how, and whether to honor the request at all. A component recompiled against a bigger world (say, adding `wasi:sockets` to a component that previously only used `wasi:cli/command`) gains nothing by itself; the new capability only becomes real the moment some host configuration grants it one. This is the opposite of how a traditional binary works, where recompiling with a new `#include` and calling `socket()` is sufficient on its own, because the ambient authority was already there waiting.

That gap between "the world declares it" and "the host grants it" is the whole value of the model for this site's deployment chapters. Part 5 walks through wasmtime and wasmCloud configuration that decides, per component, per environment, exactly which WASI worlds get backed by a real implementation and which don't. A component shipped to a cluster with no `wasi:filesystem` capability wired up simply cannot read a file, in production, regardless of what the component's own code attempts, because nothing on the host side satisfied that import. Chapter 14 and Chapter 15 show this configuration concretely for wasmtime and wasmCloud respectively; this chapter's job is only to establish that the decision point exists, where it sits, and why it's drawn at the world boundary rather than left to runtime policy checks sprinkled through host code.

The following is illustrative only: a world sketch to show the shape of the declaration, not a world this site's own gated, dependency-free cargo package ships:

```wit
// ILLUSTRATIVE — not part of this site's cargo-handling component.
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

Reading this world is reading a capability manifest before a single line of the component's own logic runs: this hypothetical component can write to its own stdio streams, read its process environment, check wall-clock time, and make outbound HTTP calls, and nothing else. No filesystem import appears, so no version of this component, however it's compiled, can open a file. No sockets import appears, so it cannot open a raw TCP connection; `wasi:http` covers its only networking path, and only outbound. A reviewer auditing this component for what it could possibly do with a compromised dependency doesn't need to read the Rust or Go source at all; the WIT world already answers the question, which is a degree of static auditability ambient-authority platforms don't offer at this granularity.

## The 0.2 and 0.3 lines

WASI's versioning deserves a precise answer rather than a vague one, because "Preview 2" sounds provisional and "the current stable interfaces" is a stronger, truer claim. As of 2026-10-20, the WASI 0.2.x line is at patch release 0.2.12, dated 2026-06-02, and it remains the stable, production-targeted generation of these interfaces; the worlds and interfaces described above are all 0.2.x. A newer line, 0.3 (sometimes called "Preview 3" informally, though the project has moved away from that naming pattern), exists and is further along than a research branch: 0.3.2 shipped 2026-10-13. Its headline feature is native async support built into the interfaces themselves, replacing the polling-based concurrency model 0.2 relies on (the `pollable` resource in `wasi:io` mentioned above).

Neither this site's Rust toolchain (`cargo component` targeting the Component Model) nor its Go toolchain (`wasm-tools` paired with `wit-bindgen-go`) targets 0.3 as of this writing in October 2026. Both target 0.2. That's not a gap in this site's tooling choices so much as a statement about where the broader ecosystem's compiler and runtime support currently sits. 0.3's async model is a larger change to the interfaces than a patch bump, and toolchain support for it is still landing incrementally across the Component Model ecosystem. Every WASI world and interface this chapter names, and every one later chapters build against, is a 0.2.x interface. Where that changes for this site, it will be a stated version bump in its own right, not a silent assumption carried forward from this chapter.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>This site's components target the <strong>minimum WASI 0.2.x world</strong> their actual behavior requires, never a broader one assembled for convenience. A component that only computes and returns a value imports nothing beyond what <code>wasi:cli/command</code> already bundles for argument and stdio access; a component that calls another service imports <code>wasi:http</code>'s outgoing-handler and nothing from <code>wasi:filesystem</code> or <code>wasi:sockets</code> unless it actually opens a file or a raw socket. Granting a capability a component doesn't use isn't a neutral default: it's an unused attack surface sitting in the host configuration, available to any future code change (or any compromised dependency) that decides to exercise it, with no world-level boundary left to catch the attempt. Every component built from Chapter 6 forward states its WASI world explicitly in its own WIT package, and every runtime chapter (14, 15, 17) shows the host-side configuration that backs that world with real capabilities, so a reader can always answer "what can this component actually touch" by reading one file, not by tracing every `wasi:*` call through the implementation.</p></div>

## For deeper coverage

- Chiarlone, R., *WebAssembly on the Server* (Manning) — the WASI chapter covers Preview 1 to Preview 2's interface redesign in more implementation depth than this chapter's model-level treatment.
- Jain, K., *Practical WebAssembly* (Apress) — worked examples instantiating WASI Preview 2 worlds across multiple host runtimes.
- [WASI documentation](https://wasi.dev) — the authoritative, versioned reference for every interface and world named in this chapter.
- [WASI Preview 2 proposal and repository](https://github.com/WebAssembly/WASI/blob/main/preview2/README.md) — the source-of-truth WIT definitions for `wasi:io`, `wasi:cli`, `wasi:clocks`, `wasi:filesystem`, `wasi:random`, `wasi:http`, `wasi:sockets`, and `wasi:nn`.
