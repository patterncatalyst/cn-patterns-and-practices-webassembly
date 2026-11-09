---
title: "Deploying on minikube"
order: 18
part: "Deploying to Kubernetes"
description: "Running the cargo wasi:http component as a Pod on minikube, scheduled onto the containerd-shim-wasmtime shim by a RuntimeClass and reached through ingress-nginx."
duration: "15 min read"
---

## Learning objectives

By the end of this chapter you can:

- Package `app.wasm` as a `FROM scratch` OCI image built with `docker build --provenance=false`, and load it with `minikube image load` instead of a registry.
- Wire a `RuntimeClass` with `handler: wasmtime` to the shim that `install-shim.sh` registers in the node's containerd config.
- Copy a node script in with `minikube cp` instead of piping a heredoc over `minikube ssh`, and say why.
- Order the shim install before the ingress addon, and say what breaks otherwise.
- Gate readiness on a real HTTP 200 behind an affinity cookie rather than on a rollout reporting `Ready`.
- Trace a `curl` against a `nip.io` host through ingress-nginx, a Service, a Pod and the shim into `app.wasm`, with no port-forward.

## Why this matters

The component doesn't change here. The `app.wasm` built from the Rust `cargo` provider plugged under the `http-rust` front door (sha256 prefix `eff7f5ee`) is the same bytes that ran under `wasmtime serve` and on a wasmCloud lattice. What needs to exist is everything around it before Kubernetes schedules a ~290 KiB Wasm binary like a container image: an OCI image with nothing else in it, a shim that gives containerd a second way to run a workload, and a `RuntimeClass` that tells the scheduler which Pods want it.

No NATS, `wadm`, capability provider or link is involved. This is the vendor-neutral path: a raw containerd shim plus a `RuntimeClass`, usable on any containerd-backed cluster with no extra control plane.

| Tool | Version |
| --- | --- |
| minikube | v1.39.0, docker driver, containerd runtime |
| Kubernetes | v1.37.1 |
| containerd (in the node) | v2.3.4 |
| runwasi `containerd-shim-wasmtime` | v0.6.1 |
| ingress-nginx (minikube addon) | controller v1.15.1 |

The output quoted below comes from a headless run recorded under `examples/part5-kubernetes/k8s/evidence/2026-10-21/`.

{% include excalidraw.html file="18-minikube-request-path" alt="A curl request to cargo.192.168.49.2.nip.io resolves through public nip.io DNS, then flows through the ingress-nginx controller, a ClusterIP Service, and a Pod with runtimeClassName wasmtime into the containerd-shim-wasmtime process running a hyper server on 0.0.0.0:8080, and finally into the wasi:http/incoming-handler export of app.wasm. A note says there is no port-forward, NodePort or minikube service anywhere in the path." caption="Figure 18.1: The live request path on minikube: host to nip.io Ingress to Service to Pod to the containerd wasmtime shim to app.wasm, with no tunnel." %}

## Wrap the component for a scheduler

`build.sh` doesn't rebuild or fork anything. It reuses the recipe that produced the component earlier: build the `cargo` provider with `cargo component build --release`, then `wac plug` it under the `http-rust` front door. The OCI image around it is as thin as an image gets:

```dockerfile
FROM scratch
COPY app.wasm /app.wasm
# The shim uses the OCI command/args to locate the module in the rootfs. The
# Deployment overrides this with an explicit `command: ["/app.wasm"]`, but we
# set it here too so `ctr run <image> <id>` (the go/no-go smoke test) works with
# no extra args.
ENTRYPOINT ["/app.wasm"]
```

`FROM scratch` means no base layer: no glibc, no shell, no package manager. The shim mounts the rootfs, reads the OCI command, and loads that file as a Wasm component directly. There is no userland to patch, scan or carry between releases.

Building it is one call, and one flag decides whether the next step works:

```bash
  docker build --provenance=false -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
```

BuildKit by default attaches a provenance attestation and turns the build into a manifest list. The shim doesn't need it, and `minikube image load` and `ctr run` resolve a platform from one plain manifest more reliably than from a list.

`minikube image load "$IMAGE" -p "$PROFILE"` then copies the image into the node's containerd store, with no registry, push, pull or credentials. The `minikube` overlay retags the Deployment's image to `:minikube` and patches `imagePullPolicy` to `Never`, so the kubelet never looks for the image on a registry. Skip either half and the Deployment sits in `ImagePullBackOff`.

{% include excalidraw.html file="18-build-package-load-deploy" alt="A pipeline: the Rust cargo provider and the http-rust front door feed a wac plug step that produces app.wasm; a docker build with provenance disabled produces a single-manifest scratch OCI image; minikube image load copies it into the node's containerd store with no registry. In parallel, install-shim.sh downloads and verifies the shim, registers the runtime, restarts containerd and applies the RuntimeClass, before the ingress addon is enabled. kubectl apply -k overlays/minikube then schedules a Pod with runtimeClassName wasmtime onto the installed shim. A final note says readiness is a real HTTP 200, not a rollout Ready, because the ingress default backend answers 404 for an unmatched host while its configuration reloads." caption="Figure 18.2: Build, package, load and deploy: the wac plug recompose wrapped for a scheduler instead of a process, with the shim installed before the ingress addon." %}

## RuntimeClass and the shim

A stock minikube node runs one kind of workload, a container on `runc`. The `RuntimeClass` in `k8s/base/runtimeclass.yaml` (`name: wasmtime`, `handler: wasmtime`) names the second runtime, and its `handler` has to match the runtime key `install-shim.sh` registers in `/etc/containerd/config.toml`. The recorded node shows both halves of the match:

```
# containerd runtime registration on the node (config.toml)
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.wasmtime]
          runtime_type = "io.containerd.wasmtime.v1"
```

containerd resolves that runtime type to `containerd-shim-wasmtime-v1` on its `PATH`. `install-shim.sh` downloads the pinned release, verifies it against the SHA256 in the release's `SHA256SUMS`, and installs it at `/usr/bin`:

```
$ minikube ssh -- containerd --version ; shim binary on node
containerd containerd v2.3.4 db8809540e1a7a9da5d518876894933ff55692ab
-rwxr-xr-x. 1 root root 32724488 Oct 21 14:17 /usr/bin/containerd-shim-wasmtime-v1
```

A Deployment with `runtimeClassName: wasmtime` now lands on the shim instead of `runc`. Its `command: ["/app.wasm"]` is the module path in the scratch rootfs, the same path the Dockerfile's `ENTRYPOINT` sets, so a plain `ctr run <image> <id>` works too. The shim detects the `wasi:http/proxy` world and serves it behind a hyper server on `0.0.0.0:8080`, the behavior `wasmtime serve` provides as a standalone process.

Probes are `tcpSocket` checks on 8080, not HTTP probes, because the component answers `GET /` with a 404; only `/cargo/{id}` is a route.

The shim binary is not a CLI. `--version`, or any undefined flag, panics with `flag provided but not defined`. `install-shim.sh` confirms the binary with `ls` and treats the running Pod as the proof.

## Copy the node script in, don't pipe it

The containerd config edit must run as root inside the node. Piping a heredoc through `minikube ssh -- "sudo bash -s"` hangs: `minikube ssh` allocates a PTY, and a heredoc fed to `sudo bash -s` over it never receives EOF, so the session never returns. `install-shim.sh` copies the script in as a file and runs that:

```bash
minikube cp "$NODE_SCRIPT" "$PROFILE:/tmp/register-wasmtime-runtime.sh" -p "$PROFILE"
minikube ssh -p "$PROFILE" -- "sudo bash /tmp/register-wasmtime-runtime.sh && sudo rm -f /tmp/register-wasmtime-runtime.sh"
```

The node script is idempotent. It checks the config for `containerd.runtimes.wasmtime]` before editing, and if the runtime is registered it leaves the config alone and doesn't restart containerd. Otherwise it backs the file up with a timestamped suffix, inserts the runtime block after the CRI runtimes table header with `awk`, restarts containerd, and polls `ctr version` for up to 30 seconds until the daemon answers.

## Install the shim before enabling ingress

A containerd restart bounces every Pod on the node. `verify-minikube.sh` installs the shim and applies the `RuntimeClass` in Step 3, and enables the `ingress` addon in Step 3b, after the restart has settled. Reverse that and the ingress-nginx controller that just started is bounced moments later and has to come up again, adding a flaky reconciliation window exactly where the script needs the controller stable.

## Readiness is a real 200

A rollout reporting `successfully rolled out` and an Ingress with a non-empty `ADDRESS` both look like done. Neither proves the component answers. ingress-nginx reloads its configuration asynchronously, and until it does, a request for a host it doesn't yet know goes to the default backend, which answers with its own `404`. A check that only looks for a completed, non-5xx response takes that for the application.

The Ingress sets a session-affinity cookie to close the gap:

```yaml
  annotations:
    # Deterministic "my rule actually matched" signal: ingress-nginx stamps
    # this cookie only on responses that went through THIS Ingress rule, never
    # on its generic default-backend 404; verify-minikube.sh waits for it
    # before trusting the Ingress (a config reload is asynchronous).
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/session-cookie-name: "part5-cargo-affinity"
```

ingress-nginx stamps that cookie only on responses that matched this Ingress's own rule, never on the default backend's look-alike 404. `verify-minikube.sh` polls for the cookie first and only then trusts a `200`:

```bash
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "http://$CARGO_HOST$VALID_PATH" 2>/dev/null | grep -qi "part5-cargo-affinity"; then
    ok=1; break
  fi
  sleep 2; waited=$(( waited + 2 ))
done
```

Once the cookie shows, `wait_for_200` polls until the URL returns an actual `200`. Cookie first, then a real 200, is a stricter bar than `kubectl rollout status`.

## The request path, live

One `curl` exercises the whole chain:

```
# request path: host -> ingress-nginx -> Service cargo-http:8080 -> Pod -> shim -> app.wasm
$ curl -s http://cargo.192.168.49.2.nip.io/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -o /dev/null -w %{http_code} http://cargo.192.168.49.2.nip.io/cargo/NOPE
404
```

`192.168.49.2` is the IP `minikube ip -p part5` returned, and `nip.io` is a public wildcard DNS service that resolves `<anything>.<ip>.nip.io` to `<ip>`. The URL's authority is therefore both a resolvable hostname and the host rule the Ingress matches: no `/etc/hosts` edit, no `minikube tunnel`, no NodePort, no `minikube service`. An ingress path gets proven through the ingress, not around it.

The Pod on the other end shows it ran under the shim:

```
$ kubectl get pods -n part5-kubernetes -o wide
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE    NOMINATED NODE   READINESS GATES
cargo-http-6f4fc58fbb-ns28x   1/1     Running   0          7s    10.244.0.6   part5   <none>           <none>
```

`kubectl describe pod` on that Pod reports `Runtime Class Name: wasmtime` and `Ready: True`.

OpenShift Local runs the same component with a different, operator-managed way of getting a Wasm-aware runtime onto the node, and a Route in place of the Ingress.

> **Decision**
>
> Package a component as `FROM scratch` with one `COPY`: it has no language runtime or userland to carry, and `--provenance=false` keeps the manifest single so image loading is unambiguous. Install the shim before enabling the ingress addon, because the containerd restart bounces every Pod on the node. Treat `Ready` and an Ingress address as necessary, not sufficient: trust a real 200 behind a signal the default backend can't fake, here the affinity cookie.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s && ./verify-minikube.sh
```

Stop CRC first; one cluster runs at a time. The script starts the `part5` minikube profile, builds and loads the image, installs the shim, applies the overlay, patches the Ingress to a live `nip.io` host, and asserts a real 200 with the exact cargo JSON plus a 404 for an unknown id. Expect `PASS`. `--keep` leaves the profile up for `kubectl`, `./capture-evidence.sh` writes the `evidence/<date>/` files, and `./teardown.sh` deletes the profile (`--app-only` keeps it).

- Drop the retag or the `imagePullPolicy: Never` patch: the Deployment sits in `ImagePullBackOff` looking for `cargo-http-wasm:minikube` on a registry.
- Build without `--provenance=false`: the manifest list complicates image loading and platform resolution.
- Enable the ingress addon before installing the shim: the controller is bounced by the containerd restart and comes up twice.
- Check only for a non-5xx response instead of the cookie: the default backend's 404 can pass for the application during the reload.

## For deeper coverage

- Bilgin Ibryam and Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the `RuntimeClass`, Deployment and readiness-probe vocabulary the manifests build on, and making a scheduler aware of a workload's special requirements.
- Brendan Burns, Joe Beda, Kelsey Hightower and Lachlan Evenson, *Kubernetes: Up and Running*, 3rd ed. (O'Reilly, 2022): the CRI and containerd shim model, and how kubelet resolves a Pod's `runtimeClassName` to a runtime.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): why one component built once runs unmodified under a containerd shim, `wasmtime serve` and a wasmCloud lattice.
- Shashank Jain, *WebAssembly for Cloud* (Apress): deployment topologies for Wasm workloads on container orchestration platforms.
- [runwasi](https://github.com/containerd/runwasi): the `containerd-shim-wasmtime` project, including its `wasi:http/proxy` world detection.
- [Kubernetes RuntimeClass documentation](https://kubernetes.io/docs/concepts/containers/runtime-class/): how a `RuntimeClass` `handler` maps to a CRI runtime registration.
- Wasm on Kubernetes: the shim and `RuntimeClass` mechanism this deploy puts on a real cluster.
- OpenShift Local (CRC): the same component and contract, deployed through an operator-managed host and a Route.
