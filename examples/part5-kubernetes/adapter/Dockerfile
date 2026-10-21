# examples/part5-kubernetes/adapter/Dockerfile
#
# A thin OCI image carrying ONLY the ADAPTED Wasm composition (app-adapted.wasm
# = provider -> adapter -> http front door, wac-plug-composed). The runwasi
# `containerd-shim-wasmtime` shim mounts this image's rootfs, reads the OCI
# command (the Deployment sets it to `/app.wasm`), and loads that file as a Wasm
# component — no Linux userland, so the base is `scratch`.
#
# build.sh writes app-adapted.wasm next to this file first (two wac plug steps),
# then `docker build`s this. app-adapted.wasm is gitignored; the image is never
# committed and never pushed (minikube image load copies it into the node store).
FROM scratch
COPY app-adapted.wasm /app.wasm
ENTRYPOINT ["/app.wasm"]
