# API Patterns and Practices: Server-Side WebAssembly

Designing and deploying server-side WebAssembly components well, with runnable
examples in **Rust** and **Go** against one **WIT** contract: a chapter-based
Jekyll site, in the `lgtm` house style.

Fifth site in the *API Patterns & Practices* series (REST →
[gRPC](https://github.com/patterncatalyst/api-patterns-and-practices-grpc) →
[GraphQL](https://github.com/patterncatalyst/api-patterns-and-practices-graphql) →
[WebSockets](https://github.com/patterncatalyst/api-patterns-and-practices-websockets) →
Server-Side WebAssembly, after
[REST](https://github.com/patterncatalyst/api-patterns-and-practices-rest)). This
site steps below the protocol layer the other four cover: instead of a wire
format over HTTP or a socket, the unit under design is a **Wasm component** (a
sandboxed, portable, near-native-speed unit of compute), and the question is how
to build, compose, run, and deploy one well. The shipping/cargo domain is
continuous with the series: the same `Booking`/`Cargo`/handling-event vocabulary,
now implemented as cargo-handling components instead of REST, gRPC, or
WebSocket endpoints. For HTTP and gRPC protocol detail (headers, status codes,
the four RPC types, deadlines), see the REST and gRPC sibling sites above:
this site covers HTTP and gRPC only as interfaces a component can expose, not
protocol fundamentals.

## What's here

- **29 chapters (Ch0–Ch28) across 8 parts**: from the execution model and the
  Component Model/WIT, through building the same component in Rust and in Go,
  exposing it over HTTP and gRPC, running it under wasmtime and wasmCloud,
  deploying it to Kubernetes (minikube and OpenShift Local/CRC), scaling it
  with HPA and KEDA scale-to-zero, Istio and WebAssembly, a survey of other
  Wasm backend architectures (Spin), a wasi-nn cargo-classifier, and a Final
  Project.
- **Both languages, first-class:** every hands-on chapter ships a Rust
  component and a Go component built against the **same** WIT world.
- **Contract-first:** a WIT world is the single source of truth for the
  shipping/cargo domain's component interfaces; both languages generate
  bindings from it, with a CI drift gate.
- **Two runtimes:** wasmtime (standalone, embeddable) and wasmCloud
  (distributed actor runtime), run separately and then together.
- **Two cluster tiers:** minikube (docker driver, containerd runtime) and
  OpenShift Local (CRC), both deployed and verified.

This repository holds the complete book: 29 chapters across 8 parts, the WIT
contract, and runnable examples in both Rust and Go for every hands-on
chapter.

## Domain

The canonical **shipping / cargo** domain used across patterncatalyst
material: `Booking`, `Cargo`, `Location` (UN/LOCODE), `Route`, `Operation`,
and `Money` as a decimal string. Here, the domain is implemented as Wasm
components: the same story as the REST, gRPC, and WebSockets siblings, one
layer below the protocol.

## Build locally

```bash
bundle install
bundle exec jekyll serve --baseurl ""
# → http://localhost:4000
```

## Layout

| Path | What |
|---|---|
| `_docs/` | The chapters + the CRC appendix (Markdown). |
| `_parts/` | The 8 Parts the chapters are grouped under. |
| `_plans/` | Build plan, decisions log, version matrix: excluded from the build. |
| `_example_pages/` | The examples index. |
| `contracts/` | The WIT world (excluded from the built site). |
| `scripts/` | Diagram generation (`generate_diagram.py`). |

## Live site

[patterncatalyst.github.io/cn-patterns-and-practices-webassembly](https://patterncatalyst.github.io/cn-patterns-and-practices-webassembly/)

## License

This project is dual-licensed to separate the code from the writing:

- **Code:** everything under `examples/`, plus build and helper scripts and
  inline code snippets, is licensed under the **Apache License 2.0**
  ([`LICENSE`](LICENSE)).
- **Content:** the tutorial and book prose (chapters under `_docs/`),
  diagrams and images under `assets/`, and the slide decks under
  `presentation/`, is licensed under **Creative Commons Attribution 4.0
  International (CC BY 4.0)** ([`LICENSE-docs.md`](LICENSE-docs.md)).

Copyright 2026 PatternCatalyst (Robert Sedor).

