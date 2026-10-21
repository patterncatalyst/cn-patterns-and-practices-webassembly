// Cross-cutting sidecar/filter INTERPOSER for the cargo domain (ch20).
//
// The component IMPORTS the three canonical `patterncatalyst:cargo` interfaces
// (satisfied by the real provider via `wac plug`) and EXPORTS the same three
// interfaces (consumed by the HTTP front door). Because both sides speak the
// identical contract, the filter drops transparently into the composition chain:
//
//   provider (exports cargo) -> filter (imports+exports cargo) -> http door
//
// On the way through it applies two cross-cutting concerns the provider and the
// front door know nothing about:
//
//   1. A destination-embargo POLICY. `book-cargo` and `get-cargo` inspect the
//      destination UN/LOCODE; an embargoed destination is rejected with
//      `cargo-error::invalid-location`, which the front door's `send_error`
//      maps to HTTP 400. A normal destination passes straight through to the
//      provider, unchanged.
//   2. Per-call LOGGING to stderr (the shim / `wasmtime serve` surfaces it in
//      the Pod log), so every domain call is observable without touching the
//      provider or the front door.
//
// Interposer gotcha: when a world both IMPORTS and EXPORTS the same interface,
// wit-bindgen generates TWO distinct Rust type trees — one under
// `bindings::patterncatalyst::cargo::types` (the import side) and one under
// `bindings::exports::patterncatalyst::cargo::types` (the export side). They are
// structurally identical but nominally distinct, so every value crossing the
// filter is converted field-by-field in the `conv` module below.
#[allow(warnings)]
mod bindings;

// Imported (upstream) canonical cargo interfaces — the real provider.
use bindings::patterncatalyst::cargo::booking as up_booking;
use bindings::patterncatalyst::cargo::handling as up_handling;

// Exported (downstream) canonical cargo interfaces — what the front door calls.
use bindings::exports::patterncatalyst::cargo::booking::Guest as BookingGuest;
use bindings::exports::patterncatalyst::cargo::handling::{Guest as HandlingGuest, GuestCargoTracker};
use bindings::exports::patterncatalyst::cargo::types::{
    Booking, Cargo, CargoError, HandlingEvent, HandlingEventType, Itinerary, Location, RouteSpec,
    TransportStatus,
};

// Destinations under embargo. A booking or lookup whose DESTINATION UN/LOCODE is
// in this set is rejected by the policy before it ever reaches the provider. The
// codes are real UN/LOCODEs chosen for the demo (Havana / Tehran / Nampo).
const EMBARGOED: &[&str] = &["CUHAV", "IRTHR", "KPFNJ"];

fn is_embargoed(unlocode: &str) -> bool {
    EMBARGOED.iter().any(|&e| e.eq_ignore_ascii_case(unlocode))
}

fn log(line: &str) {
    eprintln!("cargo-filter: {line}");
}

struct Component;

impl BookingGuest for Component {
    fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
        log(&format!(
            "book-cargo origin={} destination={} weight_kg={}",
            spec.origin.unlocode, spec.destination.unlocode, weight_kg
        ));
        if is_embargoed(&spec.destination.unlocode) {
            log(&format!(
                "POLICY DENY book-cargo: destination {} is under embargo",
                spec.destination.unlocode
            ));
            return Err(CargoError::InvalidLocation(format!(
                "destination {} is under embargo",
                spec.destination.unlocode
            )));
        }
        // Normal destination: delegate unchanged to the real provider.
        up_booking::book_cargo(&conv::route_spec_up(spec), weight_kg)
            .map(conv::booking_dn)
            .map_err(conv::err_dn)
    }

    fn request_possible_routes(booking_id: String) -> Result<Vec<Itinerary>, CargoError> {
        log(&format!("request-possible-routes booking_id={booking_id}"));
        up_booking::request_possible_routes(&booking_id)
            .map(|v| v.into_iter().map(conv::itinerary_dn).collect())
            .map_err(conv::err_dn)
    }

    fn assign_route(booking_id: String, itinerary: Itinerary) -> Result<Booking, CargoError> {
        log(&format!("assign-route booking_id={booking_id}"));
        up_booking::assign_route(&booking_id, &conv::itinerary_up(itinerary))
            .map(conv::booking_dn)
            .map_err(conv::err_dn)
    }

    fn get_cargo(tracking_id: String) -> Result<Cargo, CargoError> {
        log(&format!("get-cargo tracking_id={tracking_id}"));
        // The tracking id shape is CARGO-{ORIGIN}-{DESTINATION}; apply the same
        // embargo policy on the destination so a direct lookup of an embargoed
        // cargo is rejected just like the booking would have been.
        let parts: Vec<&str> = tracking_id.splitn(3, '-').collect();
        if parts.len() == 3 && parts[0] == "CARGO" && is_embargoed(parts[2]) {
            log(&format!(
                "POLICY DENY get-cargo: destination {} is under embargo",
                parts[2]
            ));
            return Err(CargoError::InvalidLocation(format!(
                "destination {} is under embargo",
                parts[2]
            )));
        }
        up_booking::get_cargo(&tracking_id)
            .map(conv::cargo_dn)
            .map_err(conv::err_dn)
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
        log(&format!("register-handling-event cargo_id={cargo_id}"));
        up_handling::register_handling_event(
            &cargo_id,
            conv::event_type_up(event_type),
            &conv::location_up(location),
            &voyage_id,
            &recorded_at,
        )
        .map_err(conv::err_dn)
    }

    fn list_handling_events(cargo_id: String) -> Result<Vec<HandlingEvent>, CargoError> {
        log(&format!("list-handling-events cargo_id={cargo_id}"));
        up_handling::list_handling_events(&cargo_id)
            .map(|v| v.into_iter().map(conv::handling_event_dn).collect())
            .map_err(conv::err_dn)
    }
}

// The exported `cargo-tracker` resource wraps an imported tracker from the real
// provider and delegates every method, so the resource semantics also pass
// through the interposer unchanged.
struct Tracker {
    inner: up_handling::CargoTracker,
}

impl GuestCargoTracker for Tracker {
    fn new(tracking_id: String) -> Self {
        log(&format!("cargo-tracker::new tracking_id={tracking_id}"));
        Tracker {
            inner: up_handling::CargoTracker::new(&tracking_id),
        }
    }

    fn tracking_id(&self) -> String {
        self.inner.tracking_id()
    }

    fn current_status(&self) -> TransportStatus {
        conv::transport_status_dn(self.inner.current_status())
    }

    fn history(&self) -> Vec<HandlingEvent> {
        self.inner
            .history()
            .into_iter()
            .map(conv::handling_event_dn)
            .collect()
    }
}

// Field-by-field converters between the IMPORT type tree (`up`, the provider
// side) and the EXPORT type tree (`dn`, the front-door side). The two trees are
// structurally identical; these functions are the only place the nominal
// difference is bridged.
mod conv {
    use crate::bindings::exports::patterncatalyst::cargo::types as dn;
    use crate::bindings::patterncatalyst::cargo::types as up;

    // --- Location (both directions) ---
    pub fn location_up(l: dn::Location) -> up::Location {
        up::Location {
            unlocode: l.unlocode,
            name: l.name,
            country: l.country,
        }
    }
    pub fn location_dn(l: up::Location) -> dn::Location {
        dn::Location {
            unlocode: l.unlocode,
            name: l.name,
            country: l.country,
        }
    }

    // --- Money (up -> dn) ---
    pub fn money_dn(m: up::Money) -> dn::Money {
        dn::Money {
            amount: m.amount,
            currency: m.currency,
        }
    }

    // --- Enums ---
    pub fn event_type_up(e: dn::HandlingEventType) -> up::HandlingEventType {
        match e {
            dn::HandlingEventType::Unspecified => up::HandlingEventType::Unspecified,
            dn::HandlingEventType::Received => up::HandlingEventType::Received,
            dn::HandlingEventType::Loaded => up::HandlingEventType::Loaded,
            dn::HandlingEventType::Unloaded => up::HandlingEventType::Unloaded,
            dn::HandlingEventType::Customs => up::HandlingEventType::Customs,
            dn::HandlingEventType::Claimed => up::HandlingEventType::Claimed,
        }
    }
    pub fn event_type_dn(e: up::HandlingEventType) -> dn::HandlingEventType {
        match e {
            up::HandlingEventType::Unspecified => dn::HandlingEventType::Unspecified,
            up::HandlingEventType::Received => dn::HandlingEventType::Received,
            up::HandlingEventType::Loaded => dn::HandlingEventType::Loaded,
            up::HandlingEventType::Unloaded => dn::HandlingEventType::Unloaded,
            up::HandlingEventType::Customs => dn::HandlingEventType::Customs,
            up::HandlingEventType::Claimed => dn::HandlingEventType::Claimed,
        }
    }
    pub fn routing_status_dn(s: up::RoutingStatus) -> dn::RoutingStatus {
        match s {
            up::RoutingStatus::Unspecified => dn::RoutingStatus::Unspecified,
            up::RoutingStatus::NotRouted => dn::RoutingStatus::NotRouted,
            up::RoutingStatus::Routed => dn::RoutingStatus::Routed,
            up::RoutingStatus::Misrouted => dn::RoutingStatus::Misrouted,
        }
    }
    pub fn transport_status_up(s: dn::TransportStatus) -> up::TransportStatus {
        match s {
            dn::TransportStatus::Unspecified => up::TransportStatus::Unspecified,
            dn::TransportStatus::Planned => up::TransportStatus::Planned,
            dn::TransportStatus::InTransit => up::TransportStatus::InTransit,
            dn::TransportStatus::Completed => up::TransportStatus::Completed,
            dn::TransportStatus::Delayed => up::TransportStatus::Delayed,
        }
    }
    pub fn transport_status_dn(s: up::TransportStatus) -> dn::TransportStatus {
        match s {
            up::TransportStatus::Unspecified => dn::TransportStatus::Unspecified,
            up::TransportStatus::Planned => dn::TransportStatus::Planned,
            up::TransportStatus::InTransit => dn::TransportStatus::InTransit,
            up::TransportStatus::Completed => dn::TransportStatus::Completed,
            up::TransportStatus::Delayed => dn::TransportStatus::Delayed,
        }
    }

    // --- RouteSpec (dn -> up) ---
    pub fn route_spec_up(s: dn::RouteSpec) -> up::RouteSpec {
        up::RouteSpec {
            origin: location_up(s.origin),
            destination: location_up(s.destination),
            arrival_deadline: s.arrival_deadline,
        }
    }
    pub fn route_spec_dn(s: up::RouteSpec) -> dn::RouteSpec {
        dn::RouteSpec {
            origin: location_dn(s.origin),
            destination: location_dn(s.destination),
            arrival_deadline: s.arrival_deadline,
        }
    }

    // --- Booking / Cargo (up -> dn) ---
    pub fn booking_dn(b: up::Booking) -> dn::Booking {
        dn::Booking {
            booking_id: b.booking_id,
            cargo_id: b.cargo_id,
            route_spec: route_spec_dn(b.route_spec),
            price: money_dn(b.price),
            status: routing_status_dn(b.status),
        }
    }
    pub fn cargo_dn(c: up::Cargo) -> dn::Cargo {
        dn::Cargo {
            tracking_id: c.tracking_id,
            origin: location_dn(c.origin),
            destination: location_dn(c.destination),
            weight_kg: c.weight_kg,
        }
    }

    // --- Leg / Itinerary (both directions) ---
    pub fn leg_up(l: dn::Leg) -> up::Leg {
        up::Leg {
            voyage_id: l.voyage_id,
            load_location: location_up(l.load_location),
            unload_location: location_up(l.unload_location),
            load_time: l.load_time,
            unload_time: l.unload_time,
            status: transport_status_up(l.status),
        }
    }
    pub fn leg_dn(l: up::Leg) -> dn::Leg {
        dn::Leg {
            voyage_id: l.voyage_id,
            load_location: location_dn(l.load_location),
            unload_location: location_dn(l.unload_location),
            load_time: l.load_time,
            unload_time: l.unload_time,
            status: transport_status_dn(l.status),
        }
    }
    pub fn itinerary_up(it: dn::Itinerary) -> up::Itinerary {
        up::Itinerary {
            booking_id: it.booking_id,
            legs: it.legs.into_iter().map(leg_up).collect(),
        }
    }
    pub fn itinerary_dn(it: up::Itinerary) -> dn::Itinerary {
        dn::Itinerary {
            booking_id: it.booking_id,
            legs: it.legs.into_iter().map(leg_dn).collect(),
        }
    }

    // --- HandlingEvent (up -> dn) ---
    pub fn handling_event_dn(e: up::HandlingEvent) -> dn::HandlingEvent {
        dn::HandlingEvent {
            cargo_id: e.cargo_id,
            event_type: event_type_dn(e.event_type),
            location: location_dn(e.location),
            voyage_id: e.voyage_id,
            recorded_at: e.recorded_at,
        }
    }

    // --- CargoError (up -> dn) ---
    pub fn err_dn(e: up::CargoError) -> dn::CargoError {
        match e {
            up::CargoError::NotFound(m) => dn::CargoError::NotFound(m),
            up::CargoError::InvalidBooking(m) => dn::CargoError::InvalidBooking(m),
            up::CargoError::InvalidLocation(m) => dn::CargoError::InvalidLocation(m),
            up::CargoError::Conflict(m) => dn::CargoError::Conflict(m),
        }
    }
}

bindings::export!(Component with_types_in bindings);
