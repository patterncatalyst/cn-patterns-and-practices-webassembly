// Native Kafka->Wasm consumer host (ch23).
//
// A plain Rust binary joins a REAL Kafka consumer group with rdkafka (manual
// offset commit, no tokio) and, per delivered message, drives an embedded
// wasmtime 50 runtime against `kafka-app.wasm` — the composite `build.sh`
// produces by `wac plug`-ing the Part 2 cargo provider into the ch23
// kafka-handler. The composite's only real import is wasi; this host never
// has to satisfy a `patterncatalyst:cargo` import at runtime, unlike the
// wasmCloud `messaging-kafka` path (../kafka-handler), which gets the same
// import satisfied by a wadm `link` instead of a build-time composition.
//
// Deployed as a plain Kubernetes Deployment (unlike kafka-handler, which has
// no Deployment to scale), this binary is what KEDA's `kafka` ScaledObject
// (../k8s/keda/base/kafka-scaledobject.yaml) can legitimately drive 0->N->0 on
// consumer-group lag.
//
// Engine/Component/Linker are loaded once and shared; each message gets a
// FRESH Store (and therefore a fresh handler instance) — the same shape as
// ../../part3-interfaces/grpc-bridge, which gets a fresh provider instance per
// RPC for the identical reason: no domain state leaks across invocations.
//
// Env:
//   KAFKA_BOOTSTRAP   default cargo-kafka-kafka-bootstrap.kafka.svc:9092
//   KAFKA_TOPIC       default cargo-handling-events
//   KAFKA_GROUP       default cargo-handling
//   KAFKA_APP_WASM    default /opt/cargo-kafka/kafka-app.wasm

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use rdkafka::config::ClientConfig;
use rdkafka::consumer::{BaseConsumer, CommitMode, Consumer};
use rdkafka::message::Message;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

// wasmtime 50 returns its own `wasmtime::Error` (not `anyhow::Error`), so
// anyhow's `.context()` does not apply to its results directly. This
// extension bridges a `wasmtime::Result<T>` into an `anyhow::Result<T>` with a
// context message — the same idiom used in the ch14 wasmtime-host and the
// grpc-bridge.
trait WasmCtx<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T>;
}
impl<T> WasmCtx<T> for wasmtime::Result<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T> {
        self.map_err(|e| anyhow::anyhow!("{ctx}: {e}"))
    }
}

wasmtime::component::bindgen!({
    path: "wit",
    world: "kafka-host",
});

use exports::wasmcloud::messaging::types::BrokerMessage;

const DEFAULT_BOOTSTRAP: &str = "cargo-kafka-kafka-bootstrap.kafka.svc:9092";
const DEFAULT_TOPIC: &str = "cargo-handling-events";
const DEFAULT_GROUP: &str = "cargo-handling";
const DEFAULT_WASM_PATH: &str = "/opt/cargo-kafka/kafka-app.wasm";

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn kafka_app_wasm_path() -> String {
    env_or("KAFKA_APP_WASM", DEFAULT_WASM_PATH)
}

struct HostState {
    table: ResourceTable,
    wasi: WasiCtx,
}

impl WasiView for HostState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

// Engine + preloaded composite, shared across every message. Each message
// gets a FRESH Store (and therefore a fresh instance of the plugged-in cargo
// provider's domain state) — see the file header.
#[derive(Clone)]
struct Host {
    engine: Arc<Engine>,
    component: Arc<Component>,
    linker: Arc<Linker<HostState>>,
}

impl Host {
    fn new(wasm_path: &str) -> Result<Self> {
        let engine = Engine::default();
        let component = Component::from_file(&engine, wasm_path)
            .map_err(|e| anyhow::anyhow!("load kafka-app component at {wasm_path}: {e}"))?;
        let mut linker: Linker<HostState> = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)
            .map_err(|e| anyhow::anyhow!("add wasi to linker: {e}"))?;
        Ok(Host {
            engine: Arc::new(engine),
            component: Arc::new(component),
            linker: Arc::new(linker),
        })
    }

    fn new_store(&self) -> Store<HostState> {
        Store::new(
            &self.engine,
            HostState {
                table: ResourceTable::new(),
                // Inherit stdio/stderr so the handler's own eprintln lines land
                // in `kubectl logs` for this pod, not just the host's.
                wasi: WasiCtxBuilder::new()
                    .inherit_stdio()
                    .build(),
            },
        )
    }

    fn instantiate(&self, store: &mut Store<HostState>) -> Result<KafkaHost> {
        KafkaHost::instantiate(store, &self.component, &self.linker)
            .wc("instantiate kafka-host world")
    }

    /// Runs one delivered message through a fresh instance of `kafka-app.wasm`.
    fn handle(&self, subject: String, body: Vec<u8>) -> Result<Result<(), String>> {
        let mut store = self.new_store();
        let world = self.instantiate(&mut store)?;
        let handler = world.wasmcloud_messaging_handler();
        let msg = BrokerMessage {
            subject,
            body,
            reply_to: None,
        };
        handler
            .call_handle_message(&mut store, &msg)
            .wc("call handle-message")
    }
}

fn build_consumer(bootstrap: &str, group: &str, topic: &str) -> Result<BaseConsumer> {
    let consumer: BaseConsumer = ClientConfig::new()
        .set("bootstrap.servers", bootstrap)
        .set("group.id", group)
        .set("enable.auto.commit", "false")
        .set("auto.offset.reset", "earliest")
        .set("session.timeout.ms", "10000")
        .create()
        .map_err(|e| anyhow::anyhow!("create Kafka consumer (bootstrap={bootstrap}): {e}"))?;
    consumer
        .subscribe(&[topic])
        .map_err(|e| anyhow::anyhow!("subscribe to topic '{topic}': {e}"))?;
    Ok(consumer)
}

/// Installs a shared shutdown flag that SIGINT and SIGTERM both set, so the
/// poll loop exits and the pod terminates promptly when KEDA scales the
/// Deployment down.
fn install_shutdown_flag() -> Result<Arc<AtomicBool>> {
    let shutdown = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGINT, Arc::clone(&shutdown))?;
    signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&shutdown))?;
    Ok(shutdown)
}

fn main() -> Result<()> {
    let bootstrap = env_or("KAFKA_BOOTSTRAP", DEFAULT_BOOTSTRAP);
    let topic = env_or("KAFKA_TOPIC", DEFAULT_TOPIC);
    let group = env_or("KAFKA_GROUP", DEFAULT_GROUP);
    let wasm_path = kafka_app_wasm_path();

    println!(
        "cargo-kafka-host: starting (bootstrap={bootstrap} topic={topic} group={group} \
         wasm={wasm_path})"
    );

    let host = Host::new(&wasm_path)?;
    let consumer = build_consumer(&bootstrap, &group, &topic)?;
    let shutdown = install_shutdown_flag()?;

    while !shutdown.load(Ordering::Relaxed) {
        let message = match consumer.poll(Duration::from_millis(500)) {
            None => continue,
            Some(Err(e)) => {
                eprintln!("cargo-kafka-host: poll error: {e}");
                continue;
            }
            Some(Ok(m)) => m,
        };

        let partition = message.partition();
        let offset = message.offset();
        let subject = message.topic().to_string();
        let body = message.payload().unwrap_or_default().to_vec();

        let outcome = host.handle(subject, body);

        // At-least-once, drain-on-poison semantics: a handler error means this
        // message is malformed or unprocessable, not that the broker or the
        // host is unhealthy. Committing past it anyway keeps the consumer
        // group draining instead of wedging on a single bad message forever;
        // a dead-letter topic would be the production-grade follow-up, not
        // retry-without-bound. A host-level failure (the `Err` wasmtime arm)
        // is logged the same way and still committed, for the same reason.
        match &outcome {
            Ok(Ok(())) => {
                println!(
                    "cargo-kafka-host: partition={partition} offset={offset} outcome=ok"
                );
            }
            Ok(Err(handler_err)) => {
                eprintln!(
                    "cargo-kafka-host: partition={partition} offset={offset} \
                     outcome=handler-error error={handler_err}"
                );
            }
            Err(host_err) => {
                eprintln!(
                    "cargo-kafka-host: partition={partition} offset={offset} \
                     outcome=host-error error={host_err}"
                );
            }
        }

        if let Err(e) = consumer.commit_message(&message, CommitMode::Sync) {
            eprintln!(
                "cargo-kafka-host: partition={partition} offset={offset} commit failed: {e}"
            );
        }
    }

    println!("cargo-kafka-host: shutdown signal received, exiting");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exercises the wasmtime plumbing directly, bypassing Kafka: loads the
    // composite the same way main() does and drives one call through
    // `handle-message`, the same shape as the grpc-bridge's in-process client
    // round trip. Expects `kafka-app.wasm` already built next to this crate
    // (build.sh's output) — run `./build.sh` first if this fails to load.
    #[test]
    fn handle_message_round_trip() {
        let wasm_path = concat!(env!("CARGO_MANIFEST_DIR"), "/kafka-app.wasm");
        let host = Host::new(wasm_path).expect("build host (is kafka-app.wasm built?)");

        let body = b"CARGO-USNYC-DEHAM|loaded|DEHAM|VOY-001|2026-11-01T00:00:00Z".to_vec();
        let outcome = host
            .handle("cargo-handling-events".to_string(), body)
            .expect("wasmtime call");
        assert_eq!(outcome, Ok(()), "handler rejected a well-formed message");

        let bad_body = b"not-enough-fields".to_vec();
        let bad_outcome = host
            .handle("cargo-handling-events".to_string(), bad_body)
            .expect("wasmtime call");
        assert!(bad_outcome.is_err(), "handler accepted a malformed message");
    }
}
