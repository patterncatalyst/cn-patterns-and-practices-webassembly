# examples/part6-deviations/spin/Dockerfile
#
# Packages the pinned `spin` CLI binary as the runtime for `cargo-spin.wasm` on
# OpenShift Local (CRC) — a plain Deployment running `spin up`, the second of
# this chapter's two deploy targets (the first is the SpinKube `spin-shim`
# RuntimeClass on minikube; see README.md).
#
# `cargo-spin.wasm` is built by `./build.sh` ON THE HOST (`wac plug` recompose
# of the handler + the unedited Part 2 provider) and COPYed in below — no Rust
# or wasm toolchain (cargo, cargo-component, wac, wasm-tools) runs inside this
# image. The Spin binary itself is downloaded and SHA-256-verified at image
# build time against the same v4.2.4 release checksum build.sh and README.md
# both cite, so the image and the host toolchain never drift apart.
#
# Base: `debian:trixie-slim` — the spin v4.2.4 linux-amd64 release is
# dynamically linked against glibc, libgcc and libstdc++ (confirmed with
# `ldd`), none of which `scratch` provides; trixie-slim is the smallest base
# in this book's rotation that already carries glibc, and `libstdc++6` is the
# one package it does not include by default.
FROM debian:trixie-slim

ARG SPIN_VERSION=v4.2.4
ARG SPIN_SHA256=519ba201e0105dc83a17a4ea9ca6605c80286cbfaf40c1d7505d068bfea83cf1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/spin.tar.gz \
        "https://github.com/fermyon/spin/releases/download/${SPIN_VERSION}/spin-${SPIN_VERSION}-linux-amd64.tar.gz" \
    && echo "${SPIN_SHA256}  /tmp/spin.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/spin.tar.gz -C /tmp spin \
    && install -m 0755 /tmp/spin /usr/local/bin/spin \
    && rm -f /tmp/spin.tar.gz /tmp/spin \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Fixed numeric uid/gid: a Kubernetes `runAsNonRoot: true` securityContext can
# only verify a non-root user when the image's USER is numeric (same
# convention as ../../part5-kubernetes/kafka-host/Containerfile). `spin up`
# writes its wasmtime compilation cache under `$HOME/.cache`, so HOME points
# at `/app` and that tree must be writable by whatever uid the pod runs as.
# On minikube the pod runs as this image's uid 10001; on OpenShift the
# restricted-v2 SCC assigns an arbitrary uid that still belongs to group 0, so
# `/app` is owned by group 0 and made group-writable (`chmod g=u`) — the Red
# Hat arbitrary-uid convention — and `.cache` is pre-created so the first
# `spin up` has it ready.
RUN groupadd --system --gid 10001 cargo-spin \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin cargo-spin \
    && mkdir -p /app/.cache \
    && chown -R 10001:0 /app \
    && chmod -R g=u /app

WORKDIR /app
COPY spin.toml /app/spin.toml
COPY cargo-spin.wasm /app/cargo-spin.wasm

ENV HOME=/app
USER 10001
EXPOSE 8080
ENTRYPOINT ["spin", "up", "--listen", "0.0.0.0:8080", "-f", "/app/spin.toml"]
