---
title: "Observability On-Cluster"
order: 24
part: "Deploying to Kubernetes"
description: "Two substrate-provided OTel pipelines for the same deployed cargo-http component: the containerd-shim-wasmtime emits traces by default on minikube, configured through a node-level systemd drop-in and read from a disposable otel-lgtm sink with no port-forward; the wasmCloud host emits traces, metrics, and logs natively on CRC, read from a rootless collector under full restricted-v2. Both substrates are observable; neither shows a span the Wasm guest itself emitted."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- State precisely why no Wasm guest component in this book emits its own span, metric, or log: `wasi-otel` is an RC-only proposal, not part of the pinned stable toolchain (wasmtime 50, containerd shim v0.6.1, wasmCloud host 1.9.1), and name what signal each substrate produces instead on each cluster (Figure 24.2).
- Read `examples/part5-kubernetes/k8s/observability/enable-shim-otel.sh` and explain the exact mechanism that turns on `containerd-shim-wasmtime`'s OTel export (standard `OTEL_EXPORTER_OTLP_*` env vars reaching the containerd process through a systemd drop-in, not a shim flag or a Pod annotation), why the endpoint is a baked-in ClusterIP rather than a DNS name, and the restart-ordering gotcha the script exists to avoid.
- Read `examples/part5-kubernetes/openshift/otel-collector.yaml` and `wasmcloud-host-otel.yaml` and explain why CRC does not reuse the minikube path's `otel-lgtm` image, what replaces it, and how a Deployment with no `runAsUser` set still gets write access to its own `emptyDir` under `restricted-v2`.
- Query each backend the way the verify scripts do: `kubectl exec` into the `otel-lgtm` Pod's own network namespace on minikube, `oc logs` and `oc exec` against the rootless collector on CRC, and state why neither path uses a port-forward or a Grafana UI.
- Decide, given an on-cluster Wasm observability requirement today, whether minikube's shim-trace-only signal or CRC's host-native trace-plus-metric-plus-log signal is sufficient for it, and name the one thing neither substrate's pipeline can show: a span the `patterncatalyst:cargo` component itself produced.

## Why this matters

Chapters 18 and 19 proved the same `app.wasm` running live on two substrates; Chapters 20 and 21 spliced four more interposers into that same request path without touching the original provider or front door. None of those chapters asked the obvious next question: once a Wasm component is actually running on a cluster, what can an operator see about it? This chapter answers that question for both substrates, and the answer is narrower than it looks from the outside. Nothing in this project's pinned toolchain lets `patterncatalyst:cargo`'s own Rust code open a span, record a metric, or emit a structured log entry through an OpenTelemetry SDK compiled into the component. `wasi-otel`, the WASI proposal that would give a guest component that capability, is still an RC-only draft; it is not part of `wasm32-wasip1`, the only WASI target this book builds against, and no runtime in the pinned stack (wasmtime 50, the containerd shim at v0.6.1, the wasmCloud host at 1.9.1) implements it. Every trace, metric, and log this chapter captures is produced by the substrate the component runs inside: the shim that manages the Wasm Pod's lifecycle on minikube, the wasmCloud host that dispatches RPC calls to it on CRC. The component's own code never calls an OTel API, because there is no stable one to call.

That constraint does not make on-cluster observability worthless, it makes it a different question than the one a Java or Python operator is used to asking. A JVM or CPython process can be told to auto-instrument itself and start emitting spans tomorrow with a one-line agent flag; a Wasm component cannot, not because the tooling is immature in some vague sense, but because the specific proposal that would carry a span out of guest code into an SDK does not yet exist in a form any of this book's runtimes implement. What exists instead is two different stories about what the platform hosting the component can tell you, and those two stories diverge sharply between minikube and CRC. The raw containerd shim, the simpler of the two substrates in every other chapter, turns out to be the richer-by-default one here: it has emitted OTel traces automatically since runwasi v0.5.0, no flag required. The wasmCloud operator, which needed a dedicated appendix chapter to deploy at all under `restricted-v2`, turns out to offer the deeper signal once wired up: traces, metrics, and logs together, natively, because the host process that already mediates every RPC call between components is a natural place to instrument that dispatch.

{% include excalidraw.html file="24-otel-two-emitters-pipeline" alt="Two horizontal bands. Top band, minikube: containerd-shim-wasmtime v0.6.1 (per-pod Wasm runtime shim) emits shim-level OTel traces, one span per invocation and shim-origin only, into otel-lgtm (Grafana / Tempo / Loki / Prometheus bundled in one Pod). Bottom band, CRC: the wasmCloud host 1.9.1 (lattice host process) emits native traces, metrics, and logs, host- and provider-level telemetry, into a rootless OTel Collector that is restricted-v2 SCC compatible, whose debug and file exporters are the evidence sink, read via oc logs and oc exec. A caption line under both bands reads: two separate clusters, two separate backends, don't assume one chapter's OTel pipeline describes the other substrate." caption="Figure 24.1 — two emitters, two substrates: shim-level traces only on minikube (into otel-lgtm) versus host-native traces, metrics, and logs on CRC, landing in a rootless restricted-v2 collector whose debug and file exporters are the evidence sink. No otel-lgtm on CRC." %}

## Signal provenance: what each substrate actually tells you

Before touching either manifest, "observability" needs a precise definition for this chapter, because the answer is not the same for every signal on every substrate. Figure 24.2 is a three-by-two matrix: traces, metrics, and logs down one axis, minikube's shim-level pipeline and CRC's host-level pipeline across the other.

{% include excalidraw.html file="24-signal-provenance" alt="A three-row by two-column matrix headed guest wasi-otel is RC-only, NOT used in this book; telemetry here is substrate-provided, not component-authored. Rows: traces, metrics, logs. Left column, minikube, shim-level (containerd-shim-wasmtime): traces row reads span per invocation, emitted by the shim, not the guest; metrics row reads not emitted by the shim, cgroup CPU only via metrics-server; logs row reads container stdout/stderr only, kubelet-captured, not OTel. Right column, CRC, host-level (wasmCloud host 1.9.1): traces row reads host and provider spans, wRPC call boundaries captured natively; metrics row reads host-native metrics, instance counts, invocation rates; logs row reads host-native structured logs, via the OTel log pipeline." caption="Figure 24.2 — signal provenance: on minikube only traces are shim-emitted OTel (metrics and logs still exist, but through metrics-server and kubelet, not this chapter's OTLP pipeline); on CRC all three signals are host-native and OTel-native." %}

The minikube column is narrower than a first glance at `verify-otel-minikube.sh` suggests. That script's own evidence run queries Prometheus and Loki in addition to Tempo, and both return real data, but what they return is the `otel-lgtm` stack's own internal self-observability, the Collector's count of spans it accepted, the bundled stack's own process logs, not a metric or log describing the shim or the Wasm Pod it manages. `containerd-shim-wasmtime` emits OTel spans and nothing else; CPU and memory figures for the Wasm Pod still come from the cluster's ordinary `metrics-server` path, and the component's stdout/stderr still lands wherever `kubectl logs` always reads it from, the kubelet's container log files, untouched by this chapter's OTLP pipeline. The CRC column has no such asterisk: the wasmCloud host's `spec.observability` block turns on traces, metrics, and logs together, and all three travel the OTLP pipeline this chapter wires up, because the host process is already the one component in the lattice positioned to see every RPC dispatch, not merely one container's lifecycle events.

## minikube: the containerd shim emits traces by default

`examples/part5-kubernetes/k8s/observability/base/otel-lgtm.yaml` is the OTLP sink this path writes to, a single Pod bundling Grafana's own OpenTelemetry Collector in front of Tempo, Prometheus, and Loki. Its header comment states the scope directly:

{% raw %}
```yaml
# ch24 on-cluster observability — minikube backend.
#
# grafana/otel-lgtm bundles an OpenTelemetry Collector (0.161.0) in front of
# Tempo (traces), Prometheus (metrics) and Loki (logs), plus Grafana wired to
# all three as pre-provisioned datasources — one Pod, one OTLP sink. This is
# the SAME role the lgtm-docker-stack / lgtm-minikube-stack skills' LGTM stack
# plays for the Quarkus/Python/C++ projects; here it is the sink for the
# node-level telemetry the containerd `wasmtime` shim emits (enable-shim-otel.sh)
# about the cargo-http Wasm Pod — NOT telemetry authored by the Wasm guest
# itself. wasi-otel guest-emitted spans are an RC-only proposal, not in the
# pinned stable toolchain (wasm32-wasip1 + wasmtime 0.6.1 shim), so on-cluster
# Wasm observability today is substrate-provided: shim-level here, wasmCloud
# host-level on the CRC path (../../../openshift/otel-collector.yaml).
```
{% endraw %}

The Deployment itself is unremarkable next to that comment, one container pulling `grafana/otel-lgtm:0.33.1` straight from Docker Hub (never `minikube image load`, because this is a public dev image with a registry behind it, unlike `cargo-http-wasm`), with Grafana's own `/` endpoint on port 3000 as the readiness signal because the all-in-one stack's supervisor brings Grafana up last of its five processes:

{% raw %}
```yaml
      containers:
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
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 5
            failureThreshold: 30
```
{% endraw %}

`overlays/minikube/kustomization.yaml` is a resource-budget patch only, tuning the container's limits down from the base's 2 CPU / 3Gi to 1 CPU / 2Gi to fit a default `minikube start` VM, the same convention the Part 5 base/minikube split already uses for the app itself. Deploying this Pod is necessary but not sufficient: a sink with nothing pointed at it receives nothing.

`enable-shim-otel.sh` is the piece that actually turns the shim's telemetry on, and its header states something easy to miss on a first read of the containerd ecosystem: the shim has emitted OTel traces on by default since runwasi v0.5.0, which means there is no shim flag, no Pod annotation, no Kubernetes object at all that enables this. Configuration happens purely through the standard `OTEL_EXPORTER_OTLP_*` environment variables in the environment of the containerd process itself, because the shim is spawned as a child of containerd and inherits whatever environment that parent process has. Changing that environment is therefore a node-level change, not a cluster-level one, which is why this script writes a systemd drop-in on the minikube VM rather than patching any Kubernetes resource:

{% raw %}
```bash
OTEL_ENDPOINT="http://${OTEL_LGTM_IP}:4318"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}"
OTEL_PROTOCOL="${OTEL_PROTOCOL:-http/protobuf}"
```
```bash
NEW_CONTENT='[Service]
Environment="OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_ENDPOINT}"
Environment="OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}"
Environment="OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_PROTOCOL}"
'
```
{% endraw %}

That endpoint is a bare IP address, not a DNS name, and the script's own comment explains why in terms this section restates precisely, because it is the same host-network-namespace fact Chapter 18 already established for how the raw shim talks to the outside world at all:

{% raw %}
```bash
# WHY A BAKED-IN IP, NOT A DNS NAME: containerd runs in the minikube NODE's
# host network namespace, not inside any Pod's network namespace, so it has no
# cluster DNS resolver and cannot look up
# otel-lgtm.<namespace>.svc.cluster.local. What IS reachable from the host
# namespace is the Service's ClusterIP: on a single-node minikube cluster,
# kube-proxy's iptables/ipvs NAT rules for ClusterIPs are installed in that
# same host network namespace (there is only one node), so a ClusterIP is
# routable from containerd even though containerd is not a cluster-aware
# process. This script resolves the ClusterIP once, at install time, with
# `kubectl get svc`, and bakes the IP (not the name) into the drop-in. If the
# otel-lgtm Service is ever recreated with a new ClusterIP, re-run this script.
```
{% endraw %}

Containerd has no cluster DNS resolver because it is not itself a cluster-aware process, it is the node-level daemon Kubernetes sits on top of; what makes a ClusterIP reachable from that vantage point at all is specific to a single-node cluster, where kube-proxy's NAT rules for every Service happen to live in the same host network namespace containerd itself occupies. On a multi-node cluster, this exact technique would not work from a node that is not running the `otel-lgtm` Pod, because the NAT rule for a ClusterIP backed by a Pod on a different node still resolves, but the script's hardcoded, resolve-once approach would need to be redone per node. For this book's single-node minikube profile, that gap does not surface, and the comment is explicit that this is a workaround for a specific topology rather than a general pattern.

<div class="callout callout--warn"><p class="callout__title">Gotcha</p><p>Restarting containerd bounces every Pod on the node, because containerd is the runtime every Pod's containers (and, on this path, every Wasm shim) depend on. <code>enable-shim-otel.sh</code> must therefore run BEFORE the cargo-http app overlay is applied or reapplied, never after: a shim process already running when the drop-in's environment changes does not retroactively pick it up, because the environment a process sees is fixed at the moment it starts, not re-read on a timer. Only a shim spawned fresh, meaning after this script's own <code>systemctl restart containerd</code>, inherits the new <code>OTEL_EXPORTER_OTLP_*</code> values. <code>verify-otel-minikube.sh</code> encodes this ordering directly in its step numbering: deploy the observability stack, then run this script, then (re)deploy the app, deleting the existing Pod outright so its replacement is scheduled behind a freshly restarted shim rather than reusing one that predates the change.</p></div>

With the drop-in written and containerd restarted, `verify-otel-minikube.sh` deploys the observability overlay, runs this script, redeploys `cargo-http` with its Pod deleted so a fresh shim picks up the new environment, enables the ingress addon, and drives five successful `GET` requests plus one 404 through the real `nip.io` Ingress host, the same traffic-generation pattern every other Part 5 chapter uses. It then waits ten seconds for the shim's batch span exporter to flush and reads every backend the same way: `kubectl exec` into the `otel-lgtm` Pod itself, curling (or, if curl is absent from that image's base OS, falling back to `wget`) each backend's HTTP API on its own localhost port from inside that Pod's network namespace. No port-forward ever opens, and no Grafana UI is involved at any point; the proof is the backend's own HTTP response, captured as text.

{% raw %}
```bash
tempo_q="{resource.service.name=\"${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}\"}"
tempo_url="http://127.0.0.1:3200/api/search?q=$(urlencode "$tempo_q")&limit=20"
tempo_json="$(http_in_pod "$tempo_url" || true)"
```
{% endraw %}

<!-- LIVE-OUTPUT ch24 minikube Tempo trace: fill from k8s/observability/evidence/<date>/03-tempo.txt after the gated run --> *(verified-live output lands here after the cluster run: a Tempo `/api/search` response containing at least one `"traceID"` for `service.name="containerd-shim-wasmtime"`.)*

The same pattern repeats against Prometheus, querying `otelcol_receiver_accepted_spans_total`, the Collector's own ingestion counter, and against Loki, querying the last hour of any job's log stream:

<!-- LIVE-OUTPUT ch24 minikube Prometheus metric vector: fill from k8s/observability/evidence/<date>/04-prometheus.txt after the gated run --> *(verified-live output lands here after the cluster run: a `"resultType":"vector"` response with at least one `"value":[...]` sample for `otelcol_receiver_accepted_spans_total`.)*

<!-- LIVE-OUTPUT ch24 minikube Loki log line: fill from k8s/observability/evidence/<date>/05-loki.txt after the gated run --> *(verified-live output lands here after the cluster run: a Loki `query_range` response with at least one `"values":[...]` stream entry.)*

The script's own comment on the Loki query is direct about what that third result actually proves: the shim emits traces only, no logs of its own, so Loki's evidence here is the `otel-lgtm` stack's self-observability rather than anything describing the Wasm workload. That distinction matters for reading the evidence correctly once it lands: a reviewer scanning three green checks (Tempo, Prometheus, Loki) could reasonably assume three signals about the Wasm Pod arrived, when the accurate statement is one signal about the Wasm Pod's shim (a trace) and two signals about the backend's own health. Figure 24.2's metrics and logs rows for the minikube column exist precisely to keep that distinction in front of a reader who only skims the pass/fail summary.

## CRC: the wasmCloud host emits OTLP natively, under restricted-v2

The CRC path cannot reuse `otel-lgtm`, and the reason is the same `restricted-v2` constraint Chapter 19 built an entire appendix chapter around. `otel-lgtm` is a development image: Grafana's own Dockerfile runs it unprivileged, but its supervisor starts five processes that each want to manage their own ports and files, and the image has never been validated against the "no fixed UID, assign one from the namespace's allocated range" model `restricted-v2` enforces. CRC's house rule throughout this book has been no SCC exception and no `anyuid`, and that rule does not bend for a telemetry sink any more than it bends for the application workload itself. `examples/part5-kubernetes/openshift/otel-collector.yaml` states the substitution directly:

{% raw %}
```yaml
# otel-lgtm (the minikube backend, ../k8s/observability/base/otel-lgtm.yaml) is
# a DEV image: Grafana's own Dockerfile runs it unprivileged but its supervisor
# starts five processes that each want to self-manage ports/files, and it is
# never validated against restricted-v2's "no fixed UID, assign one from the
# namespace range" model. It is NOT used here — house rule: CRC stays
# restricted-v2 with NO SCC exception, anyuid is barred.
#
# Instead: a minimal, single-purpose otel/opentelemetry-collector-contrib
# (0.163.1 — the tag pinned in the upstream otelcol-contrib distribution
# manifest as of this survey) receiving OTLP from the wasmCloud host
# (../openshift/wasmcloud-host-otel.yaml) and dumping it two ways so the
# evidence is readable with no UI and no port-forward:
#   * `debug` exporter (verbosity: detailed) -> container stdout, read with
#     `oc logs`.
#   * `file` exporter -> an emptyDir, read with `oc exec ... cat`.
```
{% endraw %}

The collector's own `config.yaml` is small enough to read in full, and none of it is filler: one OTLP receiver accepting both gRPC and HTTP, one batch processor, and both the `debug` and `file` exporters wired into all three pipelines so a trace, a metric, and a log all land in two independently readable places at once:

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

No signal in this config.yaml travels any further than the collector's own stdout and its own `emptyDir`; there is no forwarding stage to a dashboarding backend at all, which is a chosen simplification this chapter makes so that evidence can be read with `oc logs` and `oc exec` alone. The restricted-v2 compliance the header comment promises is visible in what the manifest does not set rather than in what it does: no `runAsUser`, no `runAsGroup`, on either the Pod or the container, the same absence of a fixed identity Chapter 19's `wadm` Deployment already established as the pattern for running under a namespace-assigned UID range. What the manifest does set is the hardening a rootless container still needs regardless of which UID it lands on:

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

With no fixed UID set, the collector's config file still has to be readable and its output file still has to be writable by whatever UID the SCC actually assigns at admission time. The config arrives through a ConfigMap volume, which any UID can read; the only directory the container writes to is the `emptyDir` mounted at `/data`, and the kubelet sets that volume's group ownership to the Pod's SCC-assigned `fsGroup` regardless of which UID the container runs as, so a process with no fixed identity still gets write access to exactly one path, with zero SCC exception requested.

The other half of this path is `wasmcloud-host-otel.yaml`, an in-place patch of the running `WasmCloudHostConfig` CR that turns the host's native OTLP export on. The header comment is explicit about where this schema comes from and the one gap in that confirmation to carry forward:

{% raw %}
```yaml
# The wasmCloud host (1.9.1) has native OTLP export built
# in (`WASMCLOUD_OBSERVABILITY_ENABLED` / `wash --enable-traces/metrics/logs`
# at the CLI); the operator's WasmCloudHostConfig CRD exposes the same knobs as
# a first-class `spec.observability` block (confirmed against the CRD source,
# wasmCloud/wadm-operator crates/types/src/v1alpha1/wasmcloud_host_config.rs,
# `ObservabilityConfiguration` / `OtelSignalConfiguration` structs — camelCase
# over the wire via serde's `rename_all = "camelCase"`):
#
#   spec.observability.enable            bool
#   spec.observability.endpoint          string
#   spec.observability.protocol          grpc|http
#   spec.observability.traces.enable     bool
#   spec.observability.metrics.enable    bool
#   spec.observability.logs.enable       bool
#
# If the installed operator's CRD (chart 0.1.2 pins operator 0.1.5 — see
# ../openshift/lib.sh) predates this schema, `oc explain
# wasmcloudhostconfig.spec.observability` on the live cluster is the
# authoritative check before applying this.
```
{% endraw %}

That gap needs naming rather than glossing over: the schema above was confirmed against the operator's current source tree, not against the exact CRD version the pinned chart (0.1.2, pinning operator 0.1.5) installs on a live cluster. The comment's own prescribed fix is a one-line spot check, `oc explain wasmcloudhostconfig.spec.observability` against the running cluster, run before relying on the field names below rather than after something fails silently. The spec block itself, applied as an in-place patch to the same CR name and namespace `deploy.sh` already created, points the host at the in-namespace collector by short DNS name, something the minikube path's baked-in ClusterIP workaround never gets to do, because a wasmCloud host runs as an ordinary Pod with the cluster's normal DNS resolver, not as a node-level process outside every Pod's network namespace:

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

`verify-otel-crc.sh` applies the collector, waits for it to roll out, applies this patch, and then waits specifically for the host Deployment's own pod template to reflect the change (grepping its container env for `otel`, not merely checking that the Deployment object still exists), because the operator reconciling a spec change rolls a fresh generation of the host Pod rather than mutating the running one in place. Once that rollout completes, it drives five `GET` requests through the existing edge-TLS Route (the same `combined_ca_bundle` CA-verified pattern every CRC verification script in this book uses, never `-k`), waits ten seconds for the host's own batch exporter to flush, then reads the collector two independent ways: `oc logs` against the `debug` exporter's stdout, and `oc exec ... cat` against the `file` exporter's `emptyDir`, cross-checking that both agree.

{% raw %}
```bash
LOG="$(oc logs "deploy/otel-collector" -n "$NS" --tail=2000 2>/dev/null)"
echo "$LOG" | grep -qi 'TraceID' \
    || fail "no TraceID found in otel-collector logs (oc logs deploy/otel-collector -n $NS)"
echo "$LOG" | grep -q 'wasmcloud_host.handle_rpc_message.duration' \
    || fail "metric wasmcloud_host.handle_rpc_message.duration not found in otel-collector logs"
echo "$LOG" | grep -qi 'LogRecord #' \
    || fail "no LogRecord found in otel-collector logs"
```
{% endraw %}

<!-- LIVE-OUTPUT ch24 CRC collector debug-exporter trace excerpt: fill from openshift/evidence/<date>/04-collector-debug-log.txt after the gated run --> *(verified-live output lands here after the cluster run: a `debug` exporter trace block containing a real `TraceID` line.)*

<!-- LIVE-OUTPUT ch24 CRC collector handle_rpc_message.duration metric excerpt: fill from openshift/evidence/<date>/04-collector-debug-log.txt after the gated run --> *(verified-live output lands here after the cluster run: a `debug` exporter metric block for the `wasmcloud_host.handle_rpc_message.duration` series.)*

<!-- LIVE-OUTPUT ch24 CRC collector LogRecord excerpt: fill from openshift/evidence/<date>/04-collector-debug-log.txt after the gated run --> *(verified-live output lands here after the cluster run: a `debug` exporter log block containing a `LogRecord #` entry.)*

The file-exporter cross-check is a second, redundant read alongside the `oc logs` read: two different code paths inside the same collector binary, two different places to read the output, both expected to agree on the same metric series actually having arrived.

{% raw %}
```bash
FILE_SAMPLE="$(oc exec "$COLLECTOR_POD" -n "$NS" -- sh -c 'tail -c 200000 /data/otel-output.json 2>/dev/null' || true)"
echo "$FILE_SAMPLE" | grep -q 'wasmcloud_host.handle_rpc_message.duration' \
    || fail "file exporter output missing the handle_rpc_message.duration metric (oc exec $COLLECTOR_POD -n $NS -- cat /data/otel-output.json)"
```
{% endraw %}

<!-- LIVE-OUTPUT ch24 CRC collector file-exporter cross-check excerpt: fill from openshift/evidence/<date>/05-collector-file-export.txt after the gated run --> *(verified-live output lands here after the cluster run: a `/data/otel-output.json` tail independently containing the same `wasmcloud_host.handle_rpc_message.duration` metric series.)*

`wasmcloud_host.handle_rpc_message.duration` is the metric to call out on its own: it is the time the host spends handling one invocation dispatched over wRPC, which means it exists precisely at the link boundary Chapter 20 and Chapter 21 both already made the center of their state-contrast findings. A reader who ran those two chapters' interposition chains on CRC and watched a valid tracking id return a 404 instead of a 200 can, with this chapter's pipeline wired up, actually watch that same request's individual `book-cargo` and `get-cargo` invocations show up as separate durations in the host's own metrics, direct confirmation that each call really did land on an independent instance rather than a shared one. The telemetry in this chapter is not a new finding standing apart from Chapters 20 and 21; it is the instrument that would let an operator see the state-boundary finding those chapters already proved by HTTP response alone.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Treat minikube's shim-level trace as proof that a specific Wasm Pod was scheduled, started, and completed invocations on the node, and nothing beyond that: no metric or log in this chapter's minikube pipeline describes the Wasm workload itself, only the shim's own span and the backend stack's self-observability, so reach for it when the operational question is "is the component alive and responding," not "what is the component's RPC-level behavior." Treat CRC's wasmCloud host pipeline as the substantially richer signal: traces, metrics, and logs together, all describing host-level RPC dispatch across every linked call, including the exact invocation boundaries Chapters 20 and 21 already proved matter for an interposed, stateful request. Choose CRC's pipeline over minikube's whenever the operational question is about behavior at the link layer rather than mere Pod liveness, and budget for the restricted-v2 rootless-collector pattern (no fixed UID, an emptyDir owned by the SCC-assigned fsGroup) any time a telemetry sink needs to run on that platform without an SCC exception. On neither substrate should an operator expect to see a span the Wasm guest's own code emitted: that capability depends on `wasi-otel` graduating out of its RC-only status and landing in a runtime this book's toolchain actually pins, and until it does, every signal captured here describes the platform underneath the component, never the component's own domain logic.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning) — the WASI Preview 2 target and Component Model guarantees this chapter's substrate-versus-guest telemetry boundary is drawn against.
- [`bytecodealliance/runwasi`, "OpenTelemetry Integration"](https://github.com/containerd/runwasi) — the containerd-shim-wasmtime change (v0.5.0) that turned on-by-default OTel tracing for every Wasm Pod the shim manages, the mechanism `enable-shim-otel.sh` configures.
- [wasmCloud: Observability](https://wasmcloud.com/docs/ecosystem/observability/) — the host's native `WASMCLOUD_OBSERVABILITY_ENABLED` / `wash --enable-traces/metrics/logs` surface that `wasmcloud-host-otel.yaml`'s `spec.observability` block exposes through the operator CRD.
- [OpenTelemetry Collector: `debug` and `file` exporters](https://opentelemetry.io/docs/collector/configuration/) — the two zero-UI, zero-port-forward read paths this chapter's rootless CRC collector relies on for every piece of captured evidence.
- [`bytecodealliance/wasi-otel`](https://github.com/WebAssembly/wasi-otel): the RC-only guest-telemetry proposal this chapter names as the missing piece, not yet in `wasm32-wasip1` and not implemented by any runtime this book pins.
- Chapter 13, "Networking, Reconnect, and Resilience" and Chapter 19, "Deploying on OpenShift Local (CRC)" — the `restricted-v2`, no-SCC-exception discipline this chapter's rootless collector Deployment applies a second time, to a telemetry sink instead of an application workload.
- Chapter 18, "Deploying on minikube": the raw containerd shim and the single-node host-network-namespace topology this chapter's baked-in-ClusterIP workaround depends on.
- Chapter 20, "Wasm as a Sidecar" and Chapter 21, "Ambassador and Adapter Patterns with Wasm" — the per-invocation state finding this chapter's `wasmcloud_host.handle_rpc_message.duration` metric gives an operator a direct, metric-level way to observe, rather than inferring it from an HTTP status code alone.

