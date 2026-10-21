// ch23 Kafka message HANDLER for the cargo domain (serverless scale-to-zero).
//
// EXPORTS `wasmcloud:messaging/handler` — called once per Kafka message
// delivered by the `messaging-kafka` capability provider, which wadm links to
// this component (see ../k8s/wasmcloud/wadm-kafka.yaml). IMPORTS the cargo
// domain's `handling` interface from the repository contract and performs a
// real write — `register-handling-event` — against whichever cargo provider
// wadm links this component to. This is the workload KEDA's `kafka`
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
// drop — the handler is honest about what it can and cannot process.
#[allow(warnings)]
mod bindings;

use bindings::exports::wasmcloud::messaging::handler::Guest as HandlerGuest;
use bindings::exports::wasmcloud::messaging::types::BrokerMessage;
use bindings::patterncatalyst::cargo::handling;
use bindings::patterncatalyst::cargo::types::{HandlingEventType, Location};

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
