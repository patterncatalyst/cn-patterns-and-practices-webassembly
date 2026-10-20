// Rust provider for the `cargo` world (contracts/wit, package
// patterncatalyst:cargo@0.1.0). cargo-component generates `bindings` from the
// shared contract (see Cargo.toml's [package.metadata.component.target]); this
// file implements the three exported interfaces — `types` (data only, no
// trait to implement), `booking`, and `handling` (including the
// `cargo-tracker` resource) — over simple in-memory state.
//
// The same domain logic is implemented in ../go against the same contract; the
// host in ../host runs BOTH components through an identical scenario and
// asserts byte-for-byte-equal domain results. Keep the constants below
// (voyage id, times, price, id formats, status mapping) in lockstep with the
// Go implementation or the cross-language equality check will fail.
#[allow(warnings)]
mod bindings;

use std::cell::RefCell;
use std::collections::HashMap;

use bindings::exports::patterncatalyst::cargo::booking::Guest as BookingGuest;
use bindings::exports::patterncatalyst::cargo::handling::{
    Guest as HandlingGuest, GuestCargoTracker,
};
use bindings::exports::patterncatalyst::cargo::types::{
    Booking, Cargo, CargoError, HandlingEvent, HandlingEventType, Itinerary, Leg, Location, Money,
    RouteSpec, RoutingStatus, TransportStatus,
};

// ---------------------------------------------------------------------------
// Deterministic domain constants — MUST match the Go implementation exactly.
// ---------------------------------------------------------------------------
const VOYAGE_ID: &str = "VOY-001";
const LEG_LOAD_TIME: &str = "2026-11-01T00:00:00Z";
const PRICE_AMOUNT: &str = "1500.00";
const PRICE_CURRENCY: &str = "USD";

fn tracking_id_for(origin: &Location, destination: &Location) -> String {
    format!("CARGO-{}-{}", origin.unlocode, destination.unlocode)
}

fn booking_id_for(origin: &Location, destination: &Location) -> String {
    format!("BOOKING-{}-{}", origin.unlocode, destination.unlocode)
}

// Map the most recent handling event to the cargo's transport status. No
// events -> `unspecified` (the contract's explicit zero value). Shared with
// the Go implementation.
fn status_from_last_event(event_type: HandlingEventType) -> TransportStatus {
    match event_type {
        HandlingEventType::Unspecified => TransportStatus::Unspecified,
        HandlingEventType::Received => TransportStatus::Planned,
        HandlingEventType::Loaded => TransportStatus::InTransit,
        HandlingEventType::Unloaded => TransportStatus::InTransit,
        HandlingEventType::Customs => TransportStatus::InTransit,
        HandlingEventType::Claimed => TransportStatus::Completed,
    }
}

// ---------------------------------------------------------------------------
// In-memory state. A component instance keeps its linear memory across export
// calls within one host Store, so this thread-local survives the whole
// scenario. WASM components are single-threaded, so a RefCell is sufficient —
// no locking needed.
// ---------------------------------------------------------------------------
#[derive(Default)]
struct State {
    cargos: HashMap<String, Cargo>,
    bookings: HashMap<String, Booking>,
    events: HashMap<String, Vec<HandlingEvent>>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

struct Component;

impl BookingGuest for Component {
    fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
        if spec.origin.unlocode.is_empty() || spec.destination.unlocode.is_empty() {
            return Err(CargoError::InvalidLocation(
                "origin and destination must each have a UN/LOCODE".to_string(),
            ));
        }
        if weight_kg <= 0.0 {
            return Err(CargoError::InvalidBooking(
                "weight-kg must be greater than zero".to_string(),
            ));
        }

        let tracking_id = tracking_id_for(&spec.origin, &spec.destination);
        let booking_id = booking_id_for(&spec.origin, &spec.destination);

        let cargo = Cargo {
            tracking_id: tracking_id.clone(),
            origin: spec.origin.clone(),
            destination: spec.destination.clone(),
            weight_kg,
        };
        let booking = Booking {
            booking_id: booking_id.clone(),
            cargo_id: tracking_id.clone(),
            route_spec: spec,
            price: Money {
                amount: PRICE_AMOUNT.to_string(),
                currency: PRICE_CURRENCY.to_string(),
            },
            status: RoutingStatus::NotRouted,
        };

        STATE.with(|s| {
            let mut s = s.borrow_mut();
            s.cargos.insert(tracking_id, cargo);
            s.bookings.insert(booking_id, booking.clone());
        });
        Ok(booking)
    }

    fn request_possible_routes(booking_id: String) -> Result<Vec<Itinerary>, CargoError> {
        STATE.with(|s| {
            let s = s.borrow();
            let booking = s
                .bookings
                .get(&booking_id)
                .ok_or_else(|| CargoError::NotFound(format!("no booking {booking_id}")))?;
            let spec = &booking.route_spec;
            let itinerary = Itinerary {
                booking_id: booking_id.clone(),
                legs: vec![Leg {
                    voyage_id: VOYAGE_ID.to_string(),
                    load_location: spec.origin.clone(),
                    unload_location: spec.destination.clone(),
                    load_time: LEG_LOAD_TIME.to_string(),
                    unload_time: spec.arrival_deadline.clone(),
                    status: TransportStatus::Planned,
                }],
            };
            Ok(vec![itinerary])
        })
    }

    fn assign_route(booking_id: String, itinerary: Itinerary) -> Result<Booking, CargoError> {
        if itinerary.legs.is_empty() {
            return Err(CargoError::InvalidBooking(
                "itinerary must have at least one leg".to_string(),
            ));
        }
        STATE.with(|s| {
            let mut s = s.borrow_mut();
            let booking = s
                .bookings
                .get_mut(&booking_id)
                .ok_or_else(|| CargoError::NotFound(format!("no booking {booking_id}")))?;
            booking.status = RoutingStatus::Routed;
            Ok(booking.clone())
        })
    }

    fn get_cargo(tracking_id: String) -> Result<Cargo, CargoError> {
        STATE.with(|s| {
            s.borrow()
                .cargos
                .get(&tracking_id)
                .cloned()
                .ok_or_else(|| CargoError::NotFound(format!("no cargo {tracking_id}")))
        })
    }
}

impl HandlingGuest for Component {
    type CargoTracker = Tracker;

    fn register_handling_event(
        cargo_id: String,
        event_type: HandlingEventType,
        location: Location,
        voyage_id: String,
        recorded_at: String,
    ) -> Result<(), CargoError> {
        STATE.with(|s| {
            let mut s = s.borrow_mut();
            if !s.cargos.contains_key(&cargo_id) {
                return Err(CargoError::NotFound(format!("no cargo {cargo_id}")));
            }
            let event = HandlingEvent {
                cargo_id: cargo_id.clone(),
                event_type,
                location,
                voyage_id,
                recorded_at,
            };
            s.events.entry(cargo_id).or_default().push(event);
            Ok(())
        })
    }

    fn list_handling_events(cargo_id: String) -> Result<Vec<HandlingEvent>, CargoError> {
        STATE.with(|s| Ok(s.borrow().events.get(&cargo_id).cloned().unwrap_or_default()))
    }
}

// The `cargo-tracker` resource. It holds only its tracking id; `history` and
// `current-status` read the live shared event state by that id, so a tracker
// constructed before events are registered still reflects them when queried.
struct Tracker {
    tracking_id: String,
}

impl GuestCargoTracker for Tracker {
    fn new(tracking_id: String) -> Self {
        Tracker { tracking_id }
    }

    fn tracking_id(&self) -> String {
        self.tracking_id.clone()
    }

    fn current_status(&self) -> TransportStatus {
        STATE.with(|s| {
            s.borrow()
                .events
                .get(&self.tracking_id)
                .and_then(|events| events.last())
                .map(|last| status_from_last_event(last.event_type))
                .unwrap_or(TransportStatus::Unspecified)
        })
    }

    fn history(&self) -> Vec<HandlingEvent> {
        STATE.with(|s| {
            s.borrow()
                .events
                .get(&self.tracking_id)
                .cloned()
                .unwrap_or_default()
        })
    }
}

bindings::export!(Component with_types_in bindings);
