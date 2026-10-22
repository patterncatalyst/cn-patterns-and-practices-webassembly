# Part 7 — the final project's buildable core

Two deployable composites of the same cargo domain, one per language, proving
the book's two-language-one-contract thesis end to end:

```
part2 rust cargo provider  ─┐
                             ├─ wac plug ─> cargo-rust.wasm
part3 http-rust front door ─┘

part2 go cargo provider    ─┐
                             ├─ wac plug ─> cargo-go.wasm
part3 http-go front door   ─┘
```

Neither composite forks or edits a component. `build.sh` rebuilds the Part 2
providers and Part 3 front doors with their own, unedited recipes and plugs
each pair together with `wac plug`. `contracts/wit` is read, never written.

`cargo-rust.wasm` is the same composite `examples/part4-runtimes/wasmcloud/build.sh`
and `examples/part5-kubernetes/build.sh` already produce as `app.wasm` —
byte-identical, sha256 `eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3`.
`cargo-go.wasm` is the TinyGo counterpart, assembled here for the first time
from the Part 2 Go provider and the Part 3 `http-go` front door.

## Contract

Both composites export `wasi:http/incoming-handler` and serve:

- `GET /cargo/CARGO-USNYC-DEHAM` → `{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}`
- `GET /cargo/NOPE` → `404`

Byte-identical across languages. After `wac plug` satisfies the cargo import,
each composite imports only `wasi:*` interfaces (clocks, io, cli, filesystem,
random, http/types) — no `patterncatalyst:*` import survives composition.

## `build.sh`

```bash
./build.sh              # build + validate + package both OCI images
./build.sh --no-image   # build + validate only, skip the docker build
./build.sh --load       # also minikube image load into the 'part5' profile
```

Each run:

1. Builds the Part 2 Rust provider and Part 3 `http-rust` front door
   (`cargo component build --release`), `wac plug`s them into `cargo-rust.wasm`.
2. Builds the Part 2 Go provider and Part 3 `http-go` front door (TinyGo,
   their own `build.sh`), `wac plug`s them into `cargo-go.wasm`.
3. Validates both with `wasm-tools validate` and checks the export/import
   surface (exports the incoming-handler, imports only `wasi:*`).
4. Prints the sha256 of each.
5. Serves each with `wasmtime serve -S cli` on a local port and curls both
   paths above, asserting the exact JSON and the 404 — the gate a composite
   must pass before the image build runs.
6. Packages each as a `FROM scratch` OCI image (`cargo-rust:final`,
   `cargo-go:final`) from the single parameterized `Containerfile`, with
   `docker build --provenance=false` to keep a one-layer manifest.
7. With `--load`, copies both images into the minikube `part5` profile via
   `minikube image load` — only if that profile is already running; otherwise
   it prints a message and skips. No registry push, matching the
   docker-driver + containerd convention used throughout Part 5. The `--load`
   path is author-only: it never starts a cluster itself.

Both `.wasm` files and `target/` are gitignored — `build.sh` regenerates them
deterministically from the unedited Part 2/3 crates.

## Deploy target

Both images run under the runwasi `containerd-shim-wasmtime` shim exactly as
Part 5 describes: `runtimeClassName: wasmtime`, `command: ["/app.wasm"]`. The
scratch rootfs holds nothing else — the shim reads the component directly, no
Linux userland involved.
