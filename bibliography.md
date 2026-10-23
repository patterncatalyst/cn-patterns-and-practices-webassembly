---
title: "Bibliography"
layout: plan
permalink: /bibliography/
description: "The reference works this site's coverage and rigor draw on: nothing here is ported from them."
---

This site's chapter arc, pattern coverage, and level of rigor draw on a small set
of books and primary documentation on WebAssembly, the Component Model, and WASI.
They're reference works, not sources: no text or code from any of them is
reproduced here. If a topic in this site is useful to you, these are where to go
deeper.

| Title | Author(s) | Publisher | Focus |
|---|---|---|---|
| [*Server-Side WebAssembly*](https://www.manning.com/books/server-side-webassembly) | Danilo Chiarlone | Manning | The Component Model and the Wasm toolchain mechanics behind server-side components |
| [*WebAssembly for Cloud*](https://link.springer.com/book/10.1007/978-1-4842-7496-5) | Shashank Jain | Apress | Running Wasm workloads on Kubernetes and the deployment topologies this site builds on |
| [WebAssembly Core Specification](https://webassembly.github.io/spec/core/) | W3C WebAssembly WG | - | The core module format and execution semantics |
| [WebAssembly Component Model](https://component-model.bytecodealliance.org/) | Bytecode Alliance | - | Components, worlds, and the canonical ABI the whole book builds against |
| [WIT (Wasm Interface Type)](https://component-model.bytecodealliance.org/design/wit.html) | Bytecode Alliance | - | The interface definition language for the shared cargo contract |
| [WASI Preview 2](https://github.com/WebAssembly/WASI/blob/main/preview2/README.md) | WASI Subgroup | - | The capability-based system interface components import |
| [Proxy-Wasm ABI](https://github.com/proxy-wasm/spec) | proxy-wasm authors | - | The host ABI the Chapter 25 Istio gateway filter targets |
| [wasmtime documentation](https://docs.wasmtime.dev/) | Bytecode Alliance | - | The host runtime the examples embed and the containerd shim wraps |
| [wasmCloud documentation](https://wasmcloud.com/docs/) | wasmCloud (CNCF) | - | The lattice, wadm, and capability-provider model in Part 4 |

These titles inform this site's coverage and rigor only. Nothing in these chapters
or the runnable examples copies text or code from them.
