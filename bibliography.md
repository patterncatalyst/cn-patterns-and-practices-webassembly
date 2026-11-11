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

<table class="bib">
  <colgroup><col style="width:66%"><col style="width:34%"></colgroup>
  <thead><tr><th>Title</th><th>Author(s)</th></tr></thead>
  <tbody>
    <tr><td><a href="https://www.manning.com/books/server-side-webassembly" rel="noopener"><em>Server-Side WebAssembly</em></a><br><small>Manning. The Component Model and the Wasm toolchain mechanics behind server-side components</small></td><td>Danilo Chiarlone</td></tr>
    <tr><td><a href="https://link.springer.com/book/10.1007/978-1-4842-7496-5" rel="noopener"><em>WebAssembly for Cloud</em></a><br><small>Apress. Running Wasm workloads on Kubernetes and the deployment topologies this site builds on</small></td><td>Shashank Jain</td></tr>
    <tr><td><a href="https://webassembly.github.io/spec/core/" rel="noopener">WebAssembly Core Specification</a><br><small>The core module format and execution semantics</small></td><td>W3C WebAssembly WG</td></tr>
    <tr><td><a href="https://component-model.bytecodealliance.org/" rel="noopener">WebAssembly Component Model</a><br><small>Components, worlds, and the canonical ABI the whole book builds against</small></td><td>Bytecode Alliance</td></tr>
    <tr><td><a href="https://component-model.bytecodealliance.org/design/wit.html" rel="noopener">WIT (Wasm Interface Type)</a><br><small>The interface definition language for the shared cargo contract</small></td><td>Bytecode Alliance</td></tr>
    <tr><td><a href="https://github.com/WebAssembly/WASI/blob/main/preview2/README.md" rel="noopener">WASI Preview 2</a><br><small>The capability-based system interface components import</small></td><td>WASI Subgroup</td></tr>
    <tr><td><a href="https://github.com/proxy-wasm/spec" rel="noopener">Proxy-Wasm ABI</a><br><small>The host ABI the Chapter 25 Istio gateway filter targets</small></td><td>proxy-wasm authors</td></tr>
    <tr><td><a href="https://docs.wasmtime.dev/" rel="noopener">wasmtime documentation</a><br><small>The host runtime the examples embed and the containerd shim wraps</small></td><td>Bytecode Alliance</td></tr>
    <tr><td><a href="https://wasmcloud.com/docs/" rel="noopener">wasmCloud documentation</a><br><small>The lattice, wadm, and capability-provider model in Part 4</small></td><td>wasmCloud (CNCF)</td></tr>
  </tbody>
</table>

These titles inform this site's coverage and rigor only. Nothing in these chapters
or the runnable examples copies text or code from them.
