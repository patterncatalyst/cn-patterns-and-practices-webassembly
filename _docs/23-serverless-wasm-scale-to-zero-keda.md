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
- Read `examples/part5-kubernetes/kafka-handler/wit/world.wit` and `src/lib.rs` to see a wasmCloud component that exports `wasmcloud:messaging/handler@0.2.0` and imports the cargo domain's `handling` interface, and explain why this one workload needs the wasmCloud substrate instead of the raw containerd shim the rest of Part 5 runs on.
- Explain the Kafka half's central asymmetry: KEDA's `kafka` ScaledObject reads the exact same consumer-group lag the wadm spreadscaler reacts to, but only wadm can change `kafka-handler`'s instance count, because no Kubernetes Deployment exists for a `ScaledObject` to patch.
- Decide, for a given scale-to-zero workload, whether KEDA itself should own the replica count or whether KEDA's role is limited to surfacing a metric that a different control plane already owns, and recognize which of those two shapes a given `keda.sh/v1alpha1` object actually represents.

## Why this matters

Chapter 22 drove `cargo-http`'s replica count with a plain `autoscaling/v2` HorizontalPodAutoscaler: real scaling, because a Pod with `runtimeClassName: wasmtime` is still cgrouped and metered by the kubelet exactly like a `runc` Pod, so metrics-server and the HPA controller work unmodified. That HPA is bounded below by `minReplicas: 1`: a plain HPA has no notion of zero, because something has to keep answering `/metrics` for it to read. This chapter goes one step further, all the way to zero replicas, and it takes two fundamentally different KEDA mechanisms to get there, not one.

The first mechanism, the KEDA HTTP add-on driving the same raw-shim `cargo-http` Deployment, is the one case in this chapter where the sentence "KEDA scales the workload" is literally true: an `HTTPScaledObject` tells KEDA to hold cold requests at an interceptor, patch the Deployment from zero to one, wait for the new Pod to go Ready, and only then forward the held request. The second mechanism looks identical on the surface, a `ScaledObject`, a Kafka consumer-group lag metric, numbers rising and falling, but the workload underneath it is `kafka-handler`, a wasmCloud component deployed by `wadm`, not a Kubernetes Deployment, and KEDA has no object to patch. The lesson is not "here are two ways to scale a Wasm workload to zero." It is that the identical `keda.sh/v1alpha1` API surface sometimes drives the scale and sometimes only reports on it, depending entirely on which control plane actually owns the workload's lifecycle: the same substrate-ownership finding Chapter 20 draws out of a stateless provider's in-memory `HashMap`, now one layer up the stack at the replica-count level instead of the request level.

{% include excalidraw.html file="23-two-keda-models" alt="Two bands. Top, labeled KEDA DRIVES: a cold HTTP request arrives at a raw-shim Wasm Deployment scaled to zero; the KEDA HTTP add-on interceptor queues the request and asks a ScaledObject (http) with minReplicaCount 0 / maxReplicaCount N to scale the Deployment from 0 to 1, then replays the queued request once the new Pod is ready. Bottom, labeled KEDA OBSERVES / wadm OWNS: Kafka consumer-group lag exported by the broker feeds a KEDA kafka ScaledObject, which only informs: no HorizontalPodAutoscaler-shaped object is ever created for this component, because the wasmCloud wadm spreadscaler is the thing that actually reconciles kafka-handler's instance count against desired state." caption="Figure 23.1 — the same keda.sh API surface, two different relationships to the thing being scaled: KEDA drives the HTTP half's replica count directly, and only observes the Kafka half's." %}

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

<div class="callout callout--warn"><p class="callout__title">Gotcha</p><p>The original plan for this chapter assumed a top-level <code>minReplicaCount</code> field on <code>HTTPScaledObject</code>, the same name the Kafka half's plain <code>ScaledObject</code> uses. That field does not exist on the 0.16 <code>HTTPScaledObject</code> CRD. The current spec nests replica bounds under <code>spec.replicas.{min,max}</code>, verified directly against the upstream CRD (<code>kedacore/http-add-on @ v0.16.0</code>, <code>config/crd/bases/http.keda.sh_httpscaledobjects.yaml</code>) and the matching reference doc at <a href="https://keda.sh/docs/http-add-on/0.16/reference/httpscaledobject/">keda.sh/docs/http-add-on/0.16/reference/httpscaledobject</a>. <code>HTTPScaledObject</code> is also marked deprecated as of the 0.16 line, in favor of a newer <code>InterceptorRoute</code> (<code>http.keda.sh/v1beta1</code>) resource that is still shipped and fully functional in 0.16; the deprecation is a forward-migration notice rather than a removal, which is why this chapter uses the resource the house plan asked for and names the newer one here for anyone building past this chapter's pinned versions.</p></div>

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

`examples/part5-kubernetes/k8s/keda/verify-keda-http-minikube.sh` proves this sequence against a live profile: it deploys the overlay, waits for the Deployment to report zero replicas while idle, then fires one timed cold request and asserts both a `200` and the exact cargo JSON Chapters 18, 20, and 21 all return for the same tracking id. The timing comes from `curl -w '%{http_code} %{time_total}'`, so the cold-start latency is a measured wall-clock number, not an estimate.

<!-- LIVE-OUTPUT ch23 minikube HTTP cold-start: fill from k8s/evidence/<date>/04-scale-to-zero.txt and 05-cold-start.txt after the gated run (live output lands here after the cluster run) -->

There is no dedicated CRC build for this half of the chapter. OpenShift Local's Part 5 deployment runs the wasmCloud operator exclusively (Chapter 19), never a plain `RuntimeClass`-backed Deployment, so there is no `cargo-http`-shaped workload on CRC for the Custom Metrics Autoscaler (Red Hat's KEDA distribution) to drive directly the way the upstream HTTP add-on drives one on minikube. Installing the Custom Metrics Autoscaler on CRC and pointing an `HTTPScaledObject`-equivalent at a wasmCloud front-door component would reproduce the exact asymmetry the Kafka half already demonstrates on both clusters: the autoscaler installed and able to watch a metric, the wadm spreadscaler the only thing actually able to move the front door's instance count between zero and some ceiling. That shape is named here rather than built, since this chapter's CRC evidence is dedicated to the Kafka half, where the asymmetry is the whole point rather than an aside.

## Why the Kafka half needs wasmCloud, not the raw shim

Every other workload in Part 5, the plain `cargo-http` Deployment Chapter 18 proves, the interposed compositions Chapters 20 and 21 build on top of it, and the HTTP half above, speaks `wasi:http/incoming-handler` behind a fixed `:8080` listener. That is the one thing the raw containerd shim knows how to serve. Consuming messages from a Kafka topic is a different kind of capability entirely: something has to hold a long-lived consumer-group subscription, deserialize delivered records, and invoke application code once per message, independent of any inbound HTTP request. The raw shim has no binding for that at all: it is a `wasi:http` listener, not a general-purpose capability host, so a message-driven Wasm consumer cannot run on it no matter how the component itself is written.

wasmCloud's capability-provider model exists for exactly this shape. The `messaging-kafka` provider owns the Kafka subscription and the wire protocol; it invokes `wasmcloud:messaging/handler` on whatever component `wadm` links it to, once per delivered message, the identical provider-calls-component pattern Part 4's `httpserver` already uses to invoke the HTTP front door. That means the Kafka half of this chapter needs a wasmCloud lattice on minikube specifically, installed by `examples/part5-kubernetes/k8s/wasmcloud/install-wasmcloud-minikube.sh` (the same `wasmcloud-platform` Helm chart, 0.1.2, and host version, 1.9.1, that Chapter 19 already installs on CRC) alongside the raw shim that Chapters 18, 22, and this chapter's own HTTP half all still use. Within one minikube cluster, Part 5's shape is mixed by necessity: the raw shim is the substrate for request/response HTTP workloads, and wasmCloud is the substrate for messaging workloads, and nothing about that split is accidental or temporary: it is what each workload's required capability actually demands.

## The Kafka half: KEDA observes lag, wadm owns the scale

{% include excalidraw.html file="23-kafka-lag-flow" alt="A producer burst lands on a multi-partition Kafka topic, raising consumer-group lag. Two independent readers watch the same lag signal: the KEDA kafka ScaledObject reads it and labels itself advisory only, with no HorizontalPodAutoscaler-shaped object created as a result; the messaging-kafka capability provider actually consumes from the topic and invokes the kafka-handler component over wRPC, and wadm's spreadscaler is the loop that raises kafka-handler's instance count as throughput rises and lowers it again once the burst drains and lag returns to zero." caption="Figure 23.2 — two readers of one topic: KEDA's lag reading never leaves the advisory column; wadm's spreadscaler is the only loop that changes kafka-handler's actual instance count." %}

`examples/part5-kubernetes/kafka-handler/wit/world.wit` is the whole contract for the component this half scales:

{% raw %}
```wit
package patterncatalyst:cargo-kafka-handler@0.1.0;

world cargo-kafka-handler {
    export wasmcloud:messaging/types@0.2.0;
    export wasmcloud:messaging/handler@0.2.0;

    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;
}
```
{% endraw %}

`wasmcloud:messaging@0.2.0` is vendored verbatim under `wit/deps/messaging`, the same approach Part 3's `http-rust` already uses for `wasi:http`, because `cargo-component` never fetches WIT packages over the network: every non-contract package a local world references has to be present on disk. `patterncatalyst:cargo` is pulled in the same way Chapters 20 and 21's interposers pull it, a path dependency to the repository contract, never a copy and never an edit. The component exports `handler` (the callback the `messaging-kafka` provider invokes) and the `types` interface the `broker-message` record it depends on lives in, following the house convention of always listing a types-only interface a world's functional interfaces depend on. It imports only `handling`, not the full cargo package, because recording a handling event is the one write this component makes against the domain.

`src/lib.rs` keeps the message format small: a pipe-delimited record, `CARGO_ID|EVENT_TYPE|UNLOCODE|VOYAGE_ID|RECORDED_AT`, parsed without a JSON crate, matching the zero-extra-dependency convention Chapter 20's `sidecar-filter` and Chapter 21's `adapter` both already follow. The `Guest` implementation is a straightforward parse-validate-call:

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

Every malformed or unrecognized message is a real `Err`, never a silent drop: a bad event type, missing fields, or invalid UTF-8 all surface as a rejected `result<_, string>` the `messaging-kafka` provider's own delivery semantics have to deal with, rather than being swallowed inside the handler. The location record defaults its `name` and `country` to the UN/LOCODE itself: the Kafka wire format in this demo carries only the code, not a full location lookup, and the cargo provider stays authoritative for any display-quality data. This handler's job is to record that an event happened, not to enrich it.

`examples/part5-kubernetes/k8s/wasmcloud/wadm-kafka.yaml` wires three pieces into one lattice application: the `messaging-kafka` capability (the actual Kafka consumer), `kafka-handler` (the component above), and the Part 2 cargo provider reused verbatim:

{% raw %}
```yaml
    - name: kafka-handler
      type: component
      properties:
        image: __HANDLER_REF__
      traits:
        - type: spreadscaler
          properties:
            instances: 1
        - type: link
          properties:
            target: cargo-provider-k
            namespace: patterncatalyst
            package: cargo
            interfaces:
              - handling

    - name: messaging-kafka
      type: capability
      properties:
        image: ghcr.io/wasmcloud/messaging-kafka:6c67eb2
      traits:
        - type: link
          properties:
            target: kafka-handler
            namespace: wasmcloud
            package: messaging
            interfaces:
              - handler
            source_config:
              - name: cargo-handling-events-consumer
                properties:
                  hosts: cargo-kafka-kafka-bootstrap.kafka.svc:9092
                  topic: cargo-handling-events
                  consumer_group: kafka-handler
```
{% endraw %}

`messaging-kafka` ships no semver release upstream at all, only commit-SHA builds aliased `canary`; this manifest pins the exact commit SHA (`6c67eb2`, confirmed against the ghcr package page at the time of this survey) rather than the floating alias, so a re-run never silently picks up a different build. Both that tag and the exact configuration key names under `source_config.properties` (`hosts`/`topic`/`consumer_group`) are marked TBD-confirm-at-kickoff in the manifest itself: upstream has no dedicated reference page for `messaging-kafka`'s config shape at the time of this writing, so the live run needs to confirm them against `wash inspect` or the provider's own source before trusting this exact key set. The `spreadscaler` trait on `kafka-handler` is the line that matters most for this chapter's argument: `wadm` continuously reconciles the lattice back to whatever number that trait says, regardless of what any `ScaledObject` observes.

The broker underneath all of this is Strimzi 1.3.0, in single-node KRaft mode (no ZooKeeper; Strimzi dropped it entirely by this release line). The chapter's original plan assumed Apache Kafka 4.1.0; verified against the 1.3.0 release's own example manifests, that operator version supports only Kafka 4.2.0 through 4.3.1, so `examples/part5-kubernetes/k8s/kafka/base/kafka.yaml` pins the exact pairing Strimzi ships in its own example:

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

Six partitions is a chosen ceiling, not an arbitrary number: both KEDA's `kafka` scaler and wadm's spreadscaler can only ever drive `kafka-handler`'s replica count up to the topic's partition count, because one consumer-group member can own at most one partition at a time. A single-partition topic would cap this demo at a 0-versus-1 toggle and never show a real multi-instance scale-out under a burst.

`examples/part5-kubernetes/k8s/keda/base/kafka-scaledobject.yaml` is the object that reads lag on that topic, and its shape is worth reading closely for what it does not do:

{% raw %}
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: kafka-handler-lag
  namespace: kafka
  labels:
    app.kubernetes.io/name: kafka-handler
    app.kubernetes.io/part-of: part5-kubernetes
spec:
  scaleTargetRef:
    name: kafka-handler
    kind: Deployment
  minReplicaCount: 0
  maxReplicaCount: 6
  cooldownPeriod: 30
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: cargo-kafka-kafka-bootstrap.kafka.svc:9092
        consumerGroup: kafka-handler
        topic: cargo-handling-events
        lagThreshold: "5"
        offsetResetPolicy: earliest
```
{% endraw %}

`scaleTargetRef` names `kafka-handler` as a `Deployment`, but no such Deployment exists anywhere in this cluster: `kafka-handler` is a wasmCloud component wadm deploys, and a `ScaledObject` can only ever patch `spec.replicas` on a Deployment, StatefulSet, or similar Kubernetes-native object. That name is kept purely as self-documentation of what this trigger would target if `kafka-handler` were ever ported to a plain in-cluster consumer instead of a wasmCloud component; pointing it at a resource that does not exist and then pretending the resulting `ScaledObject` is what drives the scale would misrepresent what this object actually does. No `TriggerAuthentication` is attached either, because the single internal `plain` listener on `kafka.yaml` carries no SASL or mTLS: a production broker with either would add one, referenced via `authenticationRef`, but this demo cluster's listener does not need it.

`examples/part5-kubernetes/k8s/kafka/producer-burst.sh` is what creates the lag this `ScaledObject` reads. It runs entirely in-cluster: `kubectl run` launches a disposable Strimzi client Pod (`quay.io/strimzi/kafka:0.47.0-kafka-4.3.1`, the same distribution the broker itself ships, reused rather than pulling a separate client image), and `kubectl exec` pipes a batch of pipe-delimited messages into `kafka-console-producer.sh` against the bootstrap service's cluster DNS name: no port-forward, no NodePort, the same in-cluster-exec convention Chapter 30 of the companion Python modernization project and every Part 5 verify script in this book already follow. Sixty messages round-robin across six distinct keys by default, so the partitioner spreads the burst across all six partitions instead of landing it entirely on one, which would cap the demo's visible scale-out at a single instance no matter how large the burst was.

The full sequence `examples/part5-kubernetes/k8s/keda/verify-keda-kafka-minikube.sh` proves is: the burst lands, consumer-group lag is confirmed to have risen by running `kafka-consumer-groups.sh --describe` through `kubectl exec` (never assumed from the producer's own exit code), the KEDA `ScaledObject`'s status reflects that lag, `kafka-handler`'s wadm-owned `spreadscaler.properties.instances` is raised explicitly (a production system would wire this step to the same lag signal through automation; wadm has no native Kafka-lag trigger of its own as of this survey, so the bump is done by hand here rather than through a scaler that does not exist), the burst drains as the additional instances consume it, and lag returns toward zero.

<!-- LIVE-OUTPUT ch23 minikube Kafka lag/drain timeline: fill from k8s/evidence/<date>/23-producer-burst-lag.txt, 24-scaledobject.txt, and 25-drain.txt after the gated run (live output lands here after the cluster run) -->

CRC runs the identical narrative with two substitutions: AMQ Streams in place of upstream Strimzi for the Kafka cluster (reusing the same `Kafka`/`KafkaNodePool`/`KafkaTopic` shapes), and the Custom Metrics Autoscaler, Red Hat's supported KEDA distribution, installed through a pinned-CSV OperatorHub subscription with Manual approval rather than a Helm chart. `examples/part5-kubernetes/openshift/wadm-kafka.yaml` deploys the same three-piece lattice application with the identical `spreadscaler` and `link` traits as the minikube manifest. The teaching point is sharper on CRC than on minikube, not softer: Chapter 19 never runs a raw-shim Deployment on OpenShift Local at all, so there is no Kubernetes-native workload of any kind for a Custom-Metrics-Autoscaler `ScaledObject` to patch here; the observational role this chapter's `kafka` scaler plays on minikube is the *only* role any K8s-shaped autoscaler could play on CRC's Part 5 deployment, for any workload. The asymmetry named in the Decision below is not a minikube quirk; CRC makes the same point with no alternative path available at all.

<!-- LIVE-OUTPUT ch23 CRC Kafka lag/drain timeline: fill from openshift/evidence/<date>/ after the gated run (live output lands here after the cluster run) -->

Every example in this chapter is built and composed correctly, and the build-time proofs (the handler compiling and exporting the right interfaces, the manifests applying their resources without error) are solid; the cluster run that produces real cold-start and lag-drain numbers is pending live verification, which is why the two timelines above are placeholders rather than numbers. No latency or lag figure in this chapter is invented to fill that gap.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Let KEDA itself own the replica count when the workload it is scaling is a resource the Kubernetes API actually lets a <code>ScaledObject</code> or <code>HTTPScaledObject</code> patch: a Deployment, a StatefulSet, anything with a <code>spec.replicas</code> field a controller can write. The HTTP add-on's interceptor-and-patch mechanism against the raw-shim <code>cargo-http</code> Deployment is exactly this case, and it is the only place in this chapter where "KEDA scales it" is literally correct. Limit a <code>ScaledObject</code> to an observational role the moment the workload it names is managed by a different control plane (a wasmCloud component reconciled by <code>wadm</code>'s own <code>spreadscaler</code> trait, as <code>kafka-handler</code> is on both minikube and CRC), and say so explicitly in the manifest rather than pointing <code>scaleTargetRef</code> at a Deployment that does not exist and letting a reader assume it does the scaling. Reach for a messaging-capable runtime like wasmCloud, instead of the raw containerd shim, the moment a workload's job is consuming from a broker rather than answering an inbound HTTP request: the shim has no capability binding for that at all, no matter how the component is written, so the substrate choice is forced by the workload's own capability requirement, not a stylistic preference. When two control planes read the same metric, as KEDA and wadm both read the same consumer-group lag here, name which one actually owns the scale and let the other one be exactly what it is: a second, independent reader of the same number, useful for visibility, irrelevant to what the instance count will actually do next.</p></div>

## For deeper coverage

- [KEDA HTTP add-on 0.16 — `HTTPScaledObject` reference](https://keda.sh/docs/http-add-on/0.16/reference/httpscaledobject/) — the current `spec.replicas.{min,max}` shape this chapter's `HTTPScaledObject` uses, and the `InterceptorRoute` resource it is deprecated in favor of.
- [KEDA Apache Kafka scaler reference](https://keda.sh/docs/2.21/scalers/apache-kafka/) — the `kafka` trigger fields (`bootstrapServers`, `consumerGroup`, `lagThreshold`, `offsetResetPolicy`) this chapter's observational `ScaledObject` uses against `cargo-handling-events`.
- [wasmCloud Applications and the `wadm` model: spreadscaler](https://wasmcloud.com/docs/ecosystem/wadm/model/) — the trait that actually owns `kafka-handler`'s instance count on both clusters, continuously reconciled independent of anything KEDA observes.
- [Strimzi: deploying the Cluster Operator](https://strimzi.io/docs/operators/latest/deploying) — the quickstart install method `install-strimzi.sh` follows for the pinned 1.3.0 operator and its KRaft-only, ZooKeeper-free topology.
- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023) — the autoscaling and event-driven scaling patterns this chapter's two `keda.sh` mechanisms each instantiate, one by directly patching a workload and one by only informing a separate owner.
- Chapter 18, "Deploying on minikube" and Chapter 19, "Deploying on OpenShift Local (CRC)" — the raw containerd shim this chapter's HTTP half scales directly, and the wasmCloud operator install this chapter's Kafka half on CRC reuses unmodified.
- Chapter 20, "Wasm as a Sidecar" — the per-invocation statelessness and substrate-ownership findings this chapter's KEDA-observes/wadm-owns asymmetry restates one layer up the stack, at the replica-count level instead of the request level.
- Chapter 22, "Scaling Wasm Workloads: HPA" — the CPU-based, floor-of-one autoscaling this chapter's scale-to-zero mechanisms both extend past the point a plain HPA can reach.
