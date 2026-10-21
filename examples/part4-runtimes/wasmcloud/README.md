# ch15 / ch16 — Running the same component on wasmCloud

This example deploys the cargo HTTP front door to a local **wasmCloud** lattice
and proves it serves live traffic through the HTTP server capability provider.
The deployed artifact (`app.wasm`) is **byte-for-byte the same component** that
`wasmtime serve` runs in Part 3 and in `prove-same-bytes.sh` (ch16).

```
part2 rust cargo provider  ─┐
                             ├─ wac plug ─> app.wasm ─┬─ wasmtime serve -S cli   (ch16)
part3 http-rust front door ─┘                        └─ wasmCloud httpserver link (ch15)
```

Everything here reuses the Part 2/3 crates by *building* them — nothing is forked
or edited, and `contracts/wit` stays pristine.

## Scripts

| script | what it does |
| --- | --- |
| `build.sh` | rebuilds the Part 2 provider + Part 3 http-rust and `wac plug`s them into `app.wasm` (prints its sha256). |
| `capture-evidence.sh` | full headless live run: `wash up` -> deploy -> link -> HTTP asserts -> resilience -> sha256 -> secret scrub, teeing to `evidence/<date>/`. |
| `prove-same-bytes.sh` | ch16: serves the SAME `app.wasm` under `wasmtime serve` and asserts the identical JSON + the sha256. |
| `teardown.sh` | idempotent: undeploy + delete the app, `wash down --all`. |

```bash
export WASH_DISABLE_INTERACTIVE=1
./capture-evidence.sh     # brings the lattice up and captures the proof
./prove-same-bytes.sh     # same bytes under wasmtime serve
./teardown.sh             # leave the box clean
```

## The wadm manifest (`wadm.yaml`)

A wadm 0.21.x / OAM `core.oam.dev/v1beta1` Application with two things in the
lattice and a link between them:

- **`cargo-http` (component)** — `image: file://./app.wasm`. A local file ref, so
  no registry push is needed. `wash up` and `wash app deploy` are both run from
  this directory, so the host resolves the relative path (it records the absolute
  `file:///…/app.wasm` in its log). A `spreadscaler` keeps one instance running.
- **`httpserver` (capability)** — `image: ghcr.io/wasmcloud/http-server:0.27.0`.
- **the link** — a `link` trait on the provider (source) targeting the component,
  on `wasi:http/incoming-handler`, with the listen address as source config:

  ```yaml
  - type: link
    properties:
      target: cargo-http
      namespace: wasi
      package: http
      interfaces: [incoming-handler]
      source_config:
        - name: cargo-http-listen
          properties:
            address: 0.0.0.0:8000
  ```

### The httpserver provider tag, and why

`ghcr.io/wasmcloud/http-server:0.27.0` — the latest released semver tag of the
provider (surveyed from the ghcr tag list; the only tags past that are
commit-SHA builds). It speaks `wasi:http` 0.2.x and is compatible with the
wasmcloud host **1.9.1** bundled in **wash 0.43.0**. Our `app.wasm` exports
`wasi:http/incoming-handler@0.2.8`; wasmCloud links by interface name across
compatible 0.2.x patch levels, so the link is satisfied.

## What `capture-evidence.sh` proves (live)

1. `wash up -d` brings up NATS + wadm + the wasmcloud host headless.
2. `wash app deploy wadm.yaml` starts the component (from the local file) and the
   provider, and establishes the link.
3. `GET http://127.0.0.1:8000/cargo/CARGO-USNYC-DEHAM` returns exactly:

   ```json
   {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
   ```

   and `GET /cargo/NOPE` returns `404`.
4. **Resilience / self-healing:** `wash scale component … --max-instances 0`
   removes the component while the provider's listener stays up. Traffic
   immediately fails (`500`, "failed to invoke `wrpc:http/incoming-handler`" — the
   provider is up but there is no component to handle the request), then wadm's
   SpreadScaler reconciles the component back to one instance and traffic recovers
   to `200` within a couple of seconds. No redeploy needed.
5. `sha256sum app.wasm` is recorded — the same hash `prove-same-bytes.sh` records
   for the `wasmtime serve` run.

Evidence is under `evidence/<YYYY-MM-DD>/` (committed): `00-wash-version`,
`01*-up/hosts`, `02-build`, `03*-deploy/status/inventory`, `04-http`,
`05-resilience`, `06-sha256`, `07-scrub`.

### Verified run (2026-10-21)

- Host: wasmcloud 1.9.1 (wash 0.43.0), provider `http-server:0.27.0`.
- `app.wasm` sha256 `eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3`
  — identical under wasmCloud and `wasmtime serve`.
- Resilience: scale-to-0 -> `500` -> self-heal -> `200` recovered in ~2 s.

## Gotchas worth a chapter callout

- **`exported component resources are not supported in wasmCloud runtime and will
  be ignored`** — a host WARN at component start. Our `handling` interface exports
  a `cargo-tracker` *resource*; the wasmCloud runtime ignores exported resources
  (use a provider for that shape). The HTTP path only uses `booking`, so it is
  unaffected — but it is a real difference from `wasmtime serve`, which runs the
  component as-is.
- **Local file refs resolve against the deploy CWD.** `file://./app.wasm` works
  because every `wash` command runs from this directory. If you deploy from
  elsewhere, use an absolute `file:///…` ref (or push to an OCI registry).
- **Readiness = a real `200`.** `wash app status` reporting `deployed` means the
  desired state was *accepted*; it does not by itself mean the component is
  answering. The capture gates on an actual HTTP `200` before asserting.
- **`wash scale` fights wadm on purpose here.** Scaling to 0 under a managed app
  is exactly how you see self-healing: wadm detects the drift and restores the
  declared instance count.
- **`app.wasm` is gitignored** (293 KiB build output); `build.sh` regenerates it
  deterministically. The `evidence/` text files ARE committed.
