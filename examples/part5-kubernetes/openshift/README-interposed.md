# ch20/ch21 interposition on OpenShift Local (CRC): the runtime-link form

The minikube deploy (`../k8s`) expresses the ch20/ch21 interposition patterns as
**compile-time `wac plug` composition**: the provider, the interposer and the HTTP
front door are spliced into one `.wasm` per Pod. This directory expresses the same
patterns as the **runtime-link form**: the three components run as **separate
wasmCloud components** wired by **wadm `link` traits at runtime**, over wRPC, on
the custom `patterncatalyst:cargo` interface. It builds on the r06b single-component
OpenShift deploy (same platform chart, operator, host 1.9.1, restricted-v2,
edge-TLS Routes, CA-verified curl, the 8 CRC notes); those files stay pristine.

```
app  = cargo-filtered (ch20) / cargo-adapted (ch21) / cargo-ambassador (ch21)
httpserver --wasi:http/incoming-handler--> front door
front door --patterncatalyst:cargo/booking--> interposer
interposer --patterncatalyst:cargo/booking,handling--> provider
            (ambassador: front door --cargo/booking--> provider, no interposer)
```

`contracts/wit` is untouched; the components are reused as built in r06c part 1,
not edited.

## Run order (headless)

```bash
eval "$(crc oc-env)"
./openshift/install-operator.sh          # r06b: nats + wadm + operator (pinned chart)
./openshift/deploy-interposed.sh         # build+push 4 raw components; host; 3 linked apps; Routes
./openshift/verify-interposed-crc.sh     # CA-verified curl per app (working subset + state gotcha)
./openshift/capture-interposed-evidence.sh  # re-verify + record evidence/<date>/10-19
./openshift/teardown-interposed.sh       # remove interposed apps, then r06b teardown + crc stop
```

## The link graph that worked (exact wadm link traits)

A `link` trait is declared on the **source** (the importer); `target` names the
**exporter** it calls. Custom interfaces are supported since wasmCloud 1.8 and
travel over wRPC on the lattice.

| source (importer) | target (exporter) | namespace | package | interfaces |
| --- | --- | --- | --- | --- |
| httpserver-* (provider) | front door | `wasi` | `http` | `incoming-handler` |
| front door | interposer | `patterncatalyst` | `cargo` | `booking` |
| interposer | provider | `patterncatalyst` | `cargo` | `booking`, `handling` |
| cargo-ambassador (front door) | cargo-provider-am | `patterncatalyst` | `cargo` | `booking` |

The HTTP front door imports only `booking` (plus the pure-type `types`, which has
no functions and is never linked), not `handling`, so the front door → interposer
link carries `booking` only. The interposer imports both, so its link to the
provider carries `booking` and `handling`.

Each app has its own httpserver on a distinct port (8000 / 8001 / 8002) so the
provider instances coexist in one in-cluster host pod, and its own operator-created
Service (named after the Application) + edge-TLS Route. All component/provider
names are globally unique in the `default` lattice so the three apps coexist.

## What the runtime links PROVE (the working subset, all live, CA-verified)

- **FILTERED (ch20):** the interposer's destination-embargo **policy fires across
  the link**: `GET /cargo/CARGO-USNYC-CUHAV` → **400** (`destination CUHAV is
  under embargo`) before the provider is ever called; an unknown id traverses the
  full chain front door → filter → provider → **404**. The filter's own
  `cargo-filter: ...` log lines in the host pod prove it is live in the chain.
- **ADAPTED (ch21):** the shape-translation round-trip runs; unknown id → **404**.
- **AMBASSADOR (ch21):** the front door **reaches the provider across the
  runtime-granted link**: `GET /cargo/NOPE` → the provider's own **404** proves the
  outbound wRPC call completed. The same app without the link
  (`wadm-ambassador-nogrant.yaml`) cannot be admitted: the unlinked cargo import
  leaves the front door unservable, the Service gets no endpoints, and the Route
  fails fast with a **5xx** (503). The 404-vs-5xx contrast is the capability grant.
  (The retry/backoff half
  of the ambassador is the Part 1 local `wasmtime run -S inherit-network` smoke;
  the shim path exposes no outbound knob.)

## State across runtime links vs. compile-time composition (the chapter headline)

A valid id (`GET /cargo/CARGO-USNYC-DEHAM`) returns the provider's **404**
(`no cargo CARGO-USNYC-DEHAM`), not the exact cargo JSON (200). This is correct,
expected behaviour, and it is the most important thing this deploy teaches:

- The front door handles a valid id by calling `book-cargo` **then** `get-cargo`:
  **two separate wRPC calls** to the provider across the link.
- **wasmCloud components are stateless by design: each invocation gets a fresh
  instance and its linear memory is reset.** The Part 2 provider stores bookings in
  a `thread_local` HashMap; the booking written by `book-cargo` is gone when
  `get-cargo` runs on a fresh provider instance → the provider answers NotFound.
- Under minikube's `wac plug` composite, `book-cargo` and `get-cargo` are
  **in-process calls within one instance** for the single HTTP request, so the
  HashMap is shared and the exact JSON (200) comes back.

So the exact cargo JSON requires **in-process composition** (the minikube / r06b
form), not a runtime link. The runtime-link form buys independent lifecycle,
independent scaling, and runtime policy/shape injection, at the cost that
**in-memory state does not survive across the link**. The fix for a stateful domain
is a capability provider (e.g. a key-value store) or a wasmCloud **Service**
workload (one pinned long-lived instance), neither of which the frozen r06c
components use. See
<https://wasmcloud.com/docs/overview/workloads/services/> and
<https://wasmcloud.com/docs/overview/workloads/components/>.

The working subset above is proven live; the state behavior above is documented
with the real provider error.

## Notes worth a chapter callout (on top of the 8 in README.md)

1. **Component-to-component links on a custom interface work.** `patterncatalyst:
   cargo/booking` links between three separate components resolve over wRPC on
   host 1.9.1; the interposer sits transparently between front door and provider
   with no caller/provider change, purely via wadm links.
2. **Per-invocation statelessness breaks a multi-call round-trip across a link.**
   The single biggest difference from `wac plug`: a composite shares one linear
   memory per request; runtime links do not. Any pattern that relies on in-memory
   state surviving between two cross-component calls must move the state to a
   provider/Service. (See state behavior above.)
3. **The front door imports only `booking`, not `handling`.** Link only the
   interfaces a component imports; linking a non-imported interface is an
   error. `types` has no functions and is never linked.
4. **One httpserver port per app.** Multiple apps' httpserver providers share the
   host pod; give each a distinct listen port (8000/8001/8002) or they fight over
   the socket. The operator makes one Service per app on that app's port.
5. **Readiness is the 404 on an unknown id, not a 200.** The exact-JSON 200 is
   unreachable here (see state behavior above), so the deploy gate waits for the
   provider's NotFound 404, which still proves every link in the chain is wired.

## Evidence

`evidence/<YYYY-MM-DD>/` (committed), numbered 10-19 to sit beside the r06b
single-component evidence (00-06): `10-interposed-versions`, `11-interposed-pods`,
`12-interposed-links`, `13-services-routes`, `14-filtered-http`, `15-adapted-http`,
`16-ambassador-http`, `17-interposer-in-path`, `18-verify-interposed.log`,
`19-interposed-sha256-scrub`.
