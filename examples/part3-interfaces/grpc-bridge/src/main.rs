// gRPC-in-FRONT-of-Wasm bridge (ch12).
//
// A native host terminates gRPC with tonic and, per RPC, instantiates the
// UNCHANGED part2 Rust provider with wasmtime and dispatches the call over WIT.
// There is no gRPC server inside any component — the bridge is the artifact, and
// the chapter states this plainly. prost/tonic are pinned exact (Cargo.lock
// committed).
//
// Run:   cargo-grpc-bridge [ADDR]         (default 127.0.0.1:50051)
// Test:  cargo test --release             (in-process client round trip)
//
// The provider wasm path defaults to the part2 build output and can be
// overridden with CARGO_PROVIDER_WASM.

use std::sync::Arc;

use anyhow::Result;
use tonic::{transport::Server, Request, Response, Status};
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../../../contracts/wit",
    world: "cargo",
});

use exports::patterncatalyst::cargo::types::{Location, RouteSpec, RoutingStatus};

pub mod pb {
    tonic::include_proto!("patterncatalyst.cargo.v1");
}

use pb::cargo_service_server::{CargoService, CargoServiceServer};
use pb::{
    BookCargoRequest, BookCargoResponse, Cargo as PbCargo, GetCargoRequest, GetCargoResponse,
    Location as PbLocation, Money as PbMoney,
};

const DEFAULT_WEIGHT_KG: f64 = 1200.5;
const ARRIVAL_DEADLINE: &str = "2026-12-01T00:00:00Z";

fn provider_wasm_path() -> String {
    std::env::var("CARGO_PROVIDER_WASM").unwrap_or_else(|_| {
        concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../part2-building-components/rust/target/wasm32-wasip1/release/cargo_rust.wasm"
        )
        .to_string()
    })
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

// Engine + preloaded component, shared across RPCs. Each RPC gets a FRESH Store
// (and therefore a fresh provider instance), which is why GetCargo books before
// it reads: the part2 provider keeps domain state in instance memory.
#[derive(Clone)]
struct Bridge {
    engine: Arc<Engine>,
    component: Arc<Component>,
    linker: Arc<Linker<HostState>>,
}

impl Bridge {
    fn new() -> Result<Self> {
        let engine = Engine::default();
        let component = Component::from_file(&engine, provider_wasm_path())
            .map_err(|e| anyhow::anyhow!("load provider component: {e}"))?;
        let mut linker: Linker<HostState> = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)
            .map_err(|e| anyhow::anyhow!("add wasi to linker: {e}"))?;
        Ok(Bridge {
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
                wasi: WasiCtxBuilder::new().inherit_stderr().build(),
            },
        )
    }

    fn instantiate(&self, store: &mut Store<HostState>) -> Result<Cargo> {
        Cargo::instantiate(store, &self.component, &self.linker)
            .map_err(|e| anyhow::anyhow!("instantiate cargo world: {e}"))
    }

    // --- synchronous WIT dispatch, run on a blocking thread ---

    fn do_get_cargo(&self, tracking_id: String) -> Result<GetCargoResponse, String> {
        let parts: Vec<&str> = tracking_id.splitn(3, '-').collect();
        if !(parts.len() == 3 && parts[0] == "CARGO") {
            return Ok(GetCargoResponse {
                cargo: None,
                price: None,
                error: format!("not-found: {tracking_id} is not a CARGO-O-D id"),
            });
        }
        let mut store = self.new_store();
        let cargo_world = self.instantiate(&mut store).map_err(|e| e.to_string())?;
        let booking_api = cargo_world.patterncatalyst_cargo_booking();

        let spec = RouteSpec {
            origin: location_for(parts[1]),
            destination: location_for(parts[2]),
            arrival_deadline: ARRIVAL_DEADLINE.to_string(),
        };
        let booking = match booking_api
            .call_book_cargo(&mut store, &spec, DEFAULT_WEIGHT_KG)
            .map_err(|e| e.to_string())?
        {
            Ok(b) => b,
            Err(e) => return Ok(domain_err_get(format!("{e:?}"))),
        };
        let cargo = match booking_api
            .call_get_cargo(&mut store, &booking.cargo_id)
            .map_err(|e| e.to_string())?
        {
            Ok(c) => c,
            Err(e) => return Ok(domain_err_get(format!("{e:?}"))),
        };
        Ok(GetCargoResponse {
            cargo: Some(PbCargo {
                tracking_id: cargo.tracking_id,
                origin: Some(pb_loc(&cargo.origin)),
                destination: Some(pb_loc(&cargo.destination)),
                weight_kg: cargo.weight_kg,
            }),
            price: Some(PbMoney {
                amount: booking.price.amount,
                currency: booking.price.currency,
            }),
            error: String::new(),
        })
    }

    fn do_book_cargo(&self, req: BookCargoRequest) -> Result<BookCargoResponse, String> {
        let mut store = self.new_store();
        let cargo_world = self.instantiate(&mut store).map_err(|e| e.to_string())?;
        let booking_api = cargo_world.patterncatalyst_cargo_booking();

        let spec = RouteSpec {
            origin: pb_to_loc(req.origin.as_ref()),
            destination: pb_to_loc(req.destination.as_ref()),
            arrival_deadline: if req.arrival_deadline.is_empty() {
                ARRIVAL_DEADLINE.to_string()
            } else {
                req.arrival_deadline
            },
        };
        let weight = if req.weight_kg == 0.0 {
            DEFAULT_WEIGHT_KG
        } else {
            req.weight_kg
        };
        match booking_api
            .call_book_cargo(&mut store, &spec, weight)
            .map_err(|e| e.to_string())?
        {
            Ok(b) => Ok(BookCargoResponse {
                booking_id: b.booking_id,
                cargo_id: b.cargo_id,
                price: Some(PbMoney {
                    amount: b.price.amount,
                    currency: b.price.currency,
                }),
                status: routing_status_str(b.status).to_string(),
                error: String::new(),
            }),
            Err(e) => Ok(BookCargoResponse {
                booking_id: String::new(),
                cargo_id: String::new(),
                price: None,
                status: String::new(),
                error: format!("{e:?}"),
            }),
        }
    }
}

fn domain_err_get(msg: String) -> GetCargoResponse {
    GetCargoResponse {
        cargo: None,
        price: None,
        error: msg,
    }
}

fn location_for(unlocode: &str) -> Location {
    let (name, country) = match unlocode {
        "USNYC" => ("New York", "US"),
        "DEHAM" => ("Hamburg", "DE"),
        other => (other, ""),
    };
    Location {
        unlocode: unlocode.to_string(),
        name: name.to_string(),
        country: country.to_string(),
    }
}

fn pb_to_loc(l: Option<&PbLocation>) -> Location {
    match l {
        Some(l) => Location {
            unlocode: l.unlocode.clone(),
            name: l.name.clone(),
            country: l.country.clone(),
        },
        None => Location {
            unlocode: String::new(),
            name: String::new(),
            country: String::new(),
        },
    }
}

fn pb_loc(l: &Location) -> PbLocation {
    PbLocation {
        unlocode: l.unlocode.clone(),
        name: l.name.clone(),
        country: l.country.clone(),
    }
}

fn routing_status_str(s: RoutingStatus) -> &'static str {
    match s {
        RoutingStatus::Unspecified => "unspecified",
        RoutingStatus::NotRouted => "not-routed",
        RoutingStatus::Routed => "routed",
        RoutingStatus::Misrouted => "misrouted",
    }
}

#[tonic::async_trait]
impl CargoService for Bridge {
    async fn get_cargo(
        &self,
        request: Request<GetCargoRequest>,
    ) -> Result<Response<GetCargoResponse>, Status> {
        let this = self.clone();
        let tracking_id = request.into_inner().tracking_id;
        let resp = tokio::task::spawn_blocking(move || this.do_get_cargo(tracking_id))
            .await
            .map_err(|e| Status::internal(format!("join error: {e}")))?
            .map_err(Status::internal)?;
        Ok(Response::new(resp))
    }

    async fn book_cargo(
        &self,
        request: Request<BookCargoRequest>,
    ) -> Result<Response<BookCargoResponse>, Status> {
        let this = self.clone();
        let req = request.into_inner();
        let resp = tokio::task::spawn_blocking(move || this.do_book_cargo(req))
            .await
            .map_err(|e| Status::internal(format!("join error: {e}")))?
            .map_err(Status::internal)?;
        Ok(Response::new(resp))
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let addr = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "127.0.0.1:50051".to_string())
        .parse()?;
    let bridge = Bridge::new()?;
    println!("cargo-grpc-bridge: serving CargoService on {addr} (gRPC in front of Wasm)");
    Server::builder()
        .add_service(CargoServiceServer::new(bridge))
        .serve(addr)
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use pb::cargo_service_client::CargoServiceClient;
    use tokio::net::TcpListener;

    // End-to-end: start the bridge on an ephemeral port, then drive it with a
    // real tonic client and assert the payload the Wasm provider produced.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn tonic_client_roundtrip() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let incoming = tokio_stream::wrappers::TcpListenerStream::new(listener);

        let bridge = Bridge::new().expect("build bridge (is the part2 provider built?)");
        tokio::spawn(async move {
            Server::builder()
                .add_service(CargoServiceServer::new(bridge))
                .serve_with_incoming(incoming)
                .await
                .unwrap();
        });

        // Let the server bind.
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;

        let mut client = CargoServiceClient::connect(format!("http://{addr}"))
            .await
            .expect("client connect");

        // GetCargo
        let resp = client
            .get_cargo(GetCargoRequest {
                tracking_id: "CARGO-USNYC-DEHAM".to_string(),
            })
            .await
            .expect("GetCargo rpc")
            .into_inner();
        assert!(resp.error.is_empty(), "unexpected error: {}", resp.error);
        let cargo = resp.cargo.expect("cargo");
        let price = resp.price.expect("price");
        assert_eq!(cargo.tracking_id, "CARGO-USNYC-DEHAM");
        assert_eq!(cargo.origin.unwrap().unlocode, "USNYC");
        assert_eq!(cargo.destination.unwrap().unlocode, "DEHAM");
        assert_eq!(cargo.weight_kg, 1200.5);
        assert_eq!(price.amount, "1500.00");
        assert_eq!(price.currency, "USD");

        // BookCargo
        let booked = client
            .book_cargo(BookCargoRequest {
                origin: Some(PbLocation {
                    unlocode: "USNYC".to_string(),
                    name: "New York".to_string(),
                    country: "US".to_string(),
                }),
                destination: Some(PbLocation {
                    unlocode: "DEHAM".to_string(),
                    name: "Hamburg".to_string(),
                    country: "DE".to_string(),
                }),
                arrival_deadline: ARRIVAL_DEADLINE.to_string(),
                weight_kg: 1200.5,
            })
            .await
            .expect("BookCargo rpc")
            .into_inner();
        assert!(booked.error.is_empty(), "unexpected error: {}", booked.error);
        assert_eq!(booked.booking_id, "BOOKING-USNYC-DEHAM");
        assert_eq!(booked.cargo_id, "CARGO-USNYC-DEHAM");
        assert_eq!(booked.status, "not-routed");
        assert_eq!(booked.price.unwrap().amount, "1500.00");

        println!("grpc-bridge: tonic client round trip OK (GetCargo + BookCargo through Wasm)");
    }
}
