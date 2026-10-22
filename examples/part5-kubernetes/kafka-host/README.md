# cargo-kafka-host — a native Kafka-to-Wasm consumer host

A plain Rust binary that joins a real Kafka consumer group and drives a Wasm
component per message, deployed as a plain Kubernetes Deployment. It is the
counterpart to `../kafka-handler`'s wasmCloud lattice path (`messaging-kafka`
capability provider + `wadm` link): same handler logic, different host.

```
Kafka (cargo-handling-events)
      │ rdkafka BaseConsumer, manual commit
      ▼
cargo-kafka-host (this crate)
      │ fresh wasmtime Store per message
      ▼
kafka-app.wasm  =  patterncatalyst:cargo provider  +  kafka-handler  (wac plug)
      exports wasmcloud:messaging/handler, imports only wasi
```

## Why a composite, not a link

`../kafka-handler` targets a world that imports `patterncatalyst:cargo/
{types,handling}` — in the wasmCloud lattice, `wadm` satisfies that import at
deploy time with a `link` trait to a separately deployed cargo provider
component. A `wasmtime::component::Component` loaded directly by a native host
has no lattice and no link trait: it is one self-contained artifact or it does
not run. `build.sh` satisfies the handler's import at build time instead, with
the same `wac plug` composition `../build.sh` and `../adapter/build.sh` use —
the Part 2 cargo provider's exports plug straight into the handler's imports,
producing `kafka-app.wasm`, which exports `wasmcloud:messaging/{types,
handler}@0.2.0` and imports nothing but `wasi:*`. The handler's business logic
is unchanged; only how its import gets satisfied differs.

## Why this host exists

`../kafka-handler` is a wasmCloud component with no Kubernetes Deployment
behind it — `wadm`'s spreadscaler owns its replica count, and
`../k8s/keda/base/kafka-scaledobject.yaml` can only watch consumer-group lag
for it, not act on it (there is no `Deployment` to patch). This host is the
other half of that comparison: a plain container workload with a
`Deployment`, so a `ScaledObject` pointed at it scales `0 -> N -> 0` on that
lag metric.

## Design

- `rdkafka::consumer::BaseConsumer` (sync, no tokio) joins `KAFKA_GROUP` and
  subscribes to `KAFKA_TOPIC` with `enable.auto.commit=false`.
- `Engine`, `Component`, and `Linker` for `kafka-app.wasm` are built once and
  shared (`Arc`); each delivered message gets a FRESH `Store`, so no domain
  state leaks between invocations — the same shape
  `../../part3-interfaces/grpc-bridge` uses per RPC.
- Each message becomes a `wasmcloud:messaging/types.broker-message` (subject =
  the Kafka topic, body = the raw payload, no reply-to) and is dispatched to
  `handler.handle-message`.
- A successful call commits the offset. A rejected message (malformed input,
  the handler's own `Err(string)`) is logged and committed anyway — this is
  at-least-once delivery with a drain-on-poison policy, not a crash loop on one
  bad record. A host-side failure (the wasmtime call itself erroring) is logged
  the same way. Every outcome logs one line with partition/offset so
  `kubectl logs` shows handler activity directly.
- `SIGINT`/`SIGTERM` set a shared flag the poll loop checks every 500 ms, so
  the pod exits promptly when KEDA scales the Deployment to zero.

## Build

```
./build.sh
```

Builds the Part 2 cargo provider and `../kafka-handler` (their own recipes,
unmodified), `wac plug`s them into `kafka-app.wasm`, validates it exports
`wasmcloud:messaging/{types,handler}@0.2.0` and imports only `wasi:*`, then
`cargo build --release`s the host binary. `kafka-app.wasm` is gitignored and
rebuilt from source every time; `Cargo.lock` is committed.

```
docker build -f Containerfile -t cargo-kafka-host:local .
```

builds the container image. The image build does not build `kafka-app.wasm`
itself — run `./build.sh` first so the file exists next to the Containerfile
for `COPY`.

## Env

| var | default |
| --- | --- |
| `KAFKA_BOOTSTRAP` | `cargo-kafka-kafka-bootstrap.kafka.svc:9092` |
| `KAFKA_TOPIC` | `cargo-handling-events` |
| `KAFKA_GROUP` | `cargo-handling` |
| `KAFKA_APP_WASM` | `/opt/cargo-kafka/kafka-app.wasm` |
