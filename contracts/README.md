# Contracts — the WIT single source of truth

This directory holds the WIT (Wasm Interface Type) package for the
shipping/cargo domain. It is the WebAssembly analog of the REST site's
OpenAPI document, the gRPC site's Protobuf package, and the WebSockets
site's AsyncAPI document: the one artifact both the Rust and Go components
generate from and validate against.

## Package layout

Package `patterncatalyst:cargo@0.1.0`, split across four files in `wit/`:

- `wit/types.wit` — interface `types`. Shared records (`location`, `money`,
  `cargo`, `route-spec`, `booking`, `leg`, `itinerary`, `handling-event`),
  enums (`handling-event-type`, `routing-status`, `transport-status`, each
  with an explicit `unspecified` first variant), and the shared
  `cargo-error` variant. No functions.
- `wit/bookings.wit` — interface `booking`. Functions `book-cargo`,
  `request-possible-routes`, `assign-route`, and `get-cargo`, each
  returning `result<_, cargo-error>`.
- `wit/handling.wit` — interface `handling`. Functions
  `register-handling-event` and `list-handling-events`, plus the
  `cargo-tracker` resource (constructor + `tracking-id`, `current-status`,
  `history` methods) that follows one cargo's status over time.
- `wit/world.wit` — two worlds over the same interfaces: `cargo` exports
  `types`, `booking`, and `handling` (the provider side, what a Rust or Go
  component implementing the domain targets); `cargo-consumer` imports the
  same three interfaces (the consumer side, what a component calling into
  a `cargo`-implementing component targets).

The package has no dependency on `wasi:*` or any other package, so
validating it needs no `deps/` fetch. WASI worlds are covered illustratively
in the chapters, not wired into this package.

## r02 posture: validate-only

This iteration validates the WIT package's syntax and structure. CI runs:

```
wasm-tools component wit contracts/wit
```

in `.github/workflows/contracts.yml` on every push and pull request, and
fails the build if the package does not parse.

The full drift gate is deferred to r03, once the first examples and their
checked-in bindings exist to diff against. That gate will regenerate the
Rust bindings (via `cargo-component`) and the Go bindings (via `wasm-tools`
or `wit-bindgen-go`) from this WIT package and fail the build if either
generated output no longer matches what's committed.

## Why `contracts/` is excluded from the Jekyll build

`contracts/` is in `_config.yml`'s `exclude:` list, the same as the sibling
REST/gRPC/WebSockets sites' contract directories. This file and the WIT
package next to it are source artifacts validated in CI, not site content.
Neither renders into the built Pages site.
