# Verification log

Live-run evidence, version pins, and go/no-go notes moved here from the chapter
bodies. The reader-facing chapters now carry a `## Build, run, observe` section
pointing at each example's verify script instead; the detailed run records stay
here. The `plans` collection is `output: false`, so this file is not published.

## 15-wasmcloud.md

Verified live (2026-10-21, wash 0.43.0 / wasmcloud host 1.9.1). Every transcript
in the chapter was quoted verbatim from
`examples/part4-runtimes/wasmcloud/evidence/2026-10-21/`: `00-wash-version.txt`,
`01-wash-up.txt`, `01b-wash-hosts.txt`, `03-deploy.txt`, `03b-app-status.txt`,
`03c-inventory.txt`, `04-http.txt`, `05-resilience.txt`. `capture-evidence.sh`
ran the full sequence headlessly: `wash up -d`, `./build.sh`, `wash app deploy
wadm.yaml` (gated on a real 200, not just `Deployed` status), the HTTP
assertions, the scale-to-zero/self-heal resilience drill, and a `sha256sum
app.wasm` recorded for Chapter 16's same-bytes proof
(`eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3`), every
assertion backed by `set -e` and a secret scrub confirming zero credential
material in the committed evidence.

## 18-deploying-on-minikube.md

Verified live 2026-10-21 (minikube v1.39.0 / Kubernetes v1.37.1 /
containerd-shim-wasmtime v0.6.1). One of two cluster paths tested headless with
equal weight (Chapter 19 is the CRC path). Full version matrix, from
`k8s/evidence/2026-10-21/00-versions.txt` and the README pin table: minikube
v1.39.0 (docker driver, containerd runtime), Kubernetes v1.37.1, containerd
v2.3.4 on the node, the runwasi shim at v0.6.1, the ingress-nginx addon
controller at v1.15.1. Go/no-go: whether the raw runwasi shim would serve the
component without hitting a known feature gap (runwasi issue #1004 was the
tracked risk) resolved clean on the first run; no wasmCloud-operator fallback was
needed.

## 19-openshift-local-crc.md

Verified live 2026-10-21 (CRC 2.64.0 / OpenShift 4.22.14 / wasmcloud host
1.9.1), evidence under `examples/part5-kubernetes/openshift/evidence/2026-10-21/`.
Every command, version pin, and byte of JSON quoted in the chapter came from that
run. Three version pins, recorded in `lib.sh` and confirmed by
`evidence/2026-10-21/00-versions.txt`: the chart OCI ref, the operator image, and
the httpserver provider tag. The chart's bundled host subchart defaults to
version 1.2.1 (`APP VERSION` column).

## 21-ambassador-and-adapter-patterns.md

Both patterns verified live as of 2026-10-21: the adapter on minikube
(`k8s/evidence/2026-10-21/14-adapted-http.txt`) and on CRC
(`openshift/evidence/2026-10-21/15-adapted-http.txt`); the ambassador
cluster-live on CRC (`openshift/evidence/2026-10-21/16-ambassador-http.txt`, plus
the negative control in `wadm-ambassador-nogrant.yaml`) and as a local
minikube-adjacent smoke (`k8s/evidence/2026-10-21/15-ambassador-localserve.txt`).

## 22-scaling-wasm-workloads-hpa.md

The minikube HPA half was verified live 2026-10-21, evidence under
`k8s/evidence/2026-10-21/`: the HPA reads real CPU and the workload never
triggers a scale-out (the teaching point). The CRC half (`verify-scaling-crc.sh`)
was pending live verification: a gated, headless script of the identical design,
evidence to land under `openshift/evidence/<date>/` once run.

## 23-serverless-wasm-scale-to-zero-keda.md

HTTP half on minikube verified live 2026-10-21 (evidence under
`k8s/keda/evidence/2026-10-21/`). Kafka half on minikube verified live 2026-10-22
(evidence under `k8s/keda/evidence/2026-10-22/`). The HTTP cold-start figure is
measured from the 2026-10-21 run; the Kafka timeline from the 2026-10-22 run. The
Kafka half's CRC port (`openshift/verify-keda-kafka-crc.sh`) is author-only, not
wired to a live wadm app, and deferred.

## 24-observability-on-cluster.md

Both halves were pending live verification at the time the chapter was written;
the LIVE-OUTPUT placeholders in the body marked where a live cluster's numbers
belong. `verify-otel-minikube.sh` (shim-OTel enable, redeploy, Tempo/Prometheus/
Loki query via `kubectl exec`) and `openshift/verify-otel-crc.sh` (collector
apply, WasmCloudHostConfig patch, dual `oc logs`/`oc exec` cross-check of trace/
metric/log) are the scripts to run; evidence lands under each path's
`evidence/<date>/`.

## 25-istio-and-webassembly.md

Both halves verified live 2026-10-22. The minikube path ran against a running
cluster (minikube IP 192.168.49.2, ingress gateway NodePort 30920); evidence
under `examples/part6-deviations/istio/evidence/2026-10-22/`. The CRC path, on
OpenShift Service Mesh 3 (the Sail operator, Istio v1.26.2, which lags the
upstream v1.31.2 the minikube path uses), ran through an edge-TLS Route; OSSM does
not provision an ingress gateway on its own, so one was deployed via gateway
injection (`openshift/ingress-gateway.yaml`).

## 26-wasm-for-other-backend-architectures.md

Both halves verified live 2026-10-22: the minikube SpinKube path (the SpinApp on
`containerd-shim-spin` v0.26.0 / RuntimeClass `wasmtime-spin-v2`, through the
nip.io ingress) and the CRC path (the Spin runtime in a restricted-v2 container,
through a CA-verified edge-TLS Route), each serving the exact cargo JSON and a
404. Evidence under `spinkube/evidence/2026-10-22/` and
`spinkube/openshift/evidence/2026-10-22/`; both captured with `capture-evidence.sh`
(versions, live manifests, HTTP proof, component sha256), scrubbed of credential
material.

## 27-wasi-nn.md

Verified live 2026-10-22. `build.sh` compiled the component and asserted its WIT
surface (exact imports, the `wasi:cli/run` export, nothing outside `wasi:*`) with
no OpenVINO install required for that pass. The live inference ran against
wasmtime v50.0.0 built from source with `--features wasi-nn` and OpenVINO
2026.4.1, over the checksummed MobileNet fixture and the committed `cargo.jpg`:
top class `container ship, containership, container vessel` at 0.910, ahead of
`alp`, `space shuttle`, `lifeboat`. Evidence under
`examples/part6-deviations/wasi-nn/evidence/2026-10-22/`.

## 28-final-project.md

Verified live 2026-10-22 on both clusters. On minikube, both composites ran on
the containerd-shim-wasmtime and answered byte-identical cargo JSON (and 404 on
an unknown id) through ingress-nginx; the Chapter 25 proxy-wasm gateway filter
enforced the `x-cargo-tenant` contract (403 without, 200 plus
`x-cargo-filtered-by` with) for both languages; the shim exported traces for the
workload into Tempo. Evidence under
`examples/part7-final-project/evidence/2026-10-22/`. On CRC, both composites,
deployed by the wasmCloud operator as two Applications (`cargo-final-rust`,
`cargo-final-go`) behind their own edge-TLS Routes, answered byte-identical cargo
JSON and 404, CA-verified against the cluster ingress CA with no `-k`,
port-forward, or NodePort. Evidence under
`examples/part7-final-project/openshift/evidence/2026-10-22/`.
