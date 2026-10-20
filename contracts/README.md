# Contracts — the WIT single source of truth

This directory will hold the WIT (Wasm Interface Type) world for the
shipping/cargo domain — the WebAssembly analog of the REST site's OpenAPI
document, the gRPC site's Protobuf package, and the WebSockets site's
AsyncAPI document: the one artifact both the Rust and Go components generate
from and validate against.

## What lands here, and when

Not in r01. The bootstrap scaffold (this iteration) ships site chrome, the
locked outline, and the plans ledger only — no `.wit` body yet. A later
iteration adds:

- `wit/` — a `cargo` world defining the shipping/cargo domain's interfaces
  (bookings, cargo, handling events) that both language targets implement
  or consume.
- A CI drift gate: regenerate the Rust bindings (via `cargo-component`) and
  the Go bindings (via `wit-bindgen-go` or equivalent) from the WIT world on
  every push, and fail the build if either generated output no longer
  matches what's committed.

## Why `contracts/` is excluded from the Jekyll build

`contracts/` is in `_config.yml`'s `exclude:` list, the same as the sibling
REST/gRPC/WebSockets sites' contract directories. This file and the WIT world
that will join it are source artifacts validated in CI, not site content —
they will not render into the built Pages site. That is intentional.
