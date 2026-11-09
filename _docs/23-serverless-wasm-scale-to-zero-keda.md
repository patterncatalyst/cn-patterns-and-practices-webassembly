---
title: "Serverless Wasm: Scale-to-Zero with KEDA"
order: 23
part: "Deploying to Kubernetes"
description: "Scale a Wasm workload to zero with KEDA's HTTP add-on and its Kafka scaler, and see where a component's cold start beats a container's."
duration: "20 min read"
---

## Learning objectives

By the end of this chapter you can:

- Write an `HTTPScaledObject` with replica bounds under `spec.replicas.{min,max}` and route an Ingress to it through an `ExternalName` interceptor Service.
- Trace a cold request: Deployment at zero, interceptor holding the request, scale from 0 to 1, response once the Pod is Ready.
- Explain why a message-driven component needs a native host that embeds the runtime, not the containerd shim's fixed `wasi:http` listener.
- Scale that host on consumer-group lag with a `kafka` `ScaledObject`, capped at the topic's partition count.
- Choose between the two triggers by the signal that should drive the replica count.

## Why this matters

A plain HorizontalPodAutoscaler never reaches zero: it reads `/metrics` from a running Pod, so it stops at `minReplicas: 1`. KEDA scales a Deployment to zero and back by patching `spec.replicas` itself. A Pod with `runtimeClassName: wasmtime` is still cgrouped and metered like a `runc` Pod, so KEDA drives it without changes.

Two triggers reach zero the same way:

| | HTTP add-on | Kafka scaler |
| --- | --- | --- |
| Signal | request concurrency | consumer-group lag |
| KEDA object | `HTTPScaledObject` | `ScaledObject` with a `kafka` trigger |
| Target | raw-shim `cargo-http` Deployment | native `cargo-kafka-host` Deployment |
| Workload | answers an inbound HTTP request | consumes records and calls a Wasm handler per message |

{% include excalidraw.html file="23-two-keda-models" alt="Two bands labeled KEDA drives. Left, HTTP: a cold request reaches a Wasm Deployment at zero replicas; the KEDA HTTP add-on interceptor queues it, an HTTPScaledObject scales the Deployment from 0 to 1, and the interceptor replays the request once the Pod is ready. Right, Kafka: consumer-group lag on cargo-handling-events feeds a kafka ScaledObject with lagThreshold 5, which scales cargo-kafka-host from 0 to N; the host runs an rdkafka consumer and a wasmtime runtime, calls the handler per record, commits the offset, and scales back to 0 as lag drains." caption="Figure 23.1: Two triggers, one owner. KEDA patches a Deployment's replica count in both halves: request concurrency on the left, consumer-group lag on the right." %}

## The HTTP half: KEDA drives a raw-shim Deployment to zero

`install-keda.sh` installs two pinned Helm charts into the `keda` namespace on minikube: KEDA core 2.21.0 and the HTTP add-on 0.16.0, whose chart requires core 2.21 or later. `ingress-nginx` is already there for the plain `cargo-http` stack. This `HTTPScaledObject` turns that unmodified Deployment into a scale-to-zero workload:

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
  # Shortened from the add-on's default (hundreds of seconds): a Wasm
  # component has no JVM-style warm-up (containerd-shim-wasmtime starts
  # serving within milliseconds of the Pod going Ready, the same point the HPA's
  # hpa.yaml makes about scaleDown.stabilizationWindowSeconds), so there is no
  # reason to wait minutes of idleness before scaling back to zero.
  scaledownPeriod: 30
```
{% endraw %}

A single in-flight request (`concurrency.targetValue: 1`) triggers scale-out, so one `curl` shows the mechanism without a load tool. `scaledownPeriod: 30` is far below the add-on's default of several minutes. A component has no JVM-style warm-up to protect: `containerd-shim-wasmtime` serves within milliseconds of the Pod going Ready, so there's no reason to wait out a long idle period.

> **Note**
>
> On the 0.16 CRD, replica bounds nest under `spec.replicas.{min,max}`, not a top-level `minReplicaCount`, which is the field the Kafka half's plain `ScaledObject` uses ([reference](https://keda.sh/docs/http-add-on/0.16/reference/httpscaledobject/)). `HTTPScaledObject` is deprecated in the 0.16 line in favor of `InterceptorRoute` (`http.keda.sh/v1beta1`). It still ships and works; use the newer resource when you build past these pins.

### Routing through the interceptor

An Ingress backend must be a Service in the Ingress's own namespace, but the interceptor proxy Service lives in `keda`. A same-namespace `ExternalName` Service bridges the gap:

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

The kustomization points the base Ingress at that Service and adds the annotation ingress-nginx needs to proxy to an `ExternalName` target:

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

With `service-upstream: "true"`, ingress-nginx proxies to the Service name instead of resolving Endpoints. A direct Ingress route to `cargo-http` would have nothing to send traffic to at zero replicas because the Service has no Endpoints. Scale-to-zero and a direct route are mutually exclusive, so the interceptor must sit in the path:

```
curl -> cargo.<minikube-ip>.nip.io  (ingress-nginx)
     -> keda-interceptor-proxy (ExternalName -> keda namespace)
     -> keda-add-ons-http-interceptor-proxy  (holds the request, asks KEDA to scale 0 -> 1, waits for Ready)
     -> Service cargo-http:8080 -> Pod (runtimeClassName: wasmtime)
     -> containerd-shim-wasmtime -> app.wasm
```

The recorded cold request on minikube:

```
$ curl -sS -w "%{http_code} %{time_total}" http://cargo.192.168.49.2.nip.io/cargo/CARGO-USNYC-DEHAM
http_code=200 cold_start_seconds=4.414011
```

That 4.4 seconds covers the interceptor hold, Kubernetes scheduling, Pod start and component instantiation. Scheduling and Pod startup dominate; the component itself starts in well under a second under the shim. A container pays the same scheduling cost plus an image pull on a cold node and its runtime's startup (JVM class loading, Python imports). A component skips both, so the only cold-start cost left is what Kubernetes charges for any Pod.

CRC has no counterpart for this half. Its deployment runs the wasmCloud operator, so there is no `RuntimeClass`-backed Deployment for the Custom Metrics Autoscaler (Red Hat's KEDA) to patch.

## Why the Kafka half needs a host that embeds the runtime

Every other workload here speaks `wasi:http/incoming-handler` behind a fixed `:8080` listener, which is all the raw containerd shim serves. Consuming from Kafka needs something that holds a long-lived consumer-group subscription, receives records and invokes application code once per message. The shim has no binding for that, so the component can't run on it however it's written.

The fix is a native host that owns what a component can't. `cargo-kafka-host` is a plain Rust binary that joins `cargo-handling-events` as a consumer group with `rdkafka` and, for each message, calls the `handle-message` export of `kafka-app.wasm` on an embedded `wasmtime` runtime. It commits the offset only after the call returns. It's an ordinary OCI container (no `runtimeClassName`), deployed as a plain Deployment, which is exactly what a `ScaledObject` can patch.

`kafka-app.wasm` is the `kafka-handler` component plugged into the cargo provider with `wac plug`, the same compile-time composition the sidecar filter uses. The composite's only unresolved import is WASI, so the host never satisfies a `patterncatalyst:cargo` import itself.

{% include excalidraw.html file="23-kafka-lag-flow" alt="A producer burst lands on a six-partition Kafka topic and raises consumer-group lag. The kafka ScaledObject reads that lag and scales cargo-kafka-host from 0 to N. Each host joins the consumer group with rdkafka, drives an embedded wasmtime runtime against kafka-app.wasm's handle-message export per message, then commits the offset. As the instances drain the backlog, lag falls and KEDA scales cargo-kafka-host back to zero." caption="Figure 23.2: KEDA reads consumer-group lag and scales cargo-kafka-host directly; the host embeds the Wasm runtime itself." %}

## The handler component

The handler's world (package `patterncatalyst:cargo-kafka-handler@0.1.0`) exports the messaging interfaces and imports the cargo domain:

{% raw %}
```wit
world cargo-kafka-handler {
    export wasmcloud:messaging/types@0.2.0;
    export wasmcloud:messaging/handler@0.2.0;

    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;
}
```
{% endraw %}

`wasmcloud:messaging@0.2.0` is vendored under `wit/deps/messaging`, because `cargo-component` never fetches WIT over the network. `patterncatalyst:cargo` is a path dependency to the repository contract. The component exports `types` along with `handler` because the `broker-message` record lives there. It imports `booking` and `handling` because a handling event records against an existing cargo.

The message format is a pipe-delimited record, `CARGO_ID|EVENT_TYPE|UNLOCODE|VOYAGE_ID|RECORDED_AT`, parsed without a JSON crate:

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

        // Demo simplification: the Kafka wire format carries only the
        // UN/LOCODE, not a full location lookup: name/country both default to
        // the code itself. The cargo provider (Part 2) is authoritative for any
        // display-quality location data; this handler's job is to record that
        // a handling event happened, not to enrich it.
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

Bad UTF-8, missing fields, an empty cargo id or an unknown event type all return `Err` instead of being swallowed. The location's `name` and `country` default to the UN/LOCODE, since the wire format carries only the code and the cargo provider stays authoritative for display data.

`register-handling-event` needs an existing cargo, so `ensure_cargo_booked` runs first. It looks the cargo up and, if the domain has none, derives the route from the `CARGO-<ORIGIN>-<DEST>` id and books it:

{% raw %}
```rust
fn ensure_cargo_booked(cargo_id: &str, recorded_at: &str) -> Result<(), String> {
    match booking::get_cargo(cargo_id) {
        Ok(_) => Ok(()),
        Err(CargoError::NotFound(_)) => {
            let (origin, destination) = locations_from_cargo_id(cargo_id).ok_or_else(|| {
                format!(
                    "cannot derive origin/destination from cargo-id '{cargo_id}': \
                     expected CARGO-<ORIGIN>-<DEST>"
                )
            })?;
            let spec = RouteSpec {
                origin: Location {
                    unlocode: origin.to_string(),
                    name: origin.to_string(),
                    country: origin.to_string(),
                },
                destination: Location {
                    unlocode: destination.to_string(),
                    name: destination.to_string(),
                    country: destination.to_string(),
                },
                arrival_deadline: recorded_at.to_string(),
            };
            booking::book_cargo(&spec, DEFAULT_WEIGHT_KG)
                .map(|_| ())
                .map_err(|e| format!("book-cargo failed for cargo_id={cargo_id}: {e:?}"))
        }
        Err(e) => Err(format!("get-cargo failed for cargo_id={cargo_id}: {e:?}")),
    }
}
```
{% endraw %}

Because booking is keyed on a lookup, each invocation is self-contained. That matters because the host creates a fresh component instance for every message.

## The native host

The host's Kafka dependency is pinned exactly because its build compiles a native library:

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

`cmake-build` compiles `librdkafka` from source (2.12.1 through `rdkafka-sys` 4.10.0 in the committed lockfile), so the lockfile ships with the crate. `ssl`, `sasl` and `gssapi` stay off because the broker's only listener is plaintext; enabling them would add build time and attack surface for nothing. The synchronous `BaseConsumer` avoids pulling in an async executor, and `signal-hook` gives a clean shutdown on SIGINT and SIGTERM, so the poll loop exits promptly when KEDA scales the host down.

The host's own WIT world (package `patterncatalyst:cargo-kafka-host@0.1.0`) is export-only:

{% raw %}
```wit
world kafka-host {
    export wasmcloud:messaging/types@0.2.0;
    export wasmcloud:messaging/handler@0.2.0;
}
```
{% endraw %}

It doesn't reuse the handler's world, because generating host bindings for that world's `patterncatalyst:cargo` imports would force the crate to stub them for nothing. The composite already satisfies those imports internally.

The host loads the engine and the composite once and shares them, but gives each message a fresh `Store`, so no state leaks between deliveries:

{% raw %}
```rust
    /// Runs one delivered message through a fresh instance of `kafka-app.wasm`.
    fn handle(&self, subject: String, body: Vec<u8>) -> Result<Result<(), String>> {
        let mut store = self.new_store();
        let world = self.instantiate(&mut store)?;
        let handler = world.wasmcloud_messaging_handler();
        let msg = BrokerMessage {
            subject,
            body,
            reply_to: None,
        };
        handler
            .call_handle_message(&mut store, &msg)
            .wc("call handle-message")
    }
```
{% endraw %}

The poll loop commits after the handler returns, and commits past a handler error:

{% raw %}
```rust
        let outcome = host.handle(subject, body);

        // At-least-once, drain-on-poison semantics: a handler error means this
        // message is malformed or unprocessable, not that the broker or the
        // host is unhealthy. Committing past it anyway keeps the consumer
        // group draining instead of wedging on a single bad message forever;
        // a dead-letter topic would be the production-grade follow-up, not
        // retry-without-bound. A host-level failure (the `Err` wasmtime arm)
```
{% endraw %}

That's at-least-once delivery with drain-on-poison semantics. A rejected message is malformed or unprocessable, not a sign of an unhealthy broker, and retrying it forever would wedge the group. A dead-letter topic is the production follow-up.

## The broker and the ScaledObject

The broker is Strimzi 1.3.0 in single-node KRaft mode, with no ZooKeeper. It supports Kafka 4.2.0 through 4.3.1, and `kafka.yaml` pins the pairing Strimzi ships in its own examples:

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

Replication and ISR settings are forced to 1 because the defaults assume three brokers; a single node would never finish bootstrapping its internal topics. The topic has six partitions, not Strimzi's single-partition default:

{% raw %}
```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: cargo-handling-events
  namespace: kafka
  labels:
    strimzi.io/cluster: cargo-kafka
    app.kubernetes.io/part-of: part5-kubernetes
spec:
  partitions: 6
  replicas: 1
```
{% endraw %}

Six is the ceiling for scale-out. One consumer-group member owns at most one partition, so a single-partition topic would cap the demo at a 0-or-1 toggle. The `ScaledObject` reads lag on that topic and patches the host Deployment:

{% raw %}
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: cargo-kafka-host
  namespace: kafka
  labels:
    app: cargo-kafka-host
    app.kubernetes.io/part-of: part5-kubernetes
spec:
  scaleTargetRef:
    name: cargo-kafka-host
    kind: Deployment
  minReplicaCount: 0
  maxReplicaCount: 6 # capped at the topic's partition count (kafkatopic.yaml)
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

`scaleTargetRef` names a plain Deployment with a real `spec.replicas`, the same kind of object the HTTP half patches, so no second control plane sits in between. With no committed offset, `offsetResetPolicy: earliest` makes the scaler treat the whole backlog as lag. No `TriggerAuthentication` is attached because the `plain` listener has no SASL or mTLS; a production broker with either adds one through `authenticationRef`.

> **Decision**
>
> Let KEDA own the replica count whenever the target has a real `spec.replicas` field, as both Deployments here do. The trigger follows the work: request concurrency for a service that answers HTTP, consumer-group lag for a process that consumes from a broker. The substrate follows the capability: a workload that consumes from a broker needs a host that embeds the runtime, because the raw shim serves only `wasi:http`.

> **🤖 Explore with your agent**
>
> "In `examples/part5-kubernetes`, `cargo-kafka-host` is scaled by `k8s/keda/base/kafka-scaledobject.yaml` on lag for the topic in `k8s/kafka/base/kafkatopic.yaml`. Raise the topic to 12 partitions and set `maxReplicaCount` to match, using the rule that one consumer-group member owns at most one partition. Then say what happens to the extra hosts if `maxReplicaCount` stays at 6 and if it goes to 20, and whether `k8s/kafka/producer-burst.sh`, which spreads its burst over six keys, can still load all 12 partitions."
>
> Check: `git diff` touches only those two files and shows `partitions: 12` and `maxReplicaCount: 12`.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s/keda && ./verify-keda-http-minikube.sh
cd examples/part5-kubernetes/k8s/keda && ./verify-keda-kafka-minikube.sh
```

The HTTP script installs KEDA and the add-on, deploys the overlay, waits for zero replicas, then sends one timed cold request through ingress-nginx and expects a 200 with the cargo JSON. The Kafka script installs Strimzi and sends a burst of 120 messages with `k8s/kafka/producer-burst.sh` (60 by default when run alone), which runs entirely in cluster: `kubectl exec` into a disposable Strimzi client Pod reusing the broker's own image, no port-forward and no NodePort. The messages round-robin across six distinct keys so the partitioner spreads them over all six partitions; a burst on one key lands on one partition and caps the visible scale-out at one host. It confirms the backlog from the topic's end offsets, then expects `cargo-kafka-host` to scale from zero toward six and back to zero as lag drains. Each prints `PASS`.

The recorded Kafka run on minikube: idle at `0/0`; a burst of 120 messages moved the end offset from 120 to 240; KEDA scaled the host to a peak of 4 replicas; every record was handled; the group's committed offset caught the log end (240/240, lag 0); KEDA scaled back to `0/0` after the cooldown. Evidence is under `k8s/keda/evidence/`. The CRC script `openshift/verify-keda-kafka-crc.sh` is not yet wired to a live `wadm` app.

Experiments:

- Point the Ingress straight at `cargo-http` and a request at zero replicas has no Endpoint to reach.
- Set `maxReplicaCount` above the partition count and the extra hosts sit idle: a member owns at most one partition.
- Send a body with fewer than five pipe-delimited fields and the handler returns `Err`; the host logs it and commits past it.

## For deeper coverage

- [KEDA HTTP add-on 0.16: `HTTPScaledObject` reference](https://keda.sh/docs/http-add-on/0.16/reference/httpscaledobject/): the `spec.replicas.{min,max}` shape and the `InterceptorRoute` replacement.
- [KEDA Apache Kafka scaler reference](https://keda.sh/docs/2.21/scalers/apache-kafka/): the `kafka` trigger fields (`bootstrapServers`, `consumerGroup`, `lagThreshold`, `offsetResetPolicy`).
- [Strimzi: deploying the Cluster Operator](https://strimzi.io/docs/operators/latest/deploying): the install method `install-strimzi.sh` follows.
- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the autoscaling and event-driven scaling patterns both KEDA objects instantiate.
- gRPC with Wasm: the same host-mediated bridge, where a native process embeds `wasmtime` and mediates a protocol no component runtime exposes.
- Deploying on minikube: the raw containerd shim the HTTP half scales.
- Wasm as a sidecar: the fresh `Store` per invocation that the host repeats for each Kafka message.
- Scaling Wasm workloads: HPA: the floor-of-one autoscaling these scale-to-zero mechanisms extend.
