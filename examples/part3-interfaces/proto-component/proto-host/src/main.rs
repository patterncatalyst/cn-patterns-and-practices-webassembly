// Native host for the protobuf-in-Wasm round trip (ch12).
//
// Loads the COMPOSED proto component (proto-rust plugged to the part2 Rust
// provider, so its cargo imports are satisfied and only `codec` is exported),
// prost-ENCODES a GetCargoRequest, calls `codec.get-cargo` across the component
// boundary, prost-DECODES the returned GetCargoResponse, and asserts the fields.
// The host never touches the cargo domain directly — the component did the
// protobuf (de)serialization and the domain dispatch itself.
//
// Usage: cargo-proto-host <composed-proto.wasm>

use anyhow::{bail, Context, Result};
use prost::Message;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "wit",
    world: "cargo-proto-codec",
});

mod pb {
    include!(concat!(env!("OUT_DIR"), "/patterncatalyst.cargo.v1.rs"));
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

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        bail!("usage: cargo-proto-host <composed-proto.wasm>");
    }
    let wasm_path = &args[1];

    let engine = Engine::default();
    let component = Component::from_file(&engine, wasm_path)
        .map_err(|e| anyhow::anyhow!("loading component {wasm_path}: {e}"))?;

    let mut linker: Linker<HostState> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)
        .map_err(|e| anyhow::anyhow!("add wasi to linker: {e}"))?;

    let mut store = Store::new(
        &engine,
        HostState {
            table: ResourceTable::new(),
            wasi: WasiCtxBuilder::new().inherit_stderr().build(),
        },
    );

    let proto = CargoProtoCodec::instantiate(&mut store, &component, &linker)
        .map_err(|e| anyhow::anyhow!("instantiate cargo-proto-codec: {e}"))?;
    let codec = proto.patterncatalyst_cargo_proto_codec();

    // --- prost ENCODE the request on the outside ---
    let req = pb::GetCargoRequest {
        tracking_id: "CARGO-USNYC-DEHAM".to_string(),
    };
    let req_bytes = req.encode_to_vec();
    println!(
        "host: encoded GetCargoRequest ({} bytes) tracking_id={}",
        req_bytes.len(),
        req.tracking_id
    );

    // --- call the component's codec.get-cargo over the component boundary ---
    let resp_bytes = codec
        .call_get_cargo(&mut store, &req_bytes)
        .map_err(|e| anyhow::anyhow!("call codec.get-cargo: {e}"))?
        .map_err(|e| anyhow::anyhow!("codec.get-cargo returned err: {e}"))?;
    println!("host: received {} bytes of protobuf response", resp_bytes.len());

    // --- prost DECODE the response and assert fields ---
    let resp = pb::GetCargoResponse::decode(resp_bytes.as_slice())
        .context("decoding GetCargoResponse")?;

    if !resp.error.is_empty() {
        bail!("response carried domain error: {}", resp.error);
    }
    let cargo = resp.cargo.context("response has no cargo")?;
    let price = resp.price.context("response has no price")?;

    assert_field("cargo.tracking_id", "CARGO-USNYC-DEHAM", &cargo.tracking_id)?;
    assert_field(
        "cargo.origin.unlocode",
        "USNYC",
        &cargo.origin.as_ref().map(|l| l.unlocode.clone()).unwrap_or_default(),
    )?;
    assert_field(
        "cargo.destination.unlocode",
        "DEHAM",
        &cargo.destination.as_ref().map(|l| l.unlocode.clone()).unwrap_or_default(),
    )?;
    if (cargo.weight_kg - 1200.5).abs() > f64::EPSILON {
        bail!("ASSERT FAIL cargo.weight_kg: expected 1200.5, got {}", cargo.weight_kg);
    }
    assert_field("price.amount", "1500.00", &price.amount)?;
    assert_field("price.currency", "USD", &price.currency)?;

    println!(
        "host: ASSERT OK — prost round trip through Wasm: tracking_id={} origin={} dest={} weight_kg={} price={} {}",
        cargo.tracking_id,
        cargo.origin.unwrap().unlocode,
        cargo.destination.unwrap().unlocode,
        cargo.weight_kg,
        price.amount,
        price.currency,
    );
    Ok(())
}

fn assert_field(ctx: &str, expected: &str, actual: &str) -> Result<()> {
    if expected != actual {
        bail!("ASSERT FAIL {ctx}: expected {expected:?}, got {actual:?}");
    }
    Ok(())
}
