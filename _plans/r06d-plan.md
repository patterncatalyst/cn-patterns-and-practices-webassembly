# r06d — Complete Part 5: ch22 HPA + ch23 KEDA scale-to-zero + ch24 observability

Branch `r06d-patterns` off `main@e14dcaf`. One iteration (Decision C). Completes Part 5 (ch17–ch24).
`app.wasm` (sha256 eff7f5ee) reused unchanged; `contracts/wit` stays PRISTINE. ONE new crate
(`kafka-handler`) with LOCAL wit + cargo-contract path-dep (r06c pattern).

## Gated decisions (user)
- **A = wasmCloud-on-minikube** for the ch23 Kafka half (no in-component Kafka client, no spike).
  `messaging-kafka` provider + ONE `kafka-handler` component on BOTH clusters; KEDA OBSERVES lag,
  wadm spreadscaler OWNS replicas — the "substrate owns the lifecycle" teaching, consistent across
  clusters. Mixed-substrate-within-minikube (raw shim for HTTP/HPA, wasmCloud for Kafka) is intended.
- **B = minimal rootless upstream OTel Collector + collector-side evidence** on CRC (otel-lgtm dropped
  on CRC; anyuid barred; restricted-v2 held). minikube keeps otel-lgtm 0.33.1.
- **C = one r06d** (ch22+ch23+ch24 together).

## Chapters (fill existing stubs to house depth: spine like ch20/ch21, ≥2000w, ≥2 diagrams,
Decision block before For-deeper-coverage, duration, 0 ban-tier, {% raw %} guards, verbatim code;
footers flip to "verified live <date>" ONLY after BOTH cluster PASSes)
- **ch22 Scaling Wasm Workloads: HPA** (order 22). minikube = real CPU HPA (metrics-server addon)
  on the raw-shim plain Deployment, synthetic in-cluster load → replicas 1→N→1; scaling-math
  (Wasm sub-second replica vs container seconds). CRC = wadm spreadscaler (no K8s HPA on the host
  Deployment — would fight the operator). Honest per-substrate asymmetry (Decision 2).
- **ch23 Serverless Wasm: scale-to-zero with KEDA** (order 23). Two models:
  - Half 1 HTTP add-on (KEDA DRIVES): minikube raw-shim Deployment, HTTPScaledObject minReplicas 0,
    idle→0, cold request via nip.io Ingress→interceptor→0→1→200 + cold-start latency. CRC = CMA/KEDA
    installed + wadm spreadscaler 0↔N.
  - Half 2 Kafka scaler (KEDA OBSERVES / wadm OWNS, both clusters): wasmCloud messaging-kafka provider
    + kafka-handler; KEDA kafka ScaledObject reads consumer-group lag; wadm owns handler replicas;
    producer burst → lag↑ → instances↑ → drain → instances↓.
- **ch24 Observability On-Cluster** (order 24). Telemetry is substrate-provided, not guest (wasi-otel
  RC-only). minikube = shim-level OTel traces (shim v0.6.1, env-configured) → otel-lgtm 0.33.1,
  evidence via Tempo/Prometheus/Loki queries through kubectl exec. CRC = wasmCloud host 1.9.1 native
  OTLP → minimal rootless upstream OTel Collector (restricted-v2), evidence from its debug/file
  exporter via oc exec. No port-forward, no Grafana UI.

## Steps
### BUILD (offline, no cluster; Sonnet executors; commit per step)
1. Branch + plan checkpoint (THIS FILE). [done]
2. ch22 examples: `k8s/scaling/` HPA (autoscaling/v2) + load generator + minikube overlay;
   `openshift/wadm-scaled.yaml`; verify/capture scripts (source k8s/lib.sh, openshift/lib.sh);
   chmod 755, bash -n.
3. ch23 crate + manifests:
   - `kafka-handler/` crate (local wit `wasmcloud:messaging/handler@0.2.0` + cargo-contract path-dep;
     build.sh; committed bindings.rs).
   - HTTP half: `install-keda.sh` (KEDA 2.21.0 + HTTP add-on 0.16.0 Helm, pinned), HTTPScaledObject,
     overlay, verify/capture (minikube raw shim).
   - Kafka half: `install-strimzi.sh` (Strimzi 1.3.0/Kafka 4.1.0) + Kafka/KafkaTopic CRs (multi-
     partition); `k8s/wasmcloud/` minikube wasmCloud-platform (chart 0.1.2, host 1.9.1) +
     WasmCloudHostConfig + messaging-kafka provider + `wadm-kafka.yaml`; KEDA kafka ScaledObject
     (+ TriggerAuthentication if secured); producer-burst script; verify/capture (minikube + CRC).
   - CRC reuses openshift/ wasmCloud + CMA operator (pinned CSV) + Strimzi + wadm-kafka.
4. ch24 examples: `k8s/observability/` otel-lgtm Deployment+Service + shim-OTel env (enable-shim-otel.sh)
   + overlay; `openshift/` minimal rootless OTel collector + wasmcloud-host-otel patch; verify/capture
   (exec-based queries).
5. Six diagrams (.py→.svg+.excalidraw, light #f1f5f9): 22-hpa-two-substrates, 22-cold-start-scaling-math;
   23-two-keda-models (http-drives vs kafka-observes), 23-kafka-lag-flow; 24-otel-two-emitters-pipeline,
   24-signal-provenance.
6. Author ch22/ch23/ch24 prose (structure + verbatim code/manifests; live-output placeholders filled
   in step 9 after verify).
7. CI: `examples` job +1 build (kafka-handler) + drift path; `k8s-manifests` job + Strimzi/KEDA/
   wadm-kafka/HTTP/otel kustomize+kubeconform. `validate` unchanged.
8. Plans: decisions DRQ-066..073; version-matrix pins (survey date 2026-10-21); build-plan r06d +
   Part 5 COMPLETE.
### LIVE-VERIFY (USER-GATED, one cluster at a time)
9. minikube: metrics-server addon; ch22 HPA + ch23 HTTP(drives) + ch23 Kafka(wasmCloud, KEDA observes)
   + ch24 shim-OTel→otel-lgtm; commit evidence `k8s/evidence/<date>/`; `minikube delete`.
10. CRC: `crc start`; CMA + Strimzi + wasmCloud + OTel collector; ch22/23/24 CRC proofs; commit
    evidence `openshift/evidence/<date>/`; `crc stop`.
11. Flip footers to "verified live <date>"; paste verbatim evidence into chapters; re-run static gate;
    PR → CI green → squash-merge → update memory.

## Acceptance criteria (see decisions.md DRQ-066..073 for detail)
- contracts/wit unchanged; kafka-handler bindings in drift gate, not stale; examples (+1 build) and
  k8s-manifests jobs green.
- ch22: minikube HPA 1→N→1 under real in-cluster load; CRC wadm spreadscaler instance change, traffic 200.
- ch23 HTTP: minikube Deployment 0 → cold 200 after 0→1 + cold-start figure; CRC CMA installed + wadm 0↔N.
- ch23 Kafka: both clusters show KEDA ScaledObject reading lag + wadm-owned handler instances changing on
  a producer burst; lag confirmed via kafka-consumer-groups.sh through exec; NO port-forward.
- ch24: both clusters show a real trace + metric series + log line retrieved via exec (no port-forward,
  no UI); minikube otel-lgtm, CRC rootless collector under restricted-v2.
- ch22-24 ≥2000w, ≥2 committed diagrams each, spine/voice/0-ban-tier/{% raw %}; scripts chmod 755 + bash -n;
  footers flipped only after both PASSes; box clean after.

## Risks
- HPA no-signal on tiny Wasm (minikube) → sustained load + 50m CPU request; honest report, never fake.
- KEDA partition ceiling (replicas ≤ partitions) → multi-partition topic.
- KEDA HTTP cold-start flakiness → bounded retry, assert real 200.
- wasmCloud-on-minikube bring-up (new path) → mirror r06b; readiness=real-200.
- otel-lgtm not restricted-v2-safe on CRC → already dropped for a rootless collector (Decision B).
- Iteration size (large) → kept as one (Decision C); checkpoint-commit per step.

## Pins (survey-confirm at kickoff; 2026-10-21 confirmed-live)
KEDA 2.21.0 · HTTP add-on 0.16.0 · CRC CMA CSV (TBD) · metrics-server minikube addon (~0.9.0) ·
Strimzi 1.3.0 / Kafka 4.1.0 · messaging-kafka provider tag (TBD, host-1.9.1-compatible) ·
wasmcloud-platform chart 0.1.2 / host 1.9.1 (now minikube too) · otel-lgtm 0.33.1 (minikube) ·
otel/opentelemetry-collector[-contrib] tag (TBD, CRC) · reused: shim v0.6.1, minikube 1.39.0 /
k8s 1.37.1, kubeconform 0.8.0, httpserver 0.27.0.
