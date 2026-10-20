// Rust CONSUMER for the `cargo` domain (contracts/wit, package
// patterncatalyst:cargo@0.1.0). This is a cargo-component *command* component:
// it IMPORTS the three cargo interfaces (see wit/world.wit) and, because it is
// a `[[bin]]` with `fn main`, cargo-component synthesizes the `wasi:cli/run`
// export that wraps `main`. Composed with ANY component that exports `cargo`
// (the Rust or the Go provider in ../rust and ../go) via `wac plug`, the result
// is directly `wasmtime run`-able — no native host required.
//
// It runs the SAME deterministic scenario as the providers and the native host
// (fixtures/scenario.json: USNYC -> DEHAM, 1200.5 kg, three handling events)
// and prints ONE normalized summary line to stdout. The Go consumer
// (../consumer-go) prints the byte-identical line, so verify.sh can diff the
// runtime stdout of all four consumer x provider compositions. The scenario
// constants below MUST stay in lockstep with fixtures/scenario.json.
#[allow(warnings)]
mod bindings;

use bindings::patterncatalyst::cargo::booking;
use bindings::patterncatalyst::cargo::handling::{self, CargoTracker};
use bindings::patterncatalyst::cargo::types::{
    CargoError, HandlingEvent, HandlingEventType, Location, RouteSpec, RoutingStatus,
    TransportStatus,
};

// --- scenario constants — keep in lockstep with fixtures/scenario.json --------
const ORIGIN_UNLOCODE: &str = "USNYC";
const ORIGIN_NAME: &str = "New York";
const ORIGIN_COUNTRY: &str = "US";
const DEST_UNLOCODE: &str = "DEHAM";
const DEST_NAME: &str = "Hamburg";
const DEST_COUNTRY: &str = "DE";
const ARRIVAL_DEADLINE: &str = "2026-12-01T00:00:00Z";
const WEIGHT_KG: f64 = 1200.5;

struct Event {
    event_type: HandlingEventType,
    unlocode: &'static str,
    name: &'static str,
    country: &'static str,
    voyage_id: &'static str,
    recorded_at: &'static str,
}

fn scenario_events() -> Vec<Event> {
    vec![
        Event {
            event_type: HandlingEventType::Received,
            unlocode: "USNYC",
            name: "New York",
            country: "US",
            voyage_id: "VOY-001",
            recorded_at: "2026-11-02T09:00:00Z",
        },
        Event {
            event_type: HandlingEventType::Loaded,
            unlocode: "USNYC",
            name: "New York",
            country: "US",
            voyage_id: "VOY-001",
            recorded_at: "2026-11-03T14:30:00Z",
        },
        Event {
            event_type: HandlingEventType::Unloaded,
            unlocode: "DEHAM",
            name: "Hamburg",
            country: "DE",
            voyage_id: "VOY-001",
            recorded_at: "2026-11-20T08:15:00Z",
        },
    ]
}

fn event_type_str(t: HandlingEventType) -> &'static str {
    match t {
        HandlingEventType::Unspecified => "unspecified",
        HandlingEventType::Received => "received",
        HandlingEventType::Loaded => "loaded",
        HandlingEventType::Unloaded => "unloaded",
        HandlingEventType::Customs => "customs",
        HandlingEventType::Claimed => "claimed",
    }
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

fn routing_status_str(s: RoutingStatus) -> &'static str {
    match s {
        RoutingStatus::Unspecified => "unspecified",
        RoutingStatus::NotRouted => "not-routed",
        RoutingStatus::Routed => "routed",
        RoutingStatus::Misrouted => "misrouted",
    }
}

fn cargo_error_str(e: &CargoError) -> String {
    match e {
        CargoError::NotFound(m) => format!("not-found({m})"),
        CargoError::InvalidBooking(m) => format!("invalid-booking({m})"),
        CargoError::InvalidLocation(m) => format!("invalid-location({m})"),
        CargoError::Conflict(m) => format!("conflict({m})"),
    }
}

fn history_str(events: &[HandlingEvent]) -> String {
    events
        .iter()
        .map(|e| format!("{}@{}", event_type_str(e.event_type), e.location.unlocode))
        .collect::<Vec<_>>()
        .join(",")
}

fn run() -> Result<String, String> {
    let origin = Location {
        unlocode: ORIGIN_UNLOCODE.to_string(),
        name: ORIGIN_NAME.to_string(),
        country: ORIGIN_COUNTRY.to_string(),
    };
    let destination = Location {
        unlocode: DEST_UNLOCODE.to_string(),
        name: DEST_NAME.to_string(),
        country: DEST_COUNTRY.to_string(),
    };
    let spec = RouteSpec {
        origin,
        destination,
        arrival_deadline: ARRIVAL_DEADLINE.to_string(),
    };

    // book-cargo
    let b = booking::book_cargo(&spec, WEIGHT_KG).map_err(|e| cargo_error_str(&e))?;

    // get-cargo
    let cargo = booking::get_cargo(&b.cargo_id).map_err(|e| cargo_error_str(&e))?;

    // request-possible-routes -> assign-route
    let routes =
        booking::request_possible_routes(&b.booking_id).map_err(|e| cargo_error_str(&e))?;
    let itinerary = routes
        .into_iter()
        .next()
        .ok_or_else(|| "no candidate itineraries".to_string())?;
    let leg = itinerary
        .legs
        .first()
        .cloned()
        .ok_or_else(|| "itinerary has no legs".to_string())?;
    let assigned =
        booking::assign_route(&b.booking_id, &itinerary).map_err(|e| cargo_error_str(&e))?;

    // register-handling-event x3
    for e in scenario_events() {
        let loc = Location {
            unlocode: e.unlocode.to_string(),
            name: e.name.to_string(),
            country: e.country.to_string(),
        };
        handling::register_handling_event(
            &b.cargo_id,
            e.event_type,
            &loc,
            e.voyage_id,
            e.recorded_at,
        )
        .map_err(|err| cargo_error_str(&err))?;
    }

    // list-handling-events
    let events = handling::list_handling_events(&b.cargo_id).map_err(|e| cargo_error_str(&e))?;

    // cargo-tracker resource
    let tracker = CargoTracker::new(&b.cargo_id);
    let t_id = tracker.tracking_id();
    let t_status = tracker.current_status();
    let t_history = tracker.history();

    Ok(format!(
        "booking={}|cargo={}|weight={}|price={} {}|status={}|itinerary={} {} {}|assigned={}|events={}|tracker={} {} {}|history={}",
        b.booking_id,
        cargo.tracking_id,
        cargo.weight_kg,
        b.price.amount,
        b.price.currency,
        routing_status_str(b.status),
        itinerary.booking_id,
        leg.voyage_id,
        transport_status_str(leg.status),
        routing_status_str(assigned.status),
        events.len(),
        t_id,
        transport_status_str(t_status),
        t_history.len(),
        history_str(&t_history),
    ))
}

fn main() {
    match run() {
        Ok(line) => println!("{line}"),
        Err(e) => {
            eprintln!("cargo-consumer-rust: scenario failed: {e}");
            std::process::exit(1);
        }
    }
}
