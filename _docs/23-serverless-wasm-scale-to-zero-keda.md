---
title: "Serverless Wasm: Scale-to-Zero with KEDA"
order: 23
part: "Deploying to Kubernetes"
description: "Scale a Wasm workload to zero with KEDA's HTTP add-on and the Kafka scaler, and measure the cold-start payoff a component gets over a container."
duration: "20 min read"
---

## Learning objectives

By the end of this chapter you can:

- Read the `HTTPScaledObject` spec and explain why KEDA's HTTP add-on 0.16 CRD nests replica bounds under `spec.replicas.{min,max}` rather than a top-level `minReplicaCount`, and why the Ingress in front of it routes through an `ExternalName` interceptor-proxy Service instead of straight to `cargo-http`.
- Trace a cold request on minikube end to end: an idle Deployment at zero replicas, the KEDA HTTP add-on interceptor holding the request, the 0-to-1 scale-up, and the real response returned once the Pod is ready.
- Read `examples/part5-kubernetes/kafka-handler/wit/world.wit` and `src/lib.rs` to see a Wasm component that exports `wasmcloud:messaging/handler@0.2.0` and imports the cargo domain's `handling` interface, and explain why a message-driven workload like this one needs a host that embeds a runtime and calls it per delivered message, rather than the raw containerd shim's fixed `wasi:http` listener.
- Read `examples/part5-kubernetes/kafka-host/src/main.rs` to see a plain Rust binary join a real Kafka consumer group with `rdkafka`, embed a `wasmtime` runtime, and call `kafka-app.wasm`'s `handle-message` export once per delivered message, committing the offset only after that call returns.
- Compare the HTTP add-on's `HTTPScaledObject` concurrency trigger against the Kafka half's `ScaledObject` `kafka` trigger, and explain why both patch a plain Kubernetes Deployment's replica count directly, 0 to N and back to 0, even though the signal driving each — request concurrency versus consumer-group lag — is different.

## Why this matters

Chapter 22 drove `cargo-http`'s replica count with a plain `autoscaling/v2` HorizontalPodAutoscaler: real scaling, because a Pod with `runtimeClassName: wasmtime` is still cgrouped and metered by the kubelet exactly like a `runc` Pod, so metrics-server and the HPA controller work unmodified. That HPA is bounded below by `minReplicas: 1`: a plain HPA has no notion of zero, because something has to keep answering `/metrics` for it to read. This chapter goes one step further, all the way to zero replicas, with two different KEDA triggers reaching that point the same way: by patching a plain Kubernetes Deployment's `spec.replicas` directly.

The first trigger is request concurrency: the KEDA HTTP add-on holds a cold request at an interceptor, an `HTTPScaledObject` patches the raw-shim `cargo-http` Deployment from zero to one, and the interceptor forwards the held request once the new Pod is Ready. The second trigger is consumer-group lag: a plain `ScaledObject` with a `kafka` trigger reads lag on `cargo-handling-events` and patches `cargo-kafka-host`, a different kind of Deployment — a native process that joins the consumer group itself and calls a Wasm handler once per delivered message, rather than answering an inbound HTTP request. Both triggers end at the same mechanism, a `keda.sh/v1alpha1` object scaling a Deployment it can actually patch; what differs is the signal each one reads and the shape of workload on the other end of it.

{% include excalidraw.html file="23-two-keda-models" alt="Two bands, both labeled KEDA DRIVES. Left, HTTP: a cold HTTP request arrives at a raw-shim Wasm Deployment scaled to zero; the KEDA HTTP add-on interceptor queues the request and asks an HTTPScaledObject with replicas.min 0 / replicas.max N to scale the Deployment from 0 to 1, then replays the queued request once the new Pod is ready. Right, Kafka: Kafka consumer-group lag on cargo-handling-events feeds a KEDA kafka ScaledObject with lagThreshold 5, which scales the cargo-kafka-host Deployment from 0 to N directly; the host embeds an rdkafka consumer group plus a wasmtime runtime, calls the Wasm handler per record, and commits the offset, and lag draining scales it back to 0." caption="Figure 23.1 — two trigger types, one owner: KEDA patches a Deployment's replica count directly in both halves, request concurrency on the left and consumer-group lag on the right." %}

The HTTP half of this chapter, on minikube, is **verified live 2026-10-21** (evidence under `k8s/keda/evidence/2026-10-21/`). The Kafka half, on minikube, is **verified live 2026-10-22** (evidence under `k8s/keda/evidence/2026-10-22/`). The Kafka half's CRC port is deferred.

## The HTTP half: KEDA drives a raw-shim Deployment to zero

`examples/part5-kubernetes/k8s/keda/install-keda.sh` installs two pinned Helm charts from the `kedacore` repository on minikube: KEDA core 2.21.0, then the KEDA HTTP add-on 0.16.0, which the add-on's own chart declares a hard floor against (core must be at least 2.21). Both land in the `keda` namespace alongside `ingress-nginx`, which this half already needs for the plain `cargo-http` stack Chapters 17, 18, and 22 all deploy unmodified. `examples/part5-kubernetes/k8s/keda/base/httpscaledobject.yaml` is the object that turns that ordinary Deployment into a scale-to-zero workload:

{% raw %}
```yaml
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata:
  name: cargo-http
  namespace: part5-kubernetes
  labels:
    app.kubernetes.io/name: cargo-http
    app.kubernetes.io/part-of: part5-kubernetes
spec:
  hosts:
    - cargo.part5-kubernetes.example
  pathPrefixes:
    - /
  scaleTargetRef:
    name: cargo-http
    kind: Deployment
    apiVersion: apps/v1
    service: cargo-http
    port: 8080
  replicas:
    min: 0
    max: 5
  scalingMetric:
    concurrency:
      targetValue: 1
  scaledownPeriod: 30
```
{% endraw %}

`scalingMetric.concurrency.targetValue: 1` means a single in-flight request is enough to trigger a scale-out, matching the HPA's low `50m` CPU request from Chapter 22: both are tuned so a single `curl` demonstrates the mechanism without a load-testing tool. `scaledownPeriod: 30` is cut far below the add-on's own default (hundreds of seconds), because a Wasm component has no JVM-style warm-up to protect against: `containerd-shim-wasmtime` starts serving within milliseconds of a Pod going Ready, so there is no reason to wait minutes of idleness before scaling back down.

<div class="callout callout--warn"><p class="callout__title">Gotcha</p><p>On the 0.16 <code>HTTPScaledObject</code> CRD, replica bounds nest under <code>spec.replicas.{min,max}</code>, not a top-level <code>minReplicaCount</code> (the field the Kafka half's plain <code>ScaledObject</code> uses) — verified against the upstream CRD (<code>kedacore/http-add-on @ v0.16.0</code>, <code>config/crd/bases/http.keda.sh_httpscaledobjects.yaml</code>) and the reference doc at <a href="https://keda.sh/docs/http-add-on/0.16/reference/httpscaledobject/">keda.sh/docs/http-add-on/0.16/reference/httpscaledobject</a>. <code>HTTPScaledObject</code> is marked deprecated as of the 0.16 line in favor of a newer <code>InterceptorRoute</code> (<code>http.keda.sh/v1beta1</code>), still shipped and functional in 0.16; the deprecation is a forward-migration notice, not a removal, so this chapter uses <code>HTTPScaledObject</code> and names the newer resource for anyone building past these pinned versions.</p></div>

A `ScaledObject`-driven Ingress has one more wrinkle before a cold request can actually reach the interceptor. Kubernetes requires an Ingress backend to be a Service in the same namespace as the Ingress object, but the HTTP add-on's interceptor proxy Service lives in the `keda` namespace, not `part5-kubernetes`. The standard KEDA recipe for bridging that gap is a same-namespace `ExternalName` Service that resolves to the interceptor's cluster DNS name:

{% raw %}
```yaml
apiVersion: v1
kind: Service
metadata:
  name: keda-interceptor-proxy
  namespace: part5-kubernetes
  labels:
    app.kubernetes.io/name: keda-interceptor-proxy
    app.kubernetes.io/part-of: part5-kubernetes
spec:
  type: ExternalName
  externalName: keda-add-ons-http-interceptor-proxy.keda.svc.cluster.local
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```
{% endraw %}

`examples/part5-kubernetes/k8s/keda/base/kustomization.yaml` then patches the base Ingress to point at `keda-interceptor-proxy` instead of `cargo-http` directly, and adds the companion annotation ingress-nginx needs to actually honor an `ExternalName` backend:

{% raw %}
```yaml
patches:
  - target:
      kind: Ingress
      name: cargo-http
    patch: |-
      - op: replace
        path: /spec/rules/0/http/paths/0/backend/service/name
        value: keda-interceptor-proxy
      - op: add
        path: /metadata/annotations/nginx.ingress.kubernetes.io~1service-upstream
        value: "true"
```
{% endraw %}

`nginx.ingress.kubernetes.io/service-upstream: "true"` tells ingress-nginx to proxy to the Service's ClusterIP/DNS name directly instead of resolving Endpoints, which is what makes routing to an `ExternalName` target work at all. Without that rewiring, an Ingress pointed straight at `cargo-http` would have nothing to send traffic to the instant the Deployment hits zero replicas, because there would be no Endpoint behind the Service. Scale-to-zero and a direct Ingress route are mutually exclusive, which is exactly why the interceptor has to sit in the path.

With that in place, the request flow for an idle workload is:

```
curl -> cargo.<minikube-ip>.nip.io  (ingress-nginx)
     -> keda-interceptor-proxy (ExternalName -> keda namespace)
     -> keda-add-ons-http-interceptor-proxy  (holds the request, asks KEDA to scale 0 -> 1, waits for Ready)
     -> Service cargo-http:8080 -> Pod (runtimeClassName: wasmtime)
     -> containerd-shim-wasmtime -> app.wasm
```

`examples/part5-kubernetes/k8s/keda/verify-keda-http-minikube.sh` proves this sequence against a live profile: it deploys the overlay, waits for the Deployment to report zero replicas while idle, then fires one timed cold request and asserts both a `200` and the exact cargo JSON Chapters 18, 20, and 21 all return for the same tracking id. The timing comes from `curl -w '%{http_code} %{time_total}'`, so the cold-start latency is a measured wall-clock number, not an estimate. This half of the chapter is **verified live 2026-10-21**, with evidence committed under `k8s/keda/evidence/2026-10-21/`:

```
# idle: KEDA scales cargo-http to 0 after ~40s
scaled-to-zero after 40s

$ curl -sS -w "%{http_code} %{time_total}" http://cargo.192.168.49.2.nip.io/cargo/CARGO-USNYC-DEHAM
http_code=200 cold_start_seconds=4.414011
body={"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
```

4.414 seconds is the end-to-end 0-to-1 cold start, measured from the client's own `curl`: the KEDA interceptor holding the request, Kubernetes scheduling and starting a fresh Pod, and the shim instantiating `app.wasm`, all added together. Kubernetes's own scheduling and Pod-startup path dominates that number; the component's own start under `containerd-shim-wasmtime` is sub-second once the Pod is actually running, the same fast instantiation Chapter 22's scale-down-window discussion already established. A container-based workload paying the identical scheduling cost would add an image pull (unless the node already cached the image) and a language runtime's own startup on top, a JVM's classloading or a Python interpreter's import graph; a Wasm component skips both of those, so a Deployment built this way has less to pay for once Kubernetes decides to start a Pod at all, even though Kubernetes's own scheduling latency is the same for either kind of Pod.

There is no dedicated CRC build for this half of the chapter. OpenShift Local's Part 5 deployment runs the wasmCloud operator exclusively (Chapter 19), never a plain `RuntimeClass`-backed Deployment, so there is no `cargo-http`-shaped workload on CRC for the Custom Metrics Autoscaler (Red Hat's KEDA distribution) to drive directly the way the upstream HTTP add-on drives one on minikube. Installing the Custom Metrics Autoscaler on CRC against a `cargo-kafka-host`-equivalent Deployment, the same KEDA-drives-a-Deployment shape this chapter builds on minikube, is a real follow-on; it is named here rather than built, since this chapter's CRC evidence is pending on the Kafka half's own minikube pass first, and the Kafka half's CRC port is deferred separately.

## Why the Kafka half needs a host that embeds the runtime, not the raw shim

Every other workload in Part 5, the plain `cargo-http` Deployment Chapter 18 proves, the interposed compositions Chapters 20 and 21 build on top of it, and the HTTP half above, speaks `wasi:http/incoming-handler` behind a fixed `:8080` listener. That is the one thing the raw containerd shim knows how to serve. Consuming messages from a Kafka topic is a different kind of capability entirely: something has to hold a long-lived consumer-group subscription, deserialize delivered records, and invoke application code once per message, independent of any inbound HTTP request. The raw shim has no binding for that at all: it is a `wasi:http` listener, not a general-purpose capability host, so a message-driven Wasm consumer cannot run on it no matter how the component itself is written.

The fix is a native host that owns the parts a Wasm component cannot: `cargo-kafka-host` (`examples/part5-kubernetes/kafka-host/src/main.rs`) is a plain Rust binary that joins the `cargo-handling-events` topic as a real consumer group using `rdkafka`, and for every delivered message, drives an embedded `wasmtime` runtime against `kafka-app.wasm`, calling its `handle-message` export and committing the offset only once that call returns. The Wasm side of the boundary is the same `kafka-handler` component below, exporting `wasmcloud:messaging/handler@0.2.0` — that WIT contract was already settled and vendored when the component was authored, so the host reuses it as the interface shape between the two sides, the same way Part 2's provider and consumer share a contract regardless of which concrete process calls which. What changes from a wasmCloud deployment is the thing on the other side of that export: here it is a native `wasmtime::component::bindgen!` host this chapter builds, not a wasmCloud lattice and a capability provider. `kafka-app.wasm` itself is `kafka-handler` plugged into the Part 2 cargo provider ahead of time with `wac plug` (`examples/part5-kubernetes/kafka-handler/build.sh`), the same compile-time composition Chapter 20's sidecar-filter uses on minikube (DRQ-061): the composite's only unresolved import is WASI, so the host never has to satisfy a `patterncatalyst:cargo` import itself. Deployed as a plain Kubernetes `Deployment` named `cargo-kafka-host`, this workload is exactly the kind of object a `ScaledObject` can patch — which is the whole reason the Kafka half can be KEDA-driven at all, the same way the HTTP half's raw-shim Deployment is.

## The Kafka half: KEDA drives a native rdkafka-to-wasmtime host

{% include excalidraw.html file="23-kafka-lag-flow" alt="A producer burst lands on a six-partition Kafka topic and raises real consumer-group lag. The KEDA kafka ScaledObject reads that lag and scales the cargo-kafka-host Deployment directly, 0 to N. The host joins the consumer group with rdkafka and, per delivered message, drives an embedded wasmtime runtime against kafka-app.wasm's handle-message export, then commits the offset. As the extra instances drain the backlog, lag falls and KEDA scales cargo-kafka-host back to zero." caption="Figure 23.2 — one loop, one owner: KEDA reads real consumer-group lag and scales cargo-kafka-host's replica count directly; the host embeds the Wasm runtime itself." %}

`examples/part5-kubernetes/kafka-handler/wit/world.wit` is the whole contract for the component this half scales:

{% raw %}
```wit
package patterncatalyst:cargo-kafka-handler@0.1.0;

world cargo-kafka-handler {
    export wasmcloud:messaging/types@0.2.0;
    export wasmcloud:messaging/handler@0.2.0;

    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;
}
```
{% endraw %}

`wasmcloud:messaging@0.2.0` is vendored verbatim under `wit/deps/messaging`, the same approach Part 3's `http-rust` already uses for `wasi:http`, because `cargo-component` never fetches WIT packages over the network: every non-contract package a local world references has to be present on disk. `patterncatalyst:cargo` is pulled in the same way Chapters 20 and 21's interposers pull it, a path dependency to the repository contract, never a copy and never an edit. The component exports `handler` (the callback the native host below invokes) and the `types` interface the `broker-message` record it depends on lives in, following the house convention of always listing a types-only interface a world's functional interfaces depend on. It imports `booking` and `handling`: a handling event records against an existing cargo, so each message ensures the cargo is on record (booking it when the domain has none) before registering the event.

`src/lib.rs` keeps the message format small: a pipe-delimited record, `CARGO_ID|EVENT_TYPE|UNLOCODE|VOYAGE_ID|RECORDED_AT`, parsed without a JSON crate, matching the zero-extra-dependency convention Chapter 20's `sidecar-filter` and Chapter 21's `adapter` both already follow. The `Guest` implementation parses, validates, ensures the cargo exists, then records the event:

{% raw %}
```rust
impl HandlerGuest for Component {
    fn handle_message(msg: BrokerMessage) -> Result<(), String> {
        let body = String::from_utf8(msg.body)
            .map_err(|e| format!("message body on subject '{}' is not valid UTF-8: {e}", msg.subject))?;
        log(&format!("received subject={} body={body:?}", msg.subject));

        let fields: Vec<&str> = body.splitn(5, '|').collect();
        if fields.len() != 5 {
            return Err(format!(
                "malformed message: expected 5 pipe-delimited fields \
                 (CARGO_ID|EVENT_TYPE|UNLOCODE|VOYAGE_ID|RECORDED_AT), got {}: {body:?}",
                fields.len()
            ));
        }
        let cargo_id = fields[0];
        let event_type_str = fields[1];
        let unlocode = fields[2];
        let voyage_id = fields[3];
        let recorded_at = fields[4];

        if cargo_id.is_empty() || unlocode.is_empty() {
            return Err(format!(
                "malformed message: cargo-id and unlocode must not be empty: {body:?}"
            ));
        }
        let event_type = event_type_from(event_type_str).ok_or_else(|| {
            format!(
                "unknown event type '{event_type_str}' (want one of \
                 received|loaded|unloaded|customs|claimed): {body:?}"
            )
        })?;

        let location = Location {
            unlocode: unlocode.to_string(),
            name: unlocode.to_string(),
            country: unlocode.to_string(),
        };

        ensure_cargo_booked(cargo_id, recorded_at)?;

        handling::register_handling_event(cargo_id, event_type, &location, voyage_id, recorded_at)
            .map_err(|e| format!("register-handling-event failed for cargo_id={cargo_id}: {e:?}"))?;

        log(&format!(
            "recorded handling event cargo_id={cargo_id} event_type={event_type_str} \
             location={unlocode} voyage_id={voyage_id} recorded_at={recorded_at}"
        ));
        Ok(())
    }
}
```
{% endraw %}

A malformed or unrecognized message surfaces as a rejected `result<_, string>` the host's delivery semantics then act on: a bad event type, missing fields, empty cargo-id, or invalid UTF-8 all return `Err` rather than being swallowed inside the handler. The location record defaults its `name` and `country` to the UN/LOCODE itself: the Kafka wire format in this demo carries only the code, not a full location lookup, and the cargo provider stays authoritative for any display-quality data.

`register-handling-event` records against an existing cargo, so `ensure_cargo_booked` runs first. It looks the cargo up and, when the domain has no record of it, reconstructs the route from the id — the `CARGO-<ORIGIN>-<DEST>` shape the cargo provider's own `book-cargo` generates (Part 2's `tracking_id_for`) — and books it:

{% raw %}
```rust
fn ensure_cargo_booked(cargo_id: &str, recorded_at: &str) -> Result<(), String> {
    match booking::get_cargo(cargo_id) {
        Ok(_) => Ok(()),
        Err(CargoError::NotFound(_)) => {
            let (origin, destination) = locations_from_cargo_id(cargo_id).ok_or_else(|| {
                format!("cannot derive origin/destination from cargo-id '{cargo_id}': \
                         expected CARGO-<ORIGIN>-<DEST>")
            })?;
            let loc = |c: &str| Location { unlocode: c.into(), name: c.into(), country: c.into() };
            let spec = RouteSpec {
                origin: loc(origin),
                destination: loc(destination),
                arrival_deadline: recorded_at.to_string(),
            };
            booking::book_cargo(&spec, DEFAULT_WEIGHT_KG).map(|_| ())
                .map_err(|e| format!("book-cargo failed for cargo_id={cargo_id}: {e:?}"))
        }
        Err(e) => Err(format!("get-cargo failed for cargo_id={cargo_id}: {e:?}")),
    }
}
```
{% endraw %}

Booking keyed on a lookup, not a create-once step, is what makes each invocation self-contained — which matters because the host below creates a fresh component instance per message, carrying no state between them.

`examples/part5-kubernetes/kafka-host/Cargo.toml` pins the host's Kafka-specific dependency exactly, because its build compiles a native library rather than linking a prebuilt one:

{% raw %}
```toml
[dependencies]
wasmtime = "50"
wasmtime-wasi = "50"
anyhow = "1"
rdkafka = { version = "=0.39.0", default-features = false, features = ["cmake-build", "libz-static"] }
signal-hook = "0.4.5"
```
{% endraw %}

`rdkafka` is pinned with `=0.39.0` and its `Cargo.lock` is committed, because the `cmake-build` feature compiles `librdkafka` from source at build time rather than linking a system package; the committed lockfile resolves `rdkafka-sys` to `4.10.0+2.12.1`, vendoring `librdkafka` **2.12.1**. `ssl`, `sasl`, and `gssapi` stay off: the broker's only listener is the unauthenticated internal `plain` listener on `kafka.yaml` below, so the build never needs OpenSSL, and turning those features on for a plaintext-only broker would just add attack surface and compile time for nothing. `wasmtime`/`wasmtime-wasi` stay on the same **50** line the rest of Part 5 pins. The synchronous `rdkafka::consumer::BaseConsumer` (no tokio) keeps the dependency surface small, since this host has no other reason to run an async executor; `signal-hook` gives it a clean SIGINT/SIGTERM shutdown instead of a bare process kill mid-poll.

The host's own WIT world, `examples/part5-kubernetes/kafka-host/wit/world.wit`, stays narrow:

{% raw %}
```wit
package patterncatalyst:cargo-kafka-host@0.1.0;

world kafka-host {
    export wasmcloud:messaging/types@0.2.0;
    export wasmcloud:messaging/handler@0.2.0;
}
```
{% endraw %}

This world is export-only, and it stops short of reusing `kafka-handler`'s own `cargo-kafka-handler` world directly: that world additionally imports `patterncatalyst:cargo/{types,handling}`, and `wasmtime::component::bindgen!`-ing against it here would generate host-side Rust `Host` traits for those imports that this crate would then have to stub out for no reason. `kafka-app.wasm`, the composite `wac plug` produces, satisfies that import internally with the real Part 2 provider; from the host's perspective the composite's only unresolved import is WASI, and the only exports it ever calls are the two declared above.

`examples/part5-kubernetes/kafka-host/src/main.rs` loads the engine and the composite once and shares them across every message, but gives each message a fresh `Store` — the same no-state-leak-across-invocations idiom Part 3's `grpc-bridge` uses for the identical reason, substituting a Kafka-delivered record for an RPC call:

{% raw %}
```rust
/// Runs one delivered message through a fresh instance of `kafka-app.wasm`.
fn handle(&self, subject: String, body: Vec<u8>) -> Result<Result<(), String>> {
    let mut store = self.new_store();
    let world = self.instantiate(&mut store)?;
    let handler = world.wasmcloud_messaging_handler();
    let msg = BrokerMessage { subject, body, reply_to: None };
    handler
        .call_handle_message(&mut store, &msg)
        .wc("call handle-message")
}
```
{% endraw %}

The poll loop around it commits the offset only after `handle` returns, and commits past a handler error rather than retrying it forever:

{% raw %}
```rust
let outcome = host.handle(subject, body);
// At-least-once, drain-on-poison semantics: a handler error means this
// message is malformed or unprocessable, not that the broker or the host
// is unhealthy. Committing past it anyway keeps the consumer group
// draining instead of wedging on a single bad message forever; a
// dead-letter topic would be the production-grade follow-up, not
// retry-without-bound.
if let Err(e) = consumer.commit_message(&message, CommitMode::Sync) {
    eprintln!("cargo-kafka-host: partition={partition} offset={offset} commit failed: {e}");
}
```
{% endraw %}

A shared `AtomicBool` set by both `SIGINT` and `SIGTERM` handlers breaks the poll loop cleanly, so the process exits promptly instead of being force-killed the moment KEDA scales `cargo-kafka-host` down.

The broker underneath all of this is Strimzi 1.3.0, in single-node KRaft mode (no ZooKeeper; Strimzi dropped it entirely by this release line). Strimzi 1.3.0 supports Kafka 4.2.0 through 4.3.1 (verified against the 1.3.0 release's own example manifests), so `examples/part5-kubernetes/k8s/kafka/base/kafka.yaml` pins the exact pairing Strimzi ships in its own example:

{% raw %}
```yaml
spec:
  kafka:
    version: 4.3.1
    metadataVersion: 4.3-IV0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
```
{% endraw %}

The replication and ISR settings are all forced to 1 because the Kafka defaults assume at least three brokers; a single-node demo cluster would never finish bootstrapping its internal topics otherwise. The topic itself carries six partitions, not Strimzi's single-partition example default:

{% raw %}
```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: cargo-handling-events
  namespace: kafka
  labels:
    strimzi.io/cluster: cargo-kafka
spec:
  partitions: 6
  replicas: 1
```
{% endraw %}

Six partitions is a chosen ceiling, not an arbitrary number: KEDA's `kafka` scaler can only ever usefully drive `cargo-kafka-host` up to the topic's partition count, because one consumer-group member can own at most one partition at a time. A single-partition topic would cap this demo at a 0-versus-1 toggle and never show a real multi-instance scale-out under a burst.

`examples/part5-kubernetes/k8s/kafka-host/base/deployment.yaml` is the plain `Deployment` KEDA scales. Unlike `cargo-http`, this Pod does not set `runtimeClassName: wasmtime`: the host process itself is an ordinary OCI container, and only the handler logic it loads from `KAFKA_APP_WASM` is a Wasm guest, run in-process:

{% raw %}
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cargo-kafka-host
  namespace: kafka
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: cargo-kafka-host
          image: cargo-kafka-host
          env:
            - name: KAFKA_BOOTSTRAP
              value: cargo-kafka-kafka-bootstrap.kafka.svc:9092
            - name: KAFKA_TOPIC
              value: cargo-handling-events
            - name: KAFKA_GROUP
              value: cargo-handling
            - name: KAFKA_APP_WASM
              value: /opt/cargo-kafka/kafka-app.wasm
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits: { cpu: "500m", memory: "256Mi" }
```
{% endraw %}

`examples/part5-kubernetes/k8s/keda/base/kafka-scaledobject.yaml` is the object that reads lag on that topic and patches this Deployment:

{% raw %}
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: cargo-kafka-host
  namespace: kafka
spec:
  scaleTargetRef:
    name: cargo-kafka-host
    kind: Deployment
  minReplicaCount: 0
  maxReplicaCount: 6 # capped at the topic's partition count
  cooldownPeriod: 30
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: cargo-kafka-kafka-bootstrap.kafka.svc:9092
        consumerGroup: cargo-handling
        topic: cargo-handling-events
        lagThreshold: "5"
        offsetResetPolicy: earliest
```
{% endraw %}

`scaleTargetRef` names `cargo-kafka-host` as a `Deployment` because that object actually exists in this cluster: a plain Kubernetes Deployment with a real `spec.replicas` field, the same kind of object the HTTP half's `HTTPScaledObject` patches. KEDA's `kafka` trigger reads consumer-group lag for `consumerGroup: cargo-handling` on `cargo-handling-events` and drives `spec.replicas` on this Deployment directly, 0 at idle up to the 6-partition ceiling under load — no second control plane in between. No `TriggerAuthentication` is attached, because the single internal `plain` listener on `kafka.yaml` carries no SASL or mTLS: a production broker with either would add one, referenced via `authenticationRef`, but this demo cluster's listener does not need it.

`examples/part5-kubernetes/k8s/kafka/producer-burst.sh` is what creates the lag this `ScaledObject` reads. It runs entirely in-cluster: `kubectl run` launches a disposable Strimzi client Pod (`quay.io/strimzi/kafka:1.3.0-kafka-4.3.1`, the same distribution the broker itself ships, reused rather than pulling a separate client image), and `kubectl exec` pipes a batch of pipe-delimited messages into `kafka-console-producer.sh` against the bootstrap service's cluster DNS name: no port-forward, no NodePort, the same in-cluster-exec convention Chapter 30 of the companion Python modernization project and every Part 5 verify script in this book already follow. Sixty messages round-robin across six distinct keys by default, so the partitioner spreads the burst across all six partitions instead of landing it entirely on one, which would cap the demo's visible scale-out at a single instance no matter how large the burst was.

The full sequence `examples/part5-kubernetes/k8s/keda/verify-keda-kafka-minikube.sh` proves is: the burst lands and the topic backlog is confirmed to have risen by reading the topic's end offsets (`kafka-get-offsets.sh` through `kubectl exec`, never assumed from the producer's own exit code). With no committed offset yet for the group, `offsetResetPolicy: earliest` makes KEDA's scaler treat that backlog as the consumer-group lag, so the `ScaledObject` goes Active and KEDA patches `cargo-kafka-host`'s `spec.replicas` from 0 up toward the 6-partition ceiling. Each new Pod's host process joins the `cargo-handling` consumer group, gets a share of the rebalanced partitions, and drains them — calling `handle-message` per record and committing after each one. As the group's committed offset catches the log-end (`kafka-consumer-groups.sh --describe` confirms lag falls to zero), KEDA scales `cargo-kafka-host` back down to zero after the cooldown period.

The live run on minikube (2026-10-22, evidence under `k8s/keda/evidence/2026-10-22/`) followed that sequence end to end:

- Idle: `cargo-kafka-host` at `0/0`.
- Burst of 120 messages: the topic end offset rose from 120 to 240.
- KEDA scaled `cargo-kafka-host` from 0 to a peak of 4 replicas; the `ScaledObject` reported Active.
- Each record was handled (`outcome=ok`, with `recorded handling event …` from the component).
- Drain: the `cargo-handling` group's current offset caught the log-end (240/240, lag 0).
- KEDA scaled `cargo-kafka-host` back to `0/0` after the cooldown.

The HTTP half's cold-start figure above is measured, from the 2026-10-21 minikube run; the Kafka timeline here is from the 2026-10-22 run. The Kafka half's CRC port is deferred.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Let KEDA own the replica count whenever the workload it targets is a resource the Kubernetes API actually lets a <code>ScaledObject</code> or <code>HTTPScaledObject</code> patch: a Deployment, a StatefulSet, anything with a real <code>spec.replicas</code> field. Both halves of this chapter take that shape now: the HTTP add-on's <code>HTTPScaledObject</code> against the raw-shim <code>cargo-http</code> Deployment, and the <code>kafka</code> <code>ScaledObject</code> against the native <code>cargo-kafka-host</code> Deployment. The two differ only in trigger type, request concurrency versus consumer-group lag, and in the shape of workload on the other end of it, a request/response HTTP service versus a long-lived message-consuming process, never in who owns the scale. Reach for a workload that embeds the runtime directly, an <code>rdkafka</code> consumer process driving an in-process <code>wasmtime</code> instance, the moment a job's work is consuming from a broker rather than answering an inbound HTTP request: the raw containerd shim has no binding for a long-lived subscription at all, so the substrate choice is forced by the capability the workload needs, independent of which trigger ends up scaling it.</p></div>

## For deeper coverage

- [KEDA HTTP add-on 0.16 — `HTTPScaledObject` reference](https://keda.sh/docs/http-add-on/0.16/reference/httpscaledobject/) — the current `spec.replicas.{min,max}` shape this chapter's `HTTPScaledObject` uses, and the `InterceptorRoute` resource it is deprecated in favor of.
- [KEDA Apache Kafka scaler reference](https://keda.sh/docs/2.21/scalers/apache-kafka/) — the `kafka` trigger fields (`bootstrapServers`, `consumerGroup`, `lagThreshold`, `offsetResetPolicy`) this chapter's `ScaledObject` uses against `cargo-handling-events` to drive `cargo-kafka-host` directly.
- [Strimzi: deploying the Cluster Operator](https://strimzi.io/docs/operators/latest/deploying) — the quickstart install method `install-strimzi.sh` follows for the pinned 1.3.0 operator and its KRaft-only, ZooKeeper-free topology.
- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023) — the autoscaling and event-driven scaling patterns this chapter's two `keda.sh` mechanisms each instantiate, both by directly patching a workload's replica count.
- Chapter 12, "gRPC with Wasm" — the host-mediated-bridge idiom this chapter's `cargo-kafka-host` reuses: a native process embeds a `wasmtime` runtime and mediates a protocol, gRPC there, a Kafka consumer group here, that no Wasm component runtime exposes natively.
- Chapter 18, "Deploying on minikube" — the raw containerd shim this chapter's HTTP half scales directly, reused unmodified alongside the native host this chapter's Kafka half adds.
- Chapter 20, "Wasm as a Sidecar" — the per-invocation statelessness finding this chapter's host design repeats: a fresh `wasmtime::Store` per Kafka message, so no domain state leaks across deliveries.
- Chapter 22, "Scaling Wasm Workloads: HPA" — the CPU-based, floor-of-one autoscaling this chapter's scale-to-zero mechanisms both extend past the point a plain HPA can reach.
