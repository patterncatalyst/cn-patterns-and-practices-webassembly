---
title: "Observability On-Cluster"
order: 24
part: "Deploying to Kubernetes"
description: "On a cluster, the substrate emits the telemetry for a Wasm component: the containerd shim exports traces on minikube, the wasmCloud host exports traces, metrics and logs on CRC. The guest emits none."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why a guest component emits no span, metric or log, and name what each substrate emits instead.
- Turn on `containerd-shim-wasmtime` trace export with a systemd drop-in, and say why the endpoint is a ClusterIP and why the script must run before the app is deployed.
- Run a rootless OpenTelemetry Collector under `restricted-v2` with no fixed UID and point the wasmCloud host at it.
- Query each backend with `kubectl exec` or `oc logs`, without a port-forward or a Grafana UI.
- Choose between the shim's trace and the host's trace, metric and log for a given operational question.

## Why this matters

Nothing in the pinned toolchain lets the cargo component's own Rust code open a span, record a metric or write a structured log through an OpenTelemetry SDK. `wasi-otel`, the proposal that would give a guest that capability, is an RC-only draft. It isn't part of `wasm32-wasip1`, the WASI target the examples build for, and no pinned runtime implements it. Every signal on a cluster comes from the substrate the component runs inside: the shim that manages the Pod on minikube, or the wasmCloud host that dispatches RPC calls to the component on CRC.

That makes on-cluster observability a different question from the one a Java or Python operator asks. A JVM takes an agent flag and starts emitting spans. A component can't, because the proposal that would carry a span out of guest code doesn't exist in any runtime here. What the platform can tell you differs by substrate, and the simpler substrate is the richer one by default: the raw shim has emitted OTel traces since runwasi v0.5.0 with no flag. The wasmCloud host offers the deeper signal once wired up, because it already mediates every RPC call between components.

{% include excalidraw.html file="24-otel-two-emitters-pipeline" alt="Two horizontal bands. Top, minikube: containerd-shim-wasmtime emits shim-level OTel traces, one span per invocation, into otel-lgtm (Grafana, Tempo, Loki and Prometheus in one Pod). Bottom, CRC: the wasmCloud host emits native traces, metrics and logs into a rootless OpenTelemetry Collector compatible with the restricted-v2 SCC, whose debug and file exporters are read with oc logs and oc exec. A caption under both bands says the two clusters have separate backends." caption="Figure 24.1: Shim-level traces only on minikube, into otel-lgtm, versus host-native traces, metrics and logs on CRC, into a rootless restricted-v2 collector. There is no otel-lgtm on CRC." %}

## Signal provenance

The two substrates differ for each of the three signals:

{% include excalidraw.html file="24-signal-provenance" alt="A three-row by two-column matrix: traces, metrics, logs, for minikube (shim level) and CRC (host level). Minikube: a span per invocation emitted by the shim; no metrics from the shim, only cgroup CPU through metrics-server; logs are container stdout and stderr captured by the kubelet, not OTel. CRC: host and provider spans with wRPC call boundaries; host-native metrics such as instance counts and invocation rates; host-native structured logs through the OTel log pipeline. A header notes that the guest wasi-otel proposal is not used." caption="Figure 24.2: On minikube only traces are shim-emitted OTel; metrics and logs exist but travel through metrics-server and the kubelet. On CRC all three signals are host-native OTel." %}

The minikube column is narrower than the evidence suggests. The verify script gets answers from Prometheus and Loki as well as Tempo, but those describe the `otel-lgtm` stack itself, the collector's count of accepted spans and the bundled processes' own logs, not the shim or the Wasm Pod. `containerd-shim-wasmtime` emits spans and nothing else. CPU and memory still come from `metrics-server`, and component stdout and stderr still land in the kubelet's container logs. Three green checks mean one signal about the Wasm Pod and two about the backend.

On CRC the `spec.observability` block of the wasmCloud host turns on traces, metrics and logs together, because the host is the one process positioned to see every RPC dispatch, not just one container's lifecycle.

## minikube: the containerd shim emits traces by default

`k8s/observability/base/otel-lgtm.yaml` is the OTLP sink: one Pod running `grafana/otel-lgtm`, which bundles an OpenTelemetry Collector in front of Tempo, Prometheus and Loki, with Grafana wired to all three. It's pulled from Docker Hub rather than loaded with `minikube image load`, since it's a public image. Readiness is Grafana's `/` on port 3000, because the bundle's supervisor starts Grafana last:

{% raw %}
```yaml
        - name: otel-lgtm
          image: grafana/otel-lgtm:0.33.1
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
            - name: grafana
              containerPort: 3000
            - name: tempo
              containerPort: 3200
            - name: prometheus
              containerPort: 9090
            - name: loki
              containerPort: 3100
          # The all-in-one stack (Collector + Tempo + Prometheus + Loki +
          # Grafana, run under a supervisor by run-lgtm.sh) takes real wall time
          # to come up; Grafana serving "/" is the last thing to start, so it is
          # the honest readiness signal for the whole stack.
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 5
            failureThreshold: 30
```
{% endraw %}

The minikube overlay only lowers the container's limits from 2 CPU and 3Gi to 1 CPU and 2Gi to fit a default VM.

A sink with nothing pointed at it receives nothing. No shim flag, Pod annotation or Kubernetes object enables the shim's export. The shim is a child of containerd and inherits its environment, so the standard `OTEL_EXPORTER_OTLP_*` variables in containerd's own environment are the only switch. That's a node-level change, so `enable-shim-otel.sh` writes a systemd drop-in on the minikube VM:

{% raw %}
```bash
OTEL_ENDPOINT="http://${OTEL_LGTM_IP}:4318"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}"
OTEL_PROTOCOL="${OTEL_PROTOCOL:-http/protobuf}"
```
{% endraw %}

{% raw %}
```bash
NEW_CONTENT='[Service]
Environment="OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_ENDPOINT}"
Environment="OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}"
Environment="OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_PROTOCOL}"
'
```
{% endraw %}

The endpoint is a ClusterIP, not a DNS name. Containerd runs in the node's host network namespace, outside any Pod, so it has no cluster DNS resolver and can't resolve `otel-lgtm.<namespace>.svc.cluster.local`. It can reach a ClusterIP, because on a single-node cluster kube-proxy's NAT rules for every Service live in that same namespace. The script resolves the ClusterIP once with `kubectl get svc` and bakes it into the drop-in, so recreating the Service means re-running the script. The technique is specific to a single node; on a multi-node cluster the resolve-once approach would have to be redone per node.

> **Note**
>
> Restarting containerd bounces every Pod on the node. `enable-shim-otel.sh` must run before the `cargo-http` overlay is applied, never after. A shim that's already running keeps the environment it started with; only a shim spawned after `systemctl restart containerd` inherits the new `OTEL_EXPORTER_OTLP_*` values. The verify script deploys the observability stack, runs the script, then redeploys the app and deletes the existing Pod so its replacement starts behind a fresh shim.

The verify script then sends five successful `GET` requests and one 404 through the `nip.io` Ingress, waits ten seconds for the shim's batch span exporter to flush, and reads each backend by `kubectl exec` into the `otel-lgtm` Pod, calling the backend's API on its own localhost port (Tempo `:3200`, Prometheus `:9090`, Loki `:3100`) with `curl` (or `wget` where the image lacks it). Tempo is queried for the shim's service name:

{% raw %}
```bash
tempo_q="{resource.service.name=\"${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}\"}"
tempo_url="http://127.0.0.1:3200/api/search?q=$(urlencode "$tempo_q")&limit=20"
tempo_json="$(http_in_pod "$tempo_url" || true)"
```
{% endraw %}

Prometheus is queried for `otelcol_receiver_accepted_spans_total` and Loki for the last hour of any job's log stream. No port-forward opens and no UI is involved; the evidence is the backend's own HTTP response.

## CRC: the wasmCloud host emits OTLP natively

`otel-lgtm` can't run on CRC. It's a development image whose supervisor starts five processes that manage their own ports and files, and it has never been validated against the `restricted-v2` model that assigns a UID from the namespace range. Stay on `restricted-v2` with no `anyuid` and no SCC exception. `openshift/otel-collector.yaml` substitutes a single-purpose `otel/opentelemetry-collector-contrib`. It receives OTLP from the host and writes it two ways, so the evidence reads without a UI:

- the `debug` exporter, verbose, to container stdout, read with `oc logs`;
- the `file` exporter to an `emptyDir`, read with `oc exec ... cat`.

The configuration has one OTLP receiver on gRPC and HTTP, a batch processor, and both exporters on all three pipelines:

{% raw %}
```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        timeout: 5s
    exporters:
      debug:
        verbosity: detailed
      file:
        path: /data/otel-output.json
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
    service:
      extensions: [health_check]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug, file]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug, file]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug, file]
```
{% endraw %}

Nothing leaves the collector's stdout and its `emptyDir`; there's no forwarding stage to a dashboard backend, so evidence needs only `oc logs` and `oc exec`.

`restricted-v2` compliance shows in what the manifest leaves out: no `runAsUser` and no `runAsGroup` on the Pod or the container, so OpenShift assigns a UID from the namespace range. The collector-contrib image runs as UID 10001 by default, but the manifest does not rely on that fixed UID. It sets the hardening a rootless container needs on any UID:

{% raw %}
```yaml
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
```
{% endraw %}

The config arrives through a ConfigMap volume that any UID can read. The only writable path is the `emptyDir` at `/data`, whose group ownership the kubelet sets to the Pod's SCC-assigned `fsGroup`, so a process with no fixed identity can write to exactly one path.

`wasmcloud-host-otel.yaml` patches the running `WasmCloudHostConfig` to turn on the host's native export. The operator CRD exposes `spec.observability` with `enable`, `endpoint`, `protocol` (`grpc` or `http`) and per-signal `traces`, `metrics` and `logs` switches:

{% raw %}
```yaml
spec:
  hostReplicas: 1
  lattice: default
  version: "1.9.1"
  natsAddress: nats://nats.wasmcloud.svc.cluster.local
  registryCredentialsSecret: ghcr-pull
  allowLatest: false
  observability:
    enable: true
    endpoint: "http://otel-collector.wasmcloud.svc.cluster.local:4318"
    protocol: http
    traces:
      enable: true
    metrics:
      enable: true
    logs:
      enable: true
```
{% endraw %}

The patch uses the same CR name and namespace as `wasmcloud-host.yaml`, so `oc apply` replaces the running host's spec in place rather than adding a second host; apply it after `deploy.sh`, or instead of `wasmcloud-host.yaml` from the start. The schema was confirmed against the operator's source tree, not against the CRD version the pinned chart installs. Run `oc explain wasmcloudhostconfig.spec.observability` against the live cluster before relying on the field names. The host runs as an ordinary Pod with cluster DNS, so it reaches the collector by its short service name, which the minikube path's node-level shim can't do.

The operator rolls a fresh generation of the host Pod on a spec change rather than mutating the running one. `verify-otel-crc.sh` therefore waits for the Deployment's pod template to show an `otel` environment variable, not just for the Deployment to exist. It then sends five requests through the existing edge-TLS Route, verified against the CA bundle and never with `-k`, waits ten seconds for the host's batch exporter, and reads the collector two independent ways. First `oc logs`:

{% raw %}
```bash
LOG="$(oc logs "deploy/otel-collector" -n "$NS" --tail=2000 2>/dev/null)"
echo "$LOG" | grep -qi 'TraceID' \
    || fail "no TraceID found in otel-collector logs (oc logs deploy/otel-collector -n $NS)"
ok "a real trace left the wasmCloud host and was received by the collector"
echo "$LOG" | grep -q 'wasmcloud_host.handle_rpc_message.duration' \
    || fail "metric wasmcloud_host.handle_rpc_message.duration not found in otel-collector logs"
ok "metric series wasmcloud_host.handle_rpc_message.duration received"
```
{% endraw %}

Then the file exporter's output:

{% raw %}
```bash
FILE_SAMPLE="$(oc exec "$COLLECTOR_POD" -n "$NS" -- sh -c 'tail -c 200000 /data/otel-output.json 2>/dev/null' || true)"
echo "$FILE_SAMPLE" | grep -q 'wasmcloud_host.handle_rpc_message.duration' \
    || fail "file exporter output missing the handle_rpc_message.duration metric (oc exec $COLLECTOR_POD -n $NS -- cat /data/otel-output.json)"
```
{% endraw %}

`wasmcloud_host.handle_rpc_message.duration` is the metric to watch: the time the host spends handling one invocation dispatched over wRPC. It exists at the link boundary that the sidecar and adapter interposers exercise. With the pipeline wired up, the individual `book-cargo` and `get-cargo` invocations show as separate durations, evidence that each call landed on an independent instance instead of a shared one.

> **Decision**
>
> Treat the shim's trace as proof that a specific Wasm Pod was scheduled, started and completed invocations, nothing more. Use it for "is the component alive and responding". Use the wasmCloud host's traces, metrics and logs when the question is behavior at the link layer, such as RPC durations across an interposed chain. Budget for the rootless-collector pattern (no fixed UID, an `emptyDir` owned by the SCC-assigned `fsGroup`) whenever a sink must run on `restricted-v2`. Neither pipeline shows a span the guest emitted, and that stays true until `wasi-otel` graduates and a pinned runtime implements it.

> **🤖 Explore with your agent**
>
> "In `examples/part5-kubernetes/openshift/otel-collector.yaml`, add a `memory_limiter` processor ahead of `batch` in all three pipelines of the `config.yaml` ConfigMap without adding `runAsUser`, `runAsGroup` or any SCC. Then review `wasmcloud-host-otel.yaml` and tell me which `spec.observability` field I would change to send OTLP over gRPC instead of HTTP, and which port on the collector that requires."
>
> Check: `git diff` shows `memory_limiter` listed before `batch` three times and no `runAsUser`, and the reply names `protocol: grpc` and port 4317.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s/observability && ./verify-otel-minikube.sh
```

The minikube script deploys the `otel-lgtm` sink, runs `enable-shim-otel.sh` to write the drop-in and restart containerd, redeploys `cargo-http` behind a fresh shim, drives the traffic, and queries Tempo, Prometheus and Loki from inside the sink Pod. `openshift/verify-otel-crc.sh` is the CRC counterpart: it applies the collector, patches the host, drives traffic through the Route, and checks a trace, the `handle_rpc_message.duration` metric and a log line through both `oc logs` and `oc exec`. Each prints `PASS`; `README.md` and the `evidence/` directories record the version matrix and backend responses.

Experiments:

- Run `enable-shim-otel.sh` after `cargo-http` is already running and Tempo returns no span for the shim until the Pod is recreated.
- Look for a span from the cargo component's own code on either substrate and there is none.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the WASI Preview 2 target and Component Model guarantees that draw the line between substrate telemetry and guest telemetry.
- [`containerd/runwasi`, OpenTelemetry integration](https://github.com/containerd/runwasi): the change in v0.5.0 that turned on trace export by default, the mechanism `enable-shim-otel.sh` configures.
- [wasmCloud: Observability](https://wasmcloud.com/docs/ecosystem/observability/): the host's native observability surface that the operator's `spec.observability` block exposes.
- [OpenTelemetry Collector configuration](https://opentelemetry.io/docs/collector/configuration/): the `debug` and `file` exporters that give the CRC collector its no-UI read paths.
- [`WebAssembly/wasi-otel`](https://github.com/WebAssembly/wasi-otel): the RC-only guest-telemetry proposal that would let a component emit its own signals.
- The `restricted-v2`, no-SCC-exception discipline from the OpenShift Local (CRC) deployment, applied here to a telemetry sink.
- The raw containerd shim and the single-node host-network topology from the minikube deployment: the baked-in ClusterIP depends on both.
- The per-invocation state finding from the sidecar and adapter interposers: the RPC duration metric makes it observable.
