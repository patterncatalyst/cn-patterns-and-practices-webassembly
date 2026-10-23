# Part 5: ch20/ch21 interposition (filter, adapter, ambassador)

Three interposition patterns composed over the same Part 2 provider and Part 3
HTTP front door used by the plain `app.wasm`, expressed on minikube as
**compile-time `wac plug` interposition** (the raw shim hosts one component per
container behind a fixed `:8080` hyper server, so an interposer is spliced into
the component graph at build time, not added as a pod sidecar). The repository
contract under `contracts/wit/` stays byte-for-byte pristine: every new component
declares its own local `wit/world.wit` and references `patterncatalyst:cargo` as a
path dependency.

## Components

| Dir | World package | Shape | What it does |
| --- | --- | --- | --- |
| `sidecar-filter/` (ch20) | `patterncatalyst:cargo-filter` | imports + exports the canonical cargo interfaces (interposer) | Destination-embargo policy + per-call stderr logging. An embargoed destination -> `cargo-error::invalid-location` (front door maps to 400); a normal destination passes through unchanged. |
| `adapter/` (ch21) | `patterncatalyst:cargo-adapter` | imports + exports canonical cargo and exports its own `legacy` interface | Shape translation. `book-cargo` round-trips each request canonical -> legacy -> canonical before calling the provider; the round-trip is lossless, so the exact cargo JSON still comes back. The `legacy` interface (flat codes, renamed fields, a `service-level` enum with no canonical counterpart) lets a legacy-shaped caller drive the modern provider. |
| `ambassador/` (ch21) | reuses `part3-interfaces/sockets-rust` | outbound command component | Resilient outbound calls: retry with exponential backoff + jitter behind a capability-scoped network grant. Minikube evidence is a local `wasmtime run -S inherit-network` smoke (the shim exposes no outbound-network knob); the cluster-live, lattice-linked form is the wasmCloud/CRC path. |

## wac plug chains

Both HTTP compositions are two `wac plug` steps (the interposer both imports and
exports `patterncatalyst:cargo/*`, so it sits transparently between provider and
front door):

```
# filtered
wac plug --plug <provider> <filter>  -o provider-filter.wasm
wac plug --plug provider-filter.wasm <http-rust> -o app-filtered.wasm

# adapted
wac plug --plug <provider> <adapter> -o provider-adapter.wasm
wac plug --plug provider-adapter.wasm <http-rust> -o app-adapted.wasm
```

Each `app-*.wasm` exports `wasi:http/incoming-handler` and imports `wasi:cli/stderr`
(logging), satisfied by the shim / `wasmtime serve`.

## Build + run

```
sidecar-filter/build.sh        # -> app-filtered.wasm + image cargo-http-filtered:minikube
adapter/build.sh               # -> app-adapted.wasm  + image cargo-http-adapted:minikube
ambassador/build.sh            # -> ambassador.wasm + local backoff/capability smoke

# live on minikube (docker + containerd), both compositions via nip.io Ingress:
k8s/verify-interposed-minikube.sh         # bring up, assert, tear down
k8s/capture-interposed-evidence.sh        # bring up, assert, write evidence/<date>/1N-*.txt
k8s/teardown.sh                           # delete the profile (box clean)
```

Manifests: `k8s/interposed/base` (sibling `cargo-http-filtered` / `cargo-http-adapted`
Deployments + Services + Ingresses) and `k8s/interposed/overlays/minikube` (retag to
`:minikube` + `imagePullPolicy: Never`). The shared Namespace and `wasmtime`
RuntimeClass are reused (not duplicated) from `k8s/base` + `install-shim.sh`.

## CRC hand-off (next executor)

The CRC expression is the runtime-link form: deploy the three canonical components
(provider, interposer, http front door) as a wasmCloud lattice and wire the links
at runtime instead of composing one `.wasm`. Link graph: the http front door's
`patterncatalyst:cargo/{types,booking,handling}` imports link to the interposer's
exports; the interposer's imports link to the provider's exports. The ambassador is
the outbound capability provider with a runtime-granted network link (the form the
local `-S inherit-network` smoke stands in for here).
