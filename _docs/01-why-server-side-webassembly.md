---
title: "Why Server-Side WebAssembly"
order: 1
part: "Foundations"
description: "The case for running server-side workloads as Wasm components, where they fit against containers, and what this site builds to show it."
duration: "12 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what a Wasm component adds on top of a `.wasm` module (a typed interface instead of raw linear-memory pointers) and why that matters for a server workload, not just a browser one.
- Compare a Wasm component against a container on cold-start time, image size, and the isolation mechanism each one relies on.
- Name the cases where server-side Wasm does not win: heavy native dependencies, long-lived stateful processes, and workloads that need a full POSIX surface.
- Describe the one WIT contract this site builds against, in both Rust and Go, and the two runtimes (wasmtime and wasmCloud) it runs under.

## Why this matters

A container solved real problems (packaging, isolation, portability), and most server workloads reach for one by default. A Wasm component starts in single-digit milliseconds, ships as a single-digit-megabyte artifact, and runs in a sandbox that denies every syscall unless the host grants it. That does not make it a replacement for the container: a component with no POSIX filesystem cannot shell out to a legacy binary, and a native C library with no path through WASI stays out of reach. The comparison below is concrete enough that any later decision to use a component, or not to, traces back to something specific.

## What a component is, briefly

A `.wasm` module is compiled code: a flat block of linear memory, a table of functions, and nothing describing what those functions mean to anyone outside the module. Two modules compiled from different languages that want to call each other must agree by hand on how integers and pointers into that memory line up. That is brittle in a browser with one JavaScript host, and worse on a server, where the point is many components in different languages calling each other.

The **Component Model** replaces the hand-rolled agreement with a typed interface described once in the WebAssembly Interface Type language (WIT) and compiled into bindings for each component's language. A WIT interface declares records, enums, resources and functions with real types (strings, lists, options, results), not raw bytes. Two components built from the same WIT world, one in Rust and one in Go, call each other's exports without either knowing the other's language. That is the shape of this site's shared cargo domain: one `cargo` world, implemented once in Rust and once in Go, each a drop-in replacement for the other because both compile against the same `patterncatalyst:cargo` package.

As of 2026-10 the Component Model is pre-1.0 (W3C Phase 2/3), but the toolchain is far enough along to build on: wasmtime 50.0.0 implements the model fully, `cargo-component` 0.21.1 generates Rust bindings from WIT, and stable Rust 1.99.1 targets `wasm32-wasip2` without a nightly. WASI Preview 2 (the 0.2.x line) is the stable target for the host interfaces a component imports instead of calling the OS: filesystem, sockets and clocks.

{% include excalidraw.html file="01-isolation-spectrum" alt="Three horizontal bands comparing a virtual machine, a container, and a Wasm component on isolation mechanism, image size, and cold-start time. The VM band shows a guest kernel with full hardware emulation, gigabyte images, and multi-second cold starts, isolated at the hypervisor boundary. The container band shows a shared host kernel with namespace and cgroup isolation, tens-of-megabytes images, and hundreds-of-milliseconds cold starts, isolated at the kernel boundary with a shared attack surface. The Wasm component band shows a wasmtime or wasmCloud capability-based sandbox, single-digit-megabyte images, single-digit-millisecond cold starts, no ambient syscalls, and a deny-by-default model where the host grants capabilities explicitly." caption="Figure 1.1: VM, container, and Wasm component on isolation, size, and startup." %}

## The case for server-side Wasm

**Cold start.** A container pays for process creation, cgroup and namespace setup, and whatever its runtime needs to initialize: a JVM warming its JIT, a Python interpreter importing modules, Node compiling JavaScript. That is hundreds of milliseconds at best and seconds at worst. A component under wasmtime is already compiled (ahead of time, or cached after the first JIT pass), and instantiation is allocating linear memory and wiring imports, which takes single-digit milliseconds. That gap makes scale-to-zero a realistic default and lets a Wasm sidecar start per request without the caller noticing.

**Density.** A container's isolation boundary is the kernel, so each one carries a network namespace, a mount namespace and a cgroup regardless of how little work it does. A wasmtime host can run hundreds of component instances in the footprint of a handful of containers, because an instance is closer to a heap allocation than a process. That changes the economics for many small, short-lived units of logic, such as a per-tenant policy check or a per-request transform.

**Isolation.** A container is isolated by the kernel: namespaces hide the host's process tree, filesystem and network stack, and cgroups cap consumption, but the container still makes real syscalls into a kernel shared with the host and every other container on the node. A kernel vulnerability or syscall-level escape reaches past the pod. A component has no ambient authority at all: it cannot open a file, open a socket or read the clock unless the host wires that capability in through WASI. That default is deny, where a container's is allow minus namespacing, which narrows the blast radius for code you do not fully trust: a third-party plugin, a user-submitted transform, a dependency with a known CVE you cannot patch today.

**Portability.** A component compiled once runs unmodified under wasmtime on Linux, macOS or Windows, and under wasmCloud across however many hosts are in the lattice, with no `GOOS`/`GOARCH` matrix and no image per architecture. The bytecode is the portable unit and the host supplies the rest. That is why the same component deploys unmodified to both minikube and OpenShift Local (CRC) in the Kubernetes part: only the host's capability grants change.

**Polyglot composition.** This is unique to the Component Model rather than to Wasm generally. Modules from C and Rust could always be linked at the binary level, but nothing enforced that their signatures agreed on meaning, only on byte layout. A WIT world removes that ambiguity. The Rust and Go cargo components both implement the same `cargo` world, and a third component in any language with a WIT toolchain (C, JavaScript via `componentize-js`, Python via `componentize-py`) could implement it without changing either. Containers are language-agnostic too, but composing two of them is a network call across process boundaries, not an in-process typed call.

## Where it does not win

| Limit | Why it holds a component back | What fits instead |
|---|---|---|
| Heavy native dependencies | A GPU inference library, a decades-old C image codec or an ODBC driver was never built for WASI's capability model, and porting is not a weekend's work. wasi-nn is one of the few native-heavy domains with an emerging WASI story, and the exception. | A container runs the native binary unmodified. |
| Long-lived stateful processes | An instance is cheap to create and discard, which is backwards for a process holding a large in-memory cache, a connection pool or gigabytes of warm state. Rebuilding that on every cold instantiation defeats its purpose. wasmCloud manages instance lifetime with more structure than a bare wasmtime embedding, but a workload whose value is a long-lived process is a container workload first. | A container with a persistent process. |
| A full POSIX surface | WASI Preview 2 exposes files, sockets, clocks and a few other facilities as explicit capability-gated interfaces: no `fork()`, signals, `ptrace`, arbitrary `ioctl` or process table. Shell scripts, subprocess-forking tools and raw device access do not compile to a component today, and the sandbox's value depends on not handing that authority out by default. | A container. |

Table 1.1 puts representative numbers on the comparison; they are not a benchmark of a specific workload.

| | Container (OCI image) | Wasm component (wasmtime) |
|---|---|---|
| Typical image size | Tens to hundreds of MBs | Single-digit MBs |
| Cold start | Hundreds of ms to low seconds | Single-digit to low tens of ms |
| Isolation mechanism | Kernel namespaces + cgroups, shared kernel | Runtime sandbox, capability-gated host calls |
| Default host access | Namespaced but broad (syscalls reach the shared kernel) | None; explicit grants only (WASI) |
| Cross-platform artifact | One image per OS/arch combination | One `.wasm` binary, any host with a compliant runtime |
| Long-lived state | Natural fit (persistent process) | Awkward (instances are meant to be cheap and short-lived) |
| Native library support | Full (whatever the base image ships) | Limited to what compiles to `wasm32-wasip2` or has a WASI shim |

For a single `book-cargo` call, a distroless image around a compiled Go or Rust binary typically lands at 20 to 80 MB and cold-starts in several hundred milliseconds to a couple of seconds with the image already cached. Pod security contexts can narrow its syscall surface with seccomp and dropped capabilities, but it still runs real instructions against a shared kernel. The same function as a component is under 5 MB for either language, instantiates under wasmtime in low single-digit milliseconds once cached, and makes no syscall the host did not grant. Those are ballpark figures to measure, not a substitute for measuring.

## What this site builds

The worked example is one WIT contract, package `patterncatalyst:cargo@0.1.0` for the shipping and cargo domain, implemented twice: a Rust component built with `cargo-component` and a Go component built with `wasm-tools` and `wit-bindgen-go`. It defines two interfaces, `booking` and `handling`, over a shared `types` interface carrying the records (`booking`, `cargo`, `handling-event`, `itinerary`) and the `cargo-error` variant every function can return. Both implementations target the `cargo` world and are interchangeable from any caller's point of view.

They run two ways. **wasmtime** is the standalone embedding: one host process instantiating components directly, the simplest way to see one run. **wasmCloud** is the distributed layer on top: a lattice of hosts, each running wasmtime, that links components declaratively and can move an instance between hosts without redeploying it. Real systems use wasmtime as the execution engine and wasmCloud, or something like it, to decide where and when that engine runs.

The deployment target is Kubernetes on two paths: minikube with the docker driver and containerd as the default local path, and OpenShift Local (CRC) as the enterprise-platform path. Both run the same component artifacts. The platform wiring changes (ingress shape, image registry, operator-managed add-ons), not the Wasm workload.

{% include excalidraw.html file="01-request-path" alt="A request entering a cluster and splitting across two nodes. Node A runs a container pod built from a booking-service image, routed through runc with namespace and cgroup isolation to a shared host kernel via scheduled syscalls. Node B runs a wasmtime host: the booking.wasm component, pulled from an OCI registry, is routed to a wasmtime instance that only reaches the host kernel's WASI Preview 2 surface through explicitly granted capabilities. Both paths expose the same WIT interface for booking and handling, labeled as a scheduled OS process on one side and an instantiated sandbox on the other." caption="Figure 1.2: Same WIT contract, two execution shapes: a container pod and a wasmtime-hosted component." %}

> **Decision**
>
> Use a Wasm component when the workload is short-lived or bursty enough that cold start and density matter, when the code is untrusted enough that a deny-by-default sandbox is worth it, or when the same logic must run across architectures and clusters without a build matrix. Stay with a container for long-lived state worth keeping warm, a native library with no `wasm32-wasip2` path, or POSIX facilities WASI Preview 2 does not expose. Most systems run both: Wasm components as sidecars and ambassadors next to ordinary container workloads.

> **🤖 Explore with your agent**
>
> "Using the WIT package in `contracts/wit` and the built components from `examples/part2-building-components`, compare the Rust `cargo_rust.wasm` and the Go `cargo-go.wasm` for the `cargo` world: file size, the exports `wasm-tools component wit` reports, and the imports each declares. Apply this decision rule: a component fits when it needs no host access beyond its declared WASI imports, and a container fits when it needs a native library or POSIX facilities. Say which side each of the two components lands on, and name any import that would change the answer."
>
> Check: `ls -l` on both `.wasm` files reports their sizes, and `wasm-tools component wit <file>` lists the `types`, `booking` and `handling` exports.

## For deeper coverage

- Chiarlone, G., *Server-Side WebAssembly* (Manning, 2026): the case for Wasm as a general-purpose server runtime, covering the Component Model and WASI from the ground up.
- Jain, A., *WebAssembly for Cloud* (Apress, 2024): Wasm's cloud-native ecosystem, including early wasmCloud and runtime comparisons.
- [WebAssembly Core Specification](https://webassembly.github.io/spec/core/): the module, instance, and execution semantics underlying what a `.wasm` binary is and how it runs.
