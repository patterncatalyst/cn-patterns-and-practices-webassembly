# Part 5 — running the cargo component on Kubernetes (minikube)

This example runs the **same** `wasi:http` component (`app.wasm`, sha256
`eff7f5ee…`) that `wasmtime serve` runs in Part 3 and wasmCloud runs in Part 4,
now as a **Pod on a real Kubernetes cluster** (minikube, docker driver +
containerd runtime). There is no language runtime, no OS userland, and no
sidecar in the image — just the ~290 KiB component in a `scratch` OCI image,
scheduled onto the runwasi **`containerd-shim-wasmtime`** shim by a
`RuntimeClass`.

```
part2 rust cargo provider ─┐
                            ├─ wac plug ─> app.wasm ─> scratch OCI image
part3 http-rust front door ─┘                          │
                                                        ├─ wasmtime serve        (Part 3)
                                                        ├─ wasmCloud httpserver   (Part 4)
                                                        └─ containerd wasmtime shim + RuntimeClass  (Part 5, here)
```

Everything reuses the Part 2/3 crates by *building* them — nothing is forked or
edited, and `contracts/wit` stays pristine.

## The deploy mechanism: generic runwasi shim + RuntimeClass

The vendor-neutral path. The runwasi `containerd-shim-wasmtime` is a containerd
shim that detects a component targeting the `wasi:http/proxy` world and serves
it behind a built-in hyper server on `0.0.0.0:8080` (the same behaviour as
`wasmtime serve`). Our `app.wasm` exports exactly `wasi:http/incoming-handler`,
so it runs unmodified.

- `install-shim.sh` downloads the pinned shim (checksum-verified), installs the
  `containerd-shim-wasmtime-v1` binary into the node, registers the runtime
  `io.containerd.wasmtime.v1` (handler `wasmtime`) in the node's
  `/etc/containerd/config.toml`, restarts containerd, and applies the
  `RuntimeClass`.
- `base/deployment.yaml` sets `runtimeClassName: wasmtime` and
  `command: ["/app.wasm"]` (the module path inside the scratch rootfs).

The **go/no-go test passed on the first run** — the raw shim served the
component with no feature-gap wall (runwasi #1004 did not bite), so this is the
mechanism used; the wasmCloud-operator fallback was not needed.

## Request path (no port-forward, ever)

```
curl http://cargo.<minikube-ip>.nip.io/cargo/CARGO-USNYC-DEHAM
   -> ingress-nginx (addon)
   -> Service cargo-http:8080
   -> Pod (runtimeClassName: wasmtime)
   -> containerd-shim-wasmtime (hyper server, 0.0.0.0:8080)
   -> app.wasm (wasi:http/incoming-handler)
```

`nip.io` resolves `<anything>.<ip>.nip.io` to `<ip>`, so the URL's own authority
IS the real DNS-resolvable Ingress host — no `/etc/hosts` edit, no
`minikube tunnel`, no NodePort. The only thing crossing the cluster boundary is
the curl, through the real ingress edge.

## Layout

```
../build.sh              wac plug recompose -> app.wasm, then docker build the
                         scratch OCI image (--provenance=false; single manifest)
../Dockerfile            FROM scratch; COPY app.wasm /app.wasm; ENTRYPOINT ["/app.wasm"]
k8s/lib.sh               shared helpers + the pins (shim version+SHA, k8s version)
k8s/install-shim.sh      download+verify shim -> install on node -> register
                         runtime -> restart containerd -> apply RuntimeClass
k8s/base/                namespace, RuntimeClass, Deployment+Service, Ingress
k8s/overlays/minikube/   retag image to :minikube, imagePullPolicy: Never
k8s/verify-minikube.sh   full live gate (start -> build -> shim -> deploy ->
                         curl asserts -> teardown)
k8s/capture-evidence.sh  full headless run that writes committed evidence/<date>/
k8s/teardown.sh          delete the profile (or --app-only)
k8s/evidence/<date>/     captured output from a real run, for the chapters to cite
```

## Running it

```bash
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"
# Ensure CRC is stopped first (one cluster at a time): crc status; crc stop
./capture-evidence.sh     # brings everything up and captures the proof
./teardown.sh             # delete the profile, leave the box clean
```

`verify-minikube.sh` is the leaner gate (same proof, tears down at the end;
`--keep` to leave it running).

## Pins (live-verified)

| Component | Version | Notes |
| --- | --- | --- |
| runwasi `containerd-shim-wasmtime` | **v0.6.1** | x86_64-linux-musl tarball SHA256 `a9b1215ee670f11414c8fd8e970b52679085929c8ec73a0fe6ed9cf215cf9ba1` (from the release `SHA256SUMS`) |
| minikube | **v1.39.0** | docker driver + containerd runtime |
| Kubernetes | **v1.37.1** | matches the kubectl client; `--kubernetes-version` pin |
| containerd (in node) | **v2.3.4** | minikube base image; config `version = 2` |
| ingress-nginx (addon) | controller **v1.15.1** | minikube `ingress` addon |

## Gotchas worth a chapter callout

- **The shim binary is a containerd shim, not a CLI** — invoking it with
  `--version` (or any flag it doesn't define) panics with
  `flag provided but not defined`. Confirm it is in place with `ls`, and let the
  running Pod be the proof. install-shim.sh does exactly this.
- **`minikube ssh` allocates a PTY, so a heredoc piped to `sudo bash -s` never
  gets EOF and the session hangs** after the work is done. Copy the node script
  in with `minikube cp` and run `sudo bash <file>` instead — install-shim.sh
  does this for the containerd config edit.
- **Disable BuildKit provenance** (`docker build --provenance=false`). The
  default adds an attestation manifest + manifest list; a one-layer `scratch`
  image is all the shim reads, and the single plain manifest keeps
  `minikube image load` / `ctr run` platform resolution unambiguous.
- **Readiness = a real 200.** A rollout reporting `Ready` and an Ingress
  reporting an address do not by themselves mean the component is answering, and
  ingress-nginx's default-backend 404 answers (exit 0) for an unmatched host
  while the controller is still reloading. The scripts gate on the
  `part5-cargo-affinity` cookie (stamped only by OUR Ingress rule) and then on
  an actual HTTP 200.
- **`app.wasm` and the OCI image are gitignored** — `build.sh` regenerates them
  deterministically. The `evidence/` text files ARE committed.
