// Shape-translation ADAPTER for the cargo domain (ch21).
//
// Like the ch20 filter, this is an interposer on the canonical path: it IMPORTS
// the canonical `patterncatalyst:cargo` interfaces (the real provider, via
// `wac plug`) and EXPORTS them back out (consumed by the HTTP front door). The
// difference is in `book-cargo`: instead of delegating the canonical request
// straight through, it ROUND-TRIPS the request through a deliberately-different
// "legacy" shape (canonical -> legacy -> canonical) before calling the provider.
// Because the translation is lossless for every field the cargo JSON surfaces,
// the exact same cargo JSON still comes back — that round-trip IS the proof.
//
// It also exports the `legacy` interface directly (see wit/world.wit), so a
// legacy-shaped caller can book against the modern provider through the same
// translation.
//
// Interposer gotcha (same as the filter): a world that both imports and exports
// `patterncatalyst:cargo/*` yields TWO distinct Rust type trees — `up` (import /
// provider side) and `dn` (export / front-door side) — so values crossing the
// adapter are converted field-by-field in the `conv` module.
#[allow(warnings)]
mod bindings;

use bindings::patterncatalyst::cargo::booking as up_booking;
use bindings::patterncatalyst::cargo::handling as up_handling;

use bindings::exports::patterncatalyst::cargo::booking::Guest as BookingGuest;
use bindings::exports::patterncatalyst::cargo::handling::{Guest as HandlingGuest, GuestCargoTracker};
use bindings::exports::patterncatalyst::cargo::types::{
    Booking, Cargo, CargoError, HandlingEvent, HandlingEventType, Itinerary, Location, RouteSpec,
    TransportStatus,
};

use bindings::exports::patterncatalyst::cargo_adapter::legacy::{
    Guest as LegacyGuest, LegacyBookingRequest, LegacyServiceLevel,
};

fn log(line: &str) {
    eprintln!("cargo-adapter: {line}");
}

// Mirror of the HTTP front door's UN/LOCODE -> (name, country) lookup, so that
// recovering a canonical `location` from a flat legacy code yields exactly the
// same structured location the front door built — the round-trip is identity for
// the known demo codes, and falls back to (code, "") for any other code.
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

// canonical route-spec -> legacy request. Flattens the structured locations to
// their UN/LOCODE strings, renames the fields, and sets a default service level
// (the canonical model has no such concept).
fn to_legacy(spec: &RouteSpec, weight_kg: f64) -> LegacyBookingRequest {
    LegacyBookingRequest {
        origin_code: spec.origin.unlocode.clone(),
        dest_code: spec.destination.unlocode.clone(),
        cargo_weight: weight_kg,
        needed_by: spec.arrival_deadline.clone(),
        service_level: LegacyServiceLevel::Economy,
    }
}

// legacy request -> canonical (route-spec, weight-kg). Re-inflates the flat codes
// to structured locations via the shared lookup; the service level has no
// canonical counterpart and is dropped.
fn from_legacy(req: &LegacyBookingRequest) -> (RouteSpec, f64) {
    let spec = RouteSpec {
        origin: location_for(&req.origin_code),
        destination: location_for(&req.dest_code),
        arrival_deadline: req.needed_by.clone(),
    };
    (spec, req.cargo_weight)
}

struct Component;

impl BookingGuest for Component {
    fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
        // Round-trip the canonical request through the legacy shape and back,
        // then call the real provider with the re-inflated canonical request.
        let legacy = to_legacy(&spec, weight_kg);
        log(&format!(
            "book-cargo translate canonical -> legacy: origin_code={} dest_code={} cargo_weight={} service_level={:?}",
            legacy.origin_code, legacy.dest_code, legacy.cargo_weight, legacy.service_level
        ));
        let (round_spec, round_weight) = from_legacy(&legacy);
        log(&format!(
            "book-cargo translate legacy -> canonical: origin={} destination={} weight_kg={}",
            round_spec.origin.unlocode, round_spec.destination.unlocode, round_weight
        ));
        up_booking::book_cargo(&conv::route_spec_up(round_spec), round_weight)
            .map(conv::booking_dn)
            .map_err(conv::err_dn)
    }

    fn request_possible_routes(booking_id: String) -> Result<Vec<Itinerary>, CargoError> {
        up_booking::request_possible_routes(&booking_id)
            .map(|v| v.into_iter().map(conv::itinerary_dn).collect())
            .map_err(conv::err_dn)
    }

    fn assign_route(booking_id: String, itinerary: Itinerary) -> Result<Booking, CargoError> {
        up_booking::assign_route(&booking_id, &conv::itinerary_up(itinerary))
            .map(conv::booking_dn)
            .map_err(conv::err_dn)
    }

    fn get_cargo(tracking_id: String) -> Result<Cargo, CargoError> {
        up_booking::get_cargo(&tracking_id)
            .map(conv::cargo_dn)
            .map_err(conv::err_dn)
    }
}

impl LegacyGuest for Component {
    fn book_legacy(req: LegacyBookingRequest) -> Result<Booking, CargoError> {
        log(&format!(
            "book-legacy origin_code={} dest_code={} service_level={:?}",
            req.origin_code, req.dest_code, req.service_level
        ));
        let (spec, weight) = from_legacy(&req);
        up_booking::book_cargo(&conv::route_spec_up(spec), weight)
            .map(conv::booking_dn)
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
        up_handling::list_handling_events(&cargo_id)
            .map(|v| v.into_iter().map(conv::handling_event_dn).collect())
            .map_err(conv::err_dn)
    }
}

struct Tracker {
    inner: up_handling::CargoTracker,
}

impl GuestCargoTracker for Tracker {
    fn new(tracking_id: String) -> Self {
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

// Field-by-field converters between the IMPORT type tree (`up`, provider side)
// and the EXPORT type tree (`dn`, front-door side). Identical to the filter's.
mod conv {
    use crate::bindings::exports::patterncatalyst::cargo::types as dn;
    use crate::bindings::patterncatalyst::cargo::types as up;

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

    pub fn money_dn(m: up::Money) -> dn::Money {
        dn::Money {
            amount: m.amount,
            currency: m.currency,
        }
    }

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

    pub fn handling_event_dn(e: up::HandlingEvent) -> dn::HandlingEvent {
        dn::HandlingEvent {
            cargo_id: e.cargo_id,
            event_type: event_type_dn(e.event_type),
            location: location_dn(e.location),
            voyage_id: e.voyage_id,
            recorded_at: e.recorded_at,
        }
    }

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
