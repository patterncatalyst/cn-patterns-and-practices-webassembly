# examples/part5-kubernetes/Dockerfile
#
# A thin OCI image that carries ONLY the Wasm component. The runwasi
# `containerd-shim-wasmtime` shim mounts this image's rootfs, reads the OCI
# config's command (the Deployment sets it to the single arg `/app.wasm`), and
# loads that file as a Wasm component — it never needs a Linux userland, so the
# base is `scratch` and the whole image is just the ~290 KiB component plus the
# OCI metadata. No registry push: `minikube image load` copies it straight into
# the node's containerd image store (DRQ convention: docker driver + containerd,
# no registry).
#
# build.sh writes app.wasm next to this file first (wac plug recompose), then
# `docker build`s this. app.wasm is gitignored; the image is never committed.
FROM scratch
COPY app.wasm /app.wasm
# The shim uses the OCI command/args to locate the module in the rootfs. The
# Deployment overrides this with an explicit `command: ["/app.wasm"]`, but we
# set it here too so `ctr run <image> <id>` (the go/no-go smoke test) works with
# no extra args.
ENTRYPOINT ["/app.wasm"]
