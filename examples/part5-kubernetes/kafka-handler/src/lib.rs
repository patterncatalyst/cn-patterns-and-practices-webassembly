// ch23 Kafka message HANDLER for the cargo domain (serverless scale-to-zero).
//
// EXPORTS `wasmcloud:messaging/handler` — called once per Kafka message
// delivered by the `messaging-kafka` capability provider, which wadm links to
// this component (see ../k8s/wasmcloud/wadm-kafka.yaml). IMPORTS the cargo
// domain's `booking` and `handling` interfaces from the repository contract
// and performs a real write — `register-handling-event` — against whichever
// cargo provider wadm links this component to. This is the workload KEDA's `kafka`
// ScaledObject OBSERVES consumer-group lag for while the wadm spreadscaler
// OWNS the actual replica count (see ../k8s/keda/base/kafka-scaledobject.yaml).
//
// Wire format (deliberately simple, no JSON crate — matching the
// zero-extra-dependency convention of the sibling cargo-filter/cargo-adapter
// crates): a pipe-delimited record
//
//     CARGO_ID|EVENT_TYPE|UNLOCODE|VOYAGE_ID|RECORDED_AT
//
// e.g. "CARGO-USNYC-DEHAM|loaded|DEHAM|VOY-001|2026-11-01T00:00:00Z". A real
// deployment would carry CloudEvents/JSON on the wire; the point of this
// handler is the KEDA/wadm scaling story (../_docs ch23), not the message
// envelope, so the parser stays small and dependency-free. Every malformed or
// unrecognized message is a genuine rejected `result<_, string>`, not a silent
// drop — the handler surfaces what it can and cannot process.
//
// A handling event records against an existing cargo, so each message first
// ensures the cargo is on record — booking it from the id if `get-cargo`
// reports none — before registering the event. Booking is an upsert keyed on
// the cargo id, not a create-once step, which keeps each invocation
// self-contained.
#[allow(warnings)]
mod bindings;

use bindings::exports::wasmcloud::messaging::handler::Guest as HandlerGuest;
use bindings::exports::wasmcloud::messaging::types::BrokerMessage;
use bindings::patterncatalyst::cargo::booking;
use bindings::patterncatalyst::cargo::handling;
use bindings::patterncatalyst::cargo::types::{CargoError, HandlingEventType, Location, RouteSpec};

fn log(line: &str) {
    eprintln!("kafka-handler: {line}");
}

fn event_type_from(s: &str) -> Option<HandlingEventType> {
    match s {
        "received" => Some(HandlingEventType::Received),
        "loaded" => Some(HandlingEventType::Loaded),
        "unloaded" => Some(HandlingEventType::Unloaded),
        "customs" => Some(HandlingEventType::Customs),
        "claimed" => Some(HandlingEventType::Claimed),
        _ => None,
    }
}

// Placeholder weight for a cargo this handler books on first contact. The
// Kafka wire format carries no weight field; Part 2's booking workflow is
// authoritative for a cargo's real weight once it exists.
const DEFAULT_WEIGHT_KG: f64 = 1_000.0;

/// Splits a cargo id of the form `CARGO-<ORIGIN>-<DEST>` (the format the
/// cargo provider's `book-cargo` generates — see Part 2's `tracking_id_for`)
/// back into its origin and destination UN/LOCODEs.
fn locations_from_cargo_id(cargo_id: &str) -> Option<(&str, &str)> {
    let rest = cargo_id.strip_prefix("CARGO-")?;
    let mut parts = rest.splitn(2, '-');
    let origin = parts.next()?;
    let destination = parts.next()?;
    if origin.is_empty() || destination.is_empty() {
        return None;
    }
    Some((origin, destination))
}

/// Ensures `cargo_id` is on record before a handling event is registered
/// against it: looks it up, and books it from the id's own origin/destination
/// UN/LOCODEs when absent.
fn ensure_cargo_booked(cargo_id: &str, recorded_at: &str) -> Result<(), String> {
    match booking::get_cargo(cargo_id) {
        Ok(_) => Ok(()),
        Err(CargoError::NotFound(_)) => {
            let (origin, destination) = locations_from_cargo_id(cargo_id).ok_or_else(|| {
                format!(
                    "cannot derive origin/destination from cargo-id '{cargo_id}': \
                     expected CARGO-<ORIGIN>-<DEST>"
                )
            })?;
            let spec = RouteSpec {
                origin: Location {
                    unlocode: origin.to_string(),
                    name: origin.to_string(),
                    country: origin.to_string(),
                },
                destination: Location {
                    unlocode: destination.to_string(),
                    name: destination.to_string(),
                    country: destination.to_string(),
                },
                arrival_deadline: recorded_at.to_string(),
            };
            booking::book_cargo(&spec, DEFAULT_WEIGHT_KG)
                .map(|_| ())
                .map_err(|e| format!("book-cargo failed for cargo_id={cargo_id}: {e:?}"))
        }
        Err(e) => Err(format!("get-cargo failed for cargo_id={cargo_id}: {e:?}")),
    }
}

struct Component;

impl HandlerGuest for Component {
    fn handle_message(msg: BrokerMessage) -> Result<(), String> {
        let body = String::from_utf8(msg.body)
            .map_err(|e| format!("message body on subject '{}' is not valid UTF-8: {e}", msg.subject))?;
        log(&format!("received subject={} body={body:?}", msg.subject));

        let fields: Vec<&str> = body.splitn(5, '|').collect();
        if fields.len() != 5 {
            return Err(format!(
                "malformed message: expected 5 pipe-delimited fields \
                 (CARGO_ID|EVENT_TYPE|UNLOCODE|VOYAGE_ID|RECORDED_AT), got {}: {body:?}",
                fields.len()
            ));
        }
        let cargo_id = fields[0];
        let event_type_str = fields[1];
        let unlocode = fields[2];
        let voyage_id = fields[3];
        let recorded_at = fields[4];

        if cargo_id.is_empty() || unlocode.is_empty() {
            return Err(format!(
                "malformed message: cargo-id and unlocode must not be empty: {body:?}"
            ));
        }
        let event_type = event_type_from(event_type_str).ok_or_else(|| {
            format!(
                "unknown event type '{event_type_str}' (want one of \
                 received|loaded|unloaded|customs|claimed): {body:?}"
            )
        })?;

        // Demo simplification: the Kafka wire format carries only the
        // UN/LOCODE, not a full location lookup — name/country both default to
        // the code itself. The cargo provider (Part 2) is authoritative for any
        // display-quality location data; this handler's job is to record that
        // a handling event happened, not to enrich it.
        let location = Location {
            unlocode: unlocode.to_string(),
            name: unlocode.to_string(),
            country: unlocode.to_string(),
        };

        ensure_cargo_booked(cargo_id, recorded_at)?;

        handling::register_handling_event(cargo_id, event_type, &location, voyage_id, recorded_at)
            .map_err(|e| format!("register-handling-event failed for cargo_id={cargo_id}: {e:?}"))?;

        log(&format!(
            "recorded handling event cargo_id={cargo_id} event_type={event_type_str} \
             location={unlocode} voyage_id={voyage_id} recorded_at={recorded_at}"
        ));
        Ok(())
    }
}

bindings::export!(Component with_types_in bindings);
