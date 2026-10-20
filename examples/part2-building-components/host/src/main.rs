// Native host for the two-language WebAssembly cargo example.
//
// It loads a component that EXPORTS `world cargo` (either ../rust's or ../go's
// build output — the SAME host binary runs against both), then calls the
// exported booking and handling interfaces ACROSS the component boundary with
// wasmtime's component model. It drives one deterministic scenario from a
// shared fixture, asserts every observable result against the fixture's
// expectations, and prints a normalized JSON summary on stdout so verify.sh can
// also diff the Rust component's output against the Go component's.
//
// Usage: cargo-host <component.wasm> <fixture.json> [label]

use anyhow::{bail, Context, Result};
use wasmtime::component::{Component, Linker, ResourceAny, ResourceTable};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../../../contracts/wit",
    world: "cargo",
});

use exports::patterncatalyst::cargo::types::{
    HandlingEventType, Location, RouteSpec, RoutingStatus, TransportStatus,
};

// wasmtime 50 returns its own `wasmtime::Error` (no longer `anyhow::Error`), so
// anyhow's `.context()` does not apply to its results. This extension bridges a
// `wasmtime::Result<T>` into an `anyhow::Result<T>` with a context message.
trait WasmCtx<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T>;
}
impl<T> WasmCtx<T> for wasmtime::Result<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T> {
        self.map_err(|e| anyhow::anyhow!("{ctx}: {e}"))
    }
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

// ---- fixture types (serde) -------------------------------------------------

#[derive(serde::Deserialize)]
struct Fixture {
    input: Input,
    expected: Expected,
}

#[derive(serde::Deserialize)]
struct Input {
    route_spec: RouteSpecJson,
    weight_kg: f64,
    handling_events: Vec<HandlingEventJson>,
}

#[derive(serde::Deserialize)]
struct RouteSpecJson {
    origin: LocationJson,
    destination: LocationJson,
    arrival_deadline: String,
}

#[derive(serde::Deserialize, Clone)]
struct LocationJson {
    unlocode: String,
    name: String,
    country: String,
}

#[derive(serde::Deserialize)]
struct HandlingEventJson {
    event_type: String,
    location: LocationJson,
    voyage_id: String,
    recorded_at: String,
}

#[derive(serde::Deserialize)]
struct Expected {
    booking: ExpectedBooking,
    cargo: ExpectedCargo,
    itinerary: ExpectedItinerary,
    assigned_status: String,
    events_count: usize,
    tracker: ExpectedTracker,
}

#[derive(serde::Deserialize)]
struct ExpectedBooking {
    booking_id: String,
    cargo_id: String,
    price_amount: String,
    price_currency: String,
    status: String,
}

#[derive(serde::Deserialize)]
struct ExpectedCargo {
    tracking_id: String,
    weight_kg: f64,
}

#[derive(serde::Deserialize)]
struct ExpectedItinerary {
    booking_id: String,
    leg_voyage_id: String,
    leg_status: String,
}

#[derive(serde::Deserialize)]
struct ExpectedTracker {
    tracking_id: String,
    current_status: String,
    history_count: usize,
}

// ---- enum <-> string helpers ----------------------------------------------

fn event_type_from_str(s: &str) -> Result<HandlingEventType> {
    Ok(match s {
        "unspecified" => HandlingEventType::Unspecified,
        "received" => HandlingEventType::Received,
        "loaded" => HandlingEventType::Loaded,
        "unloaded" => HandlingEventType::Unloaded,
        "customs" => HandlingEventType::Customs,
        "claimed" => HandlingEventType::Claimed,
        other => bail!("unknown handling-event-type {other:?}"),
    })
}

fn transport_status_str(s: TransportStatus) -> &'static str {
    match s {
        TransportStatus::Unspecified => "unspecified",
        TransportStatus::Planned => "planned",
        TransportStatus::InTransit => "in-transit",
        TransportStatus::Completed => "completed",
        TransportStatus::Delayed => "delayed",
    }
}

fn event_type_str(s: HandlingEventType) -> &'static str {
    match s {
        HandlingEventType::Unspecified => "unspecified",
        HandlingEventType::Received => "received",
        HandlingEventType::Loaded => "loaded",
        HandlingEventType::Unloaded => "unloaded",
        HandlingEventType::Customs => "customs",
        HandlingEventType::Claimed => "claimed",
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

fn loc(j: &LocationJson) -> Location {
    Location {
        unlocode: j.unlocode.clone(),
        name: j.name.clone(),
        country: j.country.clone(),
    }
}

macro_rules! assert_eq_ctx {
    ($expected:expr, $actual:expr, $ctx:expr) => {{
        let e = $expected;
        let a = $actual;
        if e != a {
            bail!("ASSERT FAIL [{}]: expected {:?}, got {:?}", $ctx, e, a);
        }
    }};
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        bail!("usage: cargo-host <component.wasm> <fixture.json> [label]");
    }
    let wasm_path = &args[1];
    let fixture_path = &args[2];
    let label = args.get(3).cloned().unwrap_or_else(|| "component".to_string());

    let fixture: Fixture = serde_json::from_str(
        &std::fs::read_to_string(fixture_path)
            .with_context(|| format!("reading fixture {fixture_path}"))?,
    )
    .context("parsing fixture json")?;

    let engine = Engine::default();
    let component = Component::from_file(&engine, wasm_path)
        .wc(format!("loading component {wasm_path}"))?;

    let mut linker: Linker<HostState> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).wc("add wasi to linker")?;

    let mut store = Store::new(
        &engine,
        HostState {
            table: ResourceTable::new(),
            wasi: WasiCtxBuilder::new().inherit_stderr().build(),
        },
    );

    let cargo = Cargo::instantiate(&mut store, &component, &linker)
        .wc("instantiating cargo world")?;

    let booking_api = cargo.patterncatalyst_cargo_booking();
    let handling_api = cargo.patterncatalyst_cargo_handling();

    // 1. book-cargo
    let spec = RouteSpec {
        origin: loc(&fixture.input.route_spec.origin),
        destination: loc(&fixture.input.route_spec.destination),
        arrival_deadline: fixture.input.route_spec.arrival_deadline.clone(),
    };
    let booking = booking_api
        .call_book_cargo(&mut store, &spec, fixture.input.weight_kg)
        .wc("call book-cargo")?
        .map_err(|e| anyhow::anyhow!("book-cargo returned error: {e:?}"))?;

    assert_eq_ctx!(&fixture.expected.booking.booking_id, &booking.booking_id, "booking.booking-id");
    assert_eq_ctx!(&fixture.expected.booking.cargo_id, &booking.cargo_id, "booking.cargo-id");
    assert_eq_ctx!(&fixture.expected.booking.price_amount, &booking.price.amount, "booking.price.amount");
    assert_eq_ctx!(&fixture.expected.booking.price_currency, &booking.price.currency, "booking.price.currency");
    assert_eq_ctx!(fixture.expected.booking.status.as_str(), routing_status_str(booking.status), "booking.status");

    // 2. get-cargo
    let got = booking_api
        .call_get_cargo(&mut store, &booking.cargo_id)
        .wc("call get-cargo")?
        .map_err(|e| anyhow::anyhow!("get-cargo returned error: {e:?}"))?;
    assert_eq_ctx!(&fixture.expected.cargo.tracking_id, &got.tracking_id, "cargo.tracking-id");
    assert_eq_ctx!(fixture.expected.cargo.weight_kg, got.weight_kg, "cargo.weight-kg");

    // 3. request-possible-routes
    let routes = booking_api
        .call_request_possible_routes(&mut store, &booking.booking_id)
        .wc("call request-possible-routes")?
        .map_err(|e| anyhow::anyhow!("request-possible-routes returned error: {e:?}"))?;
    if routes.len() != 1 {
        bail!("ASSERT FAIL [itineraries.len]: expected 1, got {}", routes.len());
    }
    let itinerary = routes.into_iter().next().unwrap();
    assert_eq_ctx!(&fixture.expected.itinerary.booking_id, &itinerary.booking_id, "itinerary.booking-id");
    if itinerary.legs.len() != 1 {
        bail!("ASSERT FAIL [legs.len]: expected 1, got {}", itinerary.legs.len());
    }
    let leg = &itinerary.legs[0];
    assert_eq_ctx!(&fixture.expected.itinerary.leg_voyage_id, &leg.voyage_id, "leg.voyage-id");
    assert_eq_ctx!(fixture.expected.itinerary.leg_status.as_str(), transport_status_str(leg.status), "leg.status");

    // 4. assign-route
    let assigned = booking_api
        .call_assign_route(&mut store, &booking.booking_id, &itinerary)
        .wc("call assign-route")?
        .map_err(|e| anyhow::anyhow!("assign-route returned error: {e:?}"))?;
    assert_eq_ctx!(fixture.expected.assigned_status.as_str(), routing_status_str(assigned.status), "assigned.status");

    // 5. register-handling-event (x N)
    for (i, ev) in fixture.input.handling_events.iter().enumerate() {
        let et = event_type_from_str(&ev.event_type)?;
        handling_api
            .call_register_handling_event(
                &mut store,
                &booking.cargo_id,
                et,
                &loc(&ev.location),
                &ev.voyage_id,
                &ev.recorded_at,
            )
            .wc(format!("call register-handling-event[{i}]"))?
            .map_err(|e| anyhow::anyhow!("register-handling-event[{i}] returned error: {e:?}"))?;
    }

    // 6. list-handling-events
    let events = handling_api
        .call_list_handling_events(&mut store, &booking.cargo_id)
        .wc("call list-handling-events")?
        .map_err(|e| anyhow::anyhow!("list-handling-events returned error: {e:?}"))?;
    assert_eq_ctx!(fixture.expected.events_count, events.len(), "events.count");

    // 7. cargo-tracker resource
    let tracker_api = handling_api.cargo_tracker();
    let tracker: ResourceAny = tracker_api
        .call_constructor(&mut store, &booking.cargo_id)
        .wc("call cargo-tracker constructor")?;
    let t_id = tracker_api
        .call_tracking_id(&mut store, tracker)
        .wc("call tracking-id")?;
    assert_eq_ctx!(&fixture.expected.tracker.tracking_id, &t_id, "tracker.tracking-id");
    let t_status = tracker_api
        .call_current_status(&mut store, tracker)
        .wc("call current-status")?;
    assert_eq_ctx!(fixture.expected.tracker.current_status.as_str(), transport_status_str(t_status), "tracker.current-status");
    let t_history = tracker_api
        .call_history(&mut store, tracker)
        .wc("call history")?;
    assert_eq_ctx!(fixture.expected.tracker.history_count, t_history.len(), "tracker.history.count");
    tracker
        .resource_drop(&mut store)
        .wc("drop cargo-tracker resource")?;

    // normalized observable summary for cross-language diff
    let history_json: Vec<serde_json::Value> = t_history
        .iter()
        .map(|e| {
            serde_json::json!({
                "cargo-id": e.cargo_id,
                "event-type": event_type_str(e.event_type),
                "location": e.location.unlocode,
                "voyage-id": e.voyage_id,
                "recorded-at": e.recorded_at,
            })
        })
        .collect();

    let summary = serde_json::json!({
        "booking": {
            "booking-id": booking.booking_id,
            "cargo-id": booking.cargo_id,
            "price": { "amount": booking.price.amount, "currency": booking.price.currency },
            "status": routing_status_str(booking.status),
        },
        "cargo": { "tracking-id": got.tracking_id, "weight-kg": got.weight_kg },
        "itinerary": {
            "booking-id": itinerary.booking_id,
            "leg-voyage-id": leg.voyage_id,
            "leg-status": transport_status_str(leg.status),
        },
        "assigned-status": routing_status_str(assigned.status),
        "events-count": events.len(),
        "tracker": {
            "tracking-id": t_id,
            "current-status": transport_status_str(t_status),
            "history-count": t_history.len(),
            "history": history_json,
        }
    });

    eprintln!("[{label}] all assertions passed");
    println!("{}", serde_json::to_string_pretty(&summary)?);
    Ok(())
}
