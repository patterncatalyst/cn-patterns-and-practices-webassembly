---
title: "Deploying on minikube"
order: 18
part: "Deploying to Kubernetes"
description: "Running the same cargo wasi:http component as a real Pod on minikube, scheduled onto the runwasi containerd-shim-wasmtime shim by a RuntimeClass, and proved live through ingress-nginx."
duration: "17 min read"
---

## Learning objectives

By the end of this chapter you can:

- Trace the packaging pipeline that turns `app.wasm` into a schedulable Kubernetes workload: `wac plug` recompose, a `FROM scratch` OCI image built with `docker build --provenance=false`, and `minikube image load` standing in for a registry push/pull.
- Explain what a `RuntimeClass` with `handler: wasmtime` does, and how `install-shim.sh` wires the matching `io.containerd.wasmtime.v1` runtime registration into the node's `/etc/containerd/config.toml` before any Pod can reference it.
- State why `minikube ssh` piped a heredoc hangs, and why copying a script in with `minikube cp` and running `sudo bash <file>` is the fix.
- Name the ordering constraint between installing the shim and enabling the ingress addon, and what breaks if it's skipped.
- Explain why a rollout reporting `Ready` is not proof a Wasm Pod is serving traffic, and what signal `verify-minikube.sh` waits on instead.
- Walk the live request path from a `curl` against a `nip.io` hostname through ingress-nginx, a Service, a Pod, and the containerd shim into `app.wasm`'s `wasi:http/incoming-handler` export, with no port-forward anywhere in the chain.

## Why this matters

Chapter 17 described, in the abstract, how a Wasm-aware container runtime and a `RuntimeClass` let a component run as a Kubernetes Pod without a Linux userland in its image. This chapter is where that description becomes a live cluster. The exact `app.wasm` this site has carried since Part 2 (the Rust `cargo` provider, wac-plugged under the Part 3 `http-rust` front door, sha256 `eff7f5ee…`, the identical bytes Chapter 14 ran under `wasmtime serve` and Chapter 15 deployed to a wasmCloud lattice) now runs as one Pod on a real minikube cluster, reached through a real ingress-nginx edge, with zero lines of that component changed.

What's new here isn't the component; it's everything that has to exist around it before Kubernetes will schedule a `~290 KiB` Wasm binary the same way it schedules a container image. That means a packaging step that wraps the component in an OCI image with nothing else in it, a shim that teaches containerd a second way to run a workload besides `runc`, and a `RuntimeClass` that tells the scheduler which Pods want that second way. None of that infrastructure is wasmCloud's lattice from Chapter 15: there's no NATS, no `wadm`, no capability provider, no link. This is the more vendor-neutral of the two paths this site's Part 5 covers, a raw containerd shim plus a `RuntimeClass`, the same mechanism any Wasm workload on any containerd-backed cluster can use, with no additional control plane required.

Every claim below is cited against `examples/part5-kubernetes/` and against a live, headless run captured on 2026-10-21: `examples/part5-kubernetes/k8s/evidence/2026-10-21/*.txt`. The versions, the exact `curl` output, and the exact pod state quoted here are that run's real output, not a description of what minikube and containerd are supposed to do.

{% include excalidraw.html file="18-minikube-request-path" alt="A curl request to cargo.192.168.49.2.nip.io resolving via public nip.io DNS, then flowing through the ingress-nginx controller, a ClusterIP Service, a Pod labeled runtimeClassName wasmtime, into the containerd-shim-wasmtime process running a hyper server on 0.0.0.0:8080, and finally into app.wasm's wasi:http/incoming-handler export. A note states no port-forward, no NodePort, no minikube service anywhere in this path." caption="Figure 18.1: the live request path on minikube, host to nip.io Ingress to Service to Pod to the containerd wasmtime shim to app.wasm, with no tunnel anywhere in the chain." %}

## The same app.wasm, wrapped for a scheduler instead of a process

`examples/part5-kubernetes/build.sh` does not rebuild the component from scratch or fork any upstream crate. It reuses the exact Part 2/Part 3 recipe this site has used since Chapter 11: the Part 2 Rust `cargo` provider, built with `cargo component build --release`, wac-plugged under the Part 3 `http-rust` front door:

```
part2 rust provider  (exports patterncatalyst:cargo/*)
     +                 -> wac plug ->  app.wasm  (exports wasi:http/incoming-handler)
part3 http-rust       (imports patterncatalyst:cargo/*, exports wasi:http)
```

That single `app.wasm` is the artifact every runtime in Part 4 and Part 5 shares. `k8s/evidence/2026-10-21/06-sha256.txt` records the exact hash from this run:

```
$ sha256sum .../examples/part5-kubernetes/app.wasm
eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3  .../app.wasm
```

That's the same prefix Chapter 16's byte-identity proof cites for Chapters 14 and 15. The component crossing into Kubernetes here is not a Kubernetes-specific rebuild; it's the identical file, wrapped in a new container around it.

That wrapping is the entire job of `build.sh`'s image step and the `Dockerfile` next to it. The Dockerfile is about as thin as an OCI image gets:

```dockerfile
FROM scratch
COPY app.wasm /app.wasm
ENTRYPOINT ["/app.wasm"]
```

`FROM scratch` means there is no base layer at all: no glibc, no shell, no package manager, nothing a Wasm component needs because it never runs as a Linux process in the traditional sense. The runwasi shim mounts this image's rootfs, reads the OCI config's command, and loads whatever file that command points to as a Wasm component directly. The whole image is the ~290 KiB component plus OCI metadata, which is the entire point of running a component instead of a container with a language runtime baked in: there's no userland to patch, scan, or carry forward between releases, because there isn't one.

Building that image is one `docker build` call, but one flag on it changes whether the next step works at all:

```bash
docker build --provenance=false -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
```

By default, BuildKit attaches a provenance attestation manifest and turns a single-image build into a manifest list with more than one entry. The shim doesn't need that attestation data, and more importantly, a manifest list complicates exactly the step that comes next: `minikube image load`'s and `ctr run`'s platform resolution, which expects one plain manifest to pick from, not a list it has to disambiguate. `--provenance=false` keeps the build at a single manifest, and that's what makes the load step below unambiguous.

With the image built, `minikube image load "$IMAGE" -p "$PROFILE"` copies it directly into the node's containerd image store. There is no registry anywhere in this path: no push, no pull, no credentials to manage. `k8s/overlays/minikube/kustomization.yaml` retags the Deployment's image to `:minikube` (the exact tag `build.sh` produces and `minikube image load` loads) and patches `imagePullPolicy` to `Never`, so the kubelet never attempts a pull for an image that exists only in that one cluster's local store. Skip either half, the retag or the pull policy, and the Deployment sits in `ImagePullBackOff` indefinitely, because the kubelet's default pull policy would try, and fail, to find `cargo-http-wasm:minikube` on any registry.

## RuntimeClass and the containerd shim: a second way to run a Pod

A vanilla minikube node only knows how to run one kind of workload: a container, scheduled onto `runc`. Running a Wasm component as a Pod means giving containerd a second runtime it can hand a Pod to, and giving the scheduler a way to say which Pods want it. That's exactly what a `RuntimeClass` is for. `k8s/base/runtimeclass.yaml` is four lines of substance:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: wasmtime
handler: wasmtime
```

The `handler` field has to match, verbatim, the runtime key `install-shim.sh` registers in the node's `/etc/containerd/config.toml`. `k8s/evidence/2026-10-21/02-runtimeclass.txt` captures both halves of that match from the live run: the applied `RuntimeClass`, and the containerd config entry it points at.

```yaml
apiVersion: node.k8s.io/v1
handler: wasmtime
kind: RuntimeClass
metadata:
  name: wasmtime
```

```
# containerd runtime registration on the node (config.toml)
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.wasmtime]
          runtime_type = "io.containerd.wasmtime.v1"
```

containerd resolves a CRI runtime of type `io.containerd.wasmtime.v1` to a binary named `containerd-shim-wasmtime-v1` on its `PATH`. `install-shim.sh` downloads that exact binary, the runwasi `containerd-shim-wasmtime` release pinned at `v0.6.1`, checksum-verified against the SHA256 published in the release's own `SHA256SUMS` before anything is installed, and puts it at `/usr/bin/containerd-shim-wasmtime-v1` on the node. `k8s/evidence/2026-10-21/00-versions.txt` shows the binary in place after the run:

```
$ minikube ssh -- containerd --version ; shim binary on node
containerd containerd v2.3.4 db8809540e1a7a9da5d518876894933ff55692ab
-rwxr-xr-x. 1 root root 32724488 Oct 21 14:17 /usr/bin/containerd-shim-wasmtime-v1
```

Once that binary exists and the runtime is registered, a Deployment that sets `runtimeClassName: wasmtime` gets scheduled onto the shim instead of `runc`. `k8s/base/deployment.yaml`'s `command: ["/app.wasm"]` is the module path inside the scratch rootfs that the shim loads, the same path `ENTRYPOINT` sets in the Dockerfile, kept in both places so a plain `ctr run <image> <id>` smoke test works with no extra arguments too. Readiness and liveness probes are plain `tcpSocket` checks on port 8080, not an HTTP probe, because the component answers `GET /` with a 404 (only `/cargo/{id}` is a route); a TCP probe is the correct liveness signal here, and the real HTTP assertion lives in the verification script, covered below.

The shim itself detects that `app.wasm` targets the `wasi:http/proxy` world and runs it behind a built-in hyper server listening on `0.0.0.0:8080` inside the Pod, the identical behavior `wasmtime serve` provides as a standalone process in Chapter 14. The component doesn't know, and doesn't need to know, that the process serving it this time is a containerd shim instead of a CLI invocation.

One gotcha matters here: the shim binary is a containerd shim, not a CLI tool. Invoking it with `--version`, or any flag it doesn't define, panics with `flag provided but not defined`. `install-shim.sh` confirms the binary is in place with `ls`, not `--version`, and lets the running Pod be the real proof the installation worked.

## Copying a script in, not piping it over SSH

`install-shim.sh`'s containerd config edit has to run as root inside the minikube node, and the obvious approach (`minikube ssh -p "$PROFILE" -- "sudo bash -s" <<'EOF' ... EOF`) doesn't work. `minikube ssh` allocates a PTY for the session, and a heredoc piped to `sudo bash -s` over that PTY never receives an EOF signal once the work finishes; the session just hangs. The fix sidesteps the PTY-stdin problem entirely: `minikube cp` copies the node script into the VM as a real file, and the SSH call runs `sudo bash /tmp/register-wasmtime-runtime.sh` against that file instead of streaming a script over stdin.

```bash
minikube cp "$NODE_SCRIPT" "$PROFILE:/tmp/register-wasmtime-runtime.sh" -p "$PROFILE"
minikube ssh -p "$PROFILE" -- "sudo bash /tmp/register-wasmtime-runtime.sh && sudo rm -f /tmp/register-wasmtime-runtime.sh"
```

The node script itself is idempotent: it `grep`s the config for `containerd.runtimes.wasmtime]` before editing anything, so re-running `install-shim.sh` against a cluster that already has the runtime registered is a no-op rather than a duplicate block. When it does need to edit, it backs up the config file with a timestamped suffix first, inserts the new runtime block right after the CRI runtimes table header with `awk`, then restarts containerd and polls `ctr version` for up to 30 seconds to confirm the daemon came back before returning control to the caller.

{% include excalidraw.html file="18-build-package-load-deploy" alt="A pipeline diagram: the Part 2 Rust cargo provider and Part 3 http-rust front door feed into a wac plug step producing app.wasm; app.wasm feeds into a docker build with provenance disabled producing a single-manifest scratch OCI image; that image feeds into minikube image load, which copies it straight into the node's containerd store with no registry; in parallel, install-shim.sh downloads and verifies the shim, registers the runtime, restarts containerd, and applies the RuntimeClass, explicitly BEFORE the ingress addon is enabled; kubectl apply -k overlays/minikube then schedules a Pod with runtimeClassName wasmtime onto the installed shim; a final note states readiness is a real HTTP 200, not a rollout Ready, because the ingress default backend answers 404 for an unmatched host during its asynchronous config reload." caption="Figure 18.2: the build, package, load, and deploy pipeline, the same wac-plug recompose Part 3 used, now wrapped for a scheduler instead of a process, with shim install ordered before the ingress addon." %}

## Ordering: install the shim before you enable ingress

`install-shim.sh`'s containerd restart doesn't just affect the one Pod being newly scheduled. Restarting containerd bounces every Pod already running on the node, because the container runtime underneath all of them momentarily disappears and comes back. `verify-minikube.sh` orders its steps around that fact: it installs the shim and applies the `RuntimeClass` in Step 3, and only enables the `ingress` minikube addon in Step 3b, after the restart has already happened and settled.

Reverse that order, enabling ingress first and installing the shim second, and the ingress-nginx controller Pod that just finished starting gets bounced by the containerd restart moments later, forcing it to come back up a second time before it's ready to route anything. It's not a fatal ordering mistake, but it adds a flaky extra reconciliation window right where the verification script needs the controller to be stable, for no benefit. Doing the disruptive thing (installing the shim) before the thing that depends on a quiet node (bringing up the ingress controller) avoids that churn entirely.

## Readiness is a real HTTP 200, not a rollout reporting Ready

This is the gotcha most worth internalizing, because it's easy to trust the wrong signal. A Kubernetes rollout reporting `deployment "cargo-http" successfully rolled out` and an Ingress reporting a non-empty `ADDRESS` column both look like "done." Neither one, by itself, proves the component is answering requests through the full path.

The reason is ingress-nginx's own default-backend behavior. Its configuration reload is asynchronous, typically a matter of seconds after an Ingress is applied or patched, and during that window any request for a host it doesn't yet recognize gets routed to the controller's generic default backend, which answers with its own `404`. To a plain `curl` checking only for a non-5xx response or a connection that completes, that looks like a legitimate completed response from the real application, not a sign that the real routing rule hasn't taken effect yet.

`verify-minikube.sh` closes that gap with a deterministic signal instead of a fixed sleep. `k8s/base/ingress.yaml` sets a session-affinity cookie:

```yaml
annotations:
  nginx.ingress.kubernetes.io/affinity: "cookie"
  nginx.ingress.kubernetes.io/session-cookie-name: "part5-cargo-affinity"
```

That cookie is stamped only on responses that went through this Ingress's own matched rule; it's never set by the default backend's look-alike 404. So the script polls for the cookie first, and only trusts a subsequent `200` once it sees that cookie confirming the real rule is live:

```bash
while (( waited < 90 )); do
  if curl -sS -D - -o /dev/null "http://$CARGO_HOST$VALID_PATH" 2>/dev/null | grep -qi "part5-cargo-affinity"; then
    ok=1; break
  fi
  sleep 2; waited=$(( waited + 2 ))
done
```

Only after that gate passes does the script call `wait_for_200`, which polls until the URL returns an actual `200`, not merely a response. That two-stage gate, first the affinity cookie proving the rule matched, then a real `200` proving the component answered, is what "readiness" means in this example, and it's a stricter bar than `kubectl rollout status` checks for on its own.

## The request path, live

The whole chain this chapter builds toward is one `curl`, and `k8s/evidence/2026-10-21/05-http.txt` is the live transcript of it going all the way through:

```
# request path: host -> ingress-nginx -> Service cargo-http:8080 -> Pod -> shim -> app.wasm
$ curl -s http://cargo.192.168.49.2.nip.io/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -o /dev/null -w %{http_code} http://cargo.192.168.49.2.nip.io/cargo/NOPE
404
```

That's the same JSON shape and the same `404`-for-an-unbooked-id behavior this site's domain has produced since Part 2, now served from a Pod reached through a real ingress edge rather than a local process. `cargo.192.168.49.2.nip.io` is not a placeholder: `192.168.49.2` is the real IP `minikube ip -p part5` returned on this run (`k8s/evidence/2026-10-21/01-nodes.txt` confirms the node's `INTERNAL-IP` matches), and `nip.io` is a public wildcard DNS service that resolves `<anything>.<ip>.nip.io` straight to `<ip>` with no record to provision. The URL's own authority is simultaneously a real, publicly resolvable hostname and the exact host rule the Ingress is matching on: no `/etc/hosts` edit, no `minikube tunnel`, no NodePort, and no `minikube service` shortcut anywhere in this verification. House convention on this site is that an ingress path gets proven through the ingress, not around it.

`k8s/evidence/2026-10-21/04-pods.txt` shows the Pod on the other end of that chain, scheduled onto the shim exactly as designed:

```
$ kubectl get pods -n part5-kubernetes -o wide
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE    NOMINATED NODE   READINESS GATES
cargo-http-6f4fc58fbb-ns28x   1/1     Running   0          7s    10.244.0.6   part5   <none>           <none>

$ kubectl describe pod (RuntimeClass + node)
Name:                cargo-http-6f4fc58fbb-ns28x
Runtime Class Name:  wasmtime
Node:                part5/192.168.49.2
Status:              Running
    Image:         cargo-http-wasm:minikube
      Started:      Wed, 21 Oct 2026 10:17:53 -0400
    Ready:          True
```

`Runtime Class Name: wasmtime` on a `1/1 Running` Pod is the direct confirmation that this specific Pod is running under the shim, not `runc`: the mechanism this whole chapter exists to wire up, stated back by `kubectl` itself. The full version matrix this run confirms, pulled from `k8s/evidence/2026-10-21/00-versions.txt` and the README's pin table: minikube `v1.39.0` (docker driver, containerd runtime), Kubernetes `v1.37.1`, containerd `v2.3.4` on the node, the runwasi shim at `v0.6.1`, and the `ingress-nginx` addon's controller at `v1.15.1`.

**Verified live 2026-10-21 (minikube v1.39.0 / Kubernetes v1.37.1 / containerd-shim-wasmtime v0.6.1).** This is one of two cluster paths this site tests headless with equal weight. Chapter 19 takes the identical component to OpenShift Local (CRC): the same `app.wasm`, a different operator-managed story for getting a Wasm-aware runtime onto the node, and a Route in place of this chapter's Ingress.

Run the whole proof directly:

```bash
examples/part5-kubernetes/k8s/verify-minikube.sh --keep
```

`--keep` leaves the `part5` profile running afterward for inspection with `kubectl`; omit it and the script deletes the profile on exit regardless of pass or fail. `capture-evidence.sh` is the headless variant that writes the committed `evidence/<date>/` files this chapter quotes from, and `teardown.sh` removes the profile (or just the app, with `--app-only`) when you're done.

The go/no-go question this example answers, whether the raw runwasi shim would serve the component without hitting a known feature gap (runwasi issue #1004 was the risk this project tracked going in), resolved clean on the first run. The shim served the component with no wall hit, so this is the mechanism Part 5 uses here; a wasmCloud-operator-based fallback was not needed for this component.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Two choices in this chapter's scripts exist to answer a question a container-image workflow never has to ask. First, the packaging path: a component has no language runtime and no OS userland to carry, so wrapping it in a full multi-stage container build would be solving a problem that doesn't exist here. A <code>FROM scratch</code> image with one <code>COPY</code> is the correct amount of packaging for a ~290 KiB artifact, and <code>--provenance=false</code> exists only because BuildKit's default attestation manifest complicates the one thing that matters afterward: unambiguous platform resolution for <code>minikube image load</code> and the shim. Second, the shim-install ordering: install-shim.sh's containerd restart bounces every Pod on the node, so it runs before the ingress addon is enabled rather than after, trading a theoretical few seconds of idle time for avoiding a second, flaky ingress-controller reconciliation right when the verification script needs that controller stable. The third and most important lesson generalizes past this one example: a rollout reporting <code>Ready</code> and an Ingress reporting an address are necessary conditions, not sufficient ones, because ingress-nginx's default backend can mimic a real response during an asynchronous config reload. The only thing worth trusting is a real HTTP 200 behind a signal, here a cookie that is never stamped by the default backend, that proves the right rule, not a look-alike, matched.</p></div>

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the `RuntimeClass`, Deployment, and readiness-probe vocabulary this chapter's manifests build on, and the general pattern of making a scheduler aware of a workload's special requirements.
- Brendan Burns, Joe Beda, Kelsey Hightower & Lachlan Evenson, *Kubernetes: Up and Running*, 3rd ed. (O'Reilly, 2022): the CRI/containerd runtime-shim model this chapter's `RuntimeClass` and `install-shim.sh` depend on, and how the kubelet resolves a Pod's `runtimeClassName` to a concrete runtime.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model treatment of why a single component built once can run unmodified under a containerd shim, a standalone `wasmtime serve` process, and a wasmCloud lattice.
- Shashank Jain, *WebAssembly for Cloud* (Apress): deployment-topology coverage for running Wasm workloads on container-orchestration platforms, the same ground this chapter covers for minikube specifically.
- [runwasi](https://github.com/containerd/runwasi): the containerd-shim-wasmtime project this chapter pins at `v0.6.1`, including the shim's `wasi:http/proxy`-world detection this chapter's hyper-server behavior depends on.
- [containerd RuntimeClass documentation](https://kubernetes.io/docs/concepts/containers/runtime-class/): the canonical description of how a `RuntimeClass`'s `handler` field maps to a CRI runtime registration, the mechanism this chapter's `02-runtimeclass.txt` evidence confirms end to end.
- Chapter 17, "Wasm on Kubernetes": the conceptual treatment of a Wasm-aware container runtime and RuntimeClass this chapter puts on a real cluster.
- Chapter 19, "OpenShift Local (CRC)": the same component, the same contract, a different operator-managed path to a Wasm-aware runtime and a Route in place of this chapter's Ingress.
