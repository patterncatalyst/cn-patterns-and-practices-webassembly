# Part 7 final project on OpenShift Local (CRC) — the reduced pass

This is the final project's CRC tier. minikube runs the full assembly (both
composites, the Ch25 Istio proxy-wasm gateway filter, and the OTel trace
capture). CRC runs a **reduced pass**: both language composites deployed via
the wasmCloud operator — the same Part 5/Ch19 CRC tier — fronted by edge-TLS
Routes. There is **no service mesh here**; the gateway filter and the Ch23
KEDA scale-to-zero pass stay minikube-only for this project.

```
cargo-rust.wasm (ghcr, private) ──host pulls──▶  wasmCloud host (operator-managed)
cargo-go.wasm   (ghcr, private) ──host pulls──┘

   wadm Application cargo-final-rust ─operator─▶ Service cargo-final-rust:8000 ─▶ Route cargo-final-rust ◀─ curl --cacert
   wadm Application cargo-final-go   ─operator─▶ Service cargo-final-go:8000   ─▶ Route cargo-final-go   ◀─ curl --cacert
```

Both composites are byte-for-byte what `../build.sh` produces:
`cargo-rust.wasm` (sha256 `eff7f5ee…`, the same composite Part 4/Part 5
already deploy) and `cargo-go.wasm` (the TinyGo counterpart, recorded at this
project's authoring time). `contracts/wit` is untouched; nothing here forks
or edits an interface.

## Run order (headless)

```bash
eval "$(crc oc-env)"
./openshift/deploy.sh             # operator install; push both composites; host; wadm app; Routes
./openshift/verify-crc.sh         # CA-verified curl through BOTH Routes: JSON + 404, byte-identical
./openshift/capture-evidence.sh   # re-runs verify + records evidence/<date>/
./openshift/teardown.sh           # remove everything, then crc stop
```

`deploy.sh` folds the operator install into itself (no separate
`install-operator.sh` for this reduced pass — one script, idempotent
`helm upgrade --install`). The live bring-up/teardown of CRC itself stays the
caller's call: `crc start` before, `teardown.sh` (`crc stop`) after. This
project never starts or stops the cluster.

## Pinned versions

No new pins for this chapter — it reuses the firm Part 5/Ch19 CRC tier as-is:

| thing | pin | why |
| --- | --- | --- |
| CRC / OpenShift | `2.64.0` / `4.22.14` | the version this project's CRC tier is surveyed against throughout Part 5. |
| platform chart | `oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2` | the last tagged release of the wasmCloud **v1** chart, bundling nats + wadm + the operator behind the `WasmCloudHostConfig` + OAM `v1beta1` model this project already uses. |
| wasmCloud host | `1.9.1` | the chart's default host (`1.2.1`) predates provider `0.27.0`'s wRPC protocol; `1.9.1` is the pairing Part 4/5 proved. |
| httpserver provider | `ghcr.io/wasmcloud/http-server:0.27.0` | reused verbatim, one instance per language (`httpserver-rust`, `httpserver-go`). |
| component images | `ghcr.io/patterncatalyst/cargo-rust:crc-final`, `ghcr.io/patterncatalyst/cargo-go:crc-final` (both private) | pushed with `wash push`; the host pulls both with the `ghcr-pull` docker-registry secret. |

## Two Applications, one per language

Ch19 and Ch20 each wire one httpserver provider per wadm Application, and this
reduced pass follows that shape: `cargo-final-rust` (component `cargo-rust` +
`httpserver-rust` on `0.0.0.0:8000`) and `cargo-final-go` (component `cargo-go`
+ `httpserver-go` on `0.0.0.0:8000`). The wasmCloud operator creates one
Service per Application — `cargo-final-rust` and `cargo-final-go` — each
exposing its httpserver port, and `deploy.sh` waits for both. A single
Application with two httpserver providers would need the operator to put both
providers' ports on one Service; it creates one Service per Application
instead, so `deploy.sh` keeps a port-count check as a guard. This is
`deploy-interposed.sh`'s coexisting-apps shape, two Applications instead of
three.

## Why two Routes

Each Application has its own Service, so each language gets its own edge-TLS
Route — `cargo-final-rust` → Service `cargo-final-rust`, `cargo-final-go` →
Service `cargo-final-go`, both on port 8000. The httpserver provider's
addressing model links one listen address to exactly one target component, and
neither composite is a router that dispatches to the other, so one provider,
one Service, one Route per language is the clean mapping — both reachable over
real HTTPS at `*.apps-crc.testing`.

## restricted-v2 / SCC

Everything runs in the **`wasmcloud-final`** project (a normal project, so it
is governed by `restricted-v2` — the `default` namespace is PodSecurity
`privileged` and would not prove anything). Same posture as Ch19: the
`WasmCloudHostConfig` CRD has no `securityContext` field and the operator
leaves the host/leaf containers' `securityContext` unset, so `restricted-v2`
assigns namespace-range UIDs, drops ALL capabilities, forbids privilege
escalation, and defaults seccomp to `RuntimeDefault`; `values-crc.yaml` drops
wadm's hard-coded `runAsUser/runAsGroup: 1000` for the same reason. No
`anyuid` exception is granted anywhere.

## The CA-verified curl (no -k, no port-forward, no NodePort)

`lib.sh`'s `combined_ca_bundle` writes the system trust store plus the
cluster's own ingress CA to a temp file; every curl in `deploy.sh`,
`verify-crc.sh` and `capture-evidence.sh` passes it to `--cacert`. That proves
real TLS against the Routes' own certificates — `-k` or an `oc port-forward`
would prove nothing about the Route path.

## Files

| file | purpose |
| --- | --- |
| `lib.sh` | shared config + helpers (sourced, not run) |
| `values-crc.yaml` | helm overlay for the platform chart in `wasmcloud-final` |
| `wasmcloud-host.yaml` | `WasmCloudHostConfig` for the in-cluster host |
| `wadm-final.yaml` | OAM Application — both composites, both httpserver providers |
| `route.yaml` | the two edge-TLS Routes |
| `deploy.sh` | operator install, push, host, wadm app, Routes — idempotent |
| `verify-crc.sh` | CA-verified proof: both Routes, exact JSON, byte-identical, 404 |
| `capture-evidence.sh` | re-runs verify, records `evidence/<date>/`, scrubs secrets |
| `teardown.sh` | remove everything this project added, then `crc stop` |

This directory is not an issue tracker — open questions live in this README
("Two providers, one Application") and get resolved the next time the pass
runs on CRC.
