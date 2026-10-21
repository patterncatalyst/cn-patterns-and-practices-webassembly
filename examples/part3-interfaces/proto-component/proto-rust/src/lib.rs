// Protobuf codec component for the cargo domain (ch12).
//
// Exports `codec.get-cargo(list<u8>) -> result<list<u8>, string>` and imports
// the cargo `booking` interface. The handler:
//   1. prost-DECODES the request bytes into a GetCargoRequest,
//   2. parses the tracking id, books + reads the cargo over the WIT boundary,
//   3. prost-ENCODES a GetCargoResponse and returns the bytes.
// All protobuf (de)serialization runs inside the Wasm sandbox with prost.
#[allow(warnings)]
mod bindings;

// prost-generated messages (proto/cargo.proto -> OUT_DIR via build.rs).
mod pb {
    include!(concat!(env!("OUT_DIR"), "/patterncatalyst.cargo.v1.rs"));
}

use bindings::exports::patterncatalyst::cargo_proto::codec::Guest;
use bindings::patterncatalyst::cargo::booking;
use bindings::patterncatalyst::cargo::types::{CargoError, Location, RouteSpec};

use prost::Message;

const DEFAULT_WEIGHT_KG: f64 = 1200.5;
const ARRIVAL_DEADLINE: &str = "2026-12-01T00:00:00Z";

struct Component;

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

fn err_message(e: &CargoError) -> String {
    match e {
        CargoError::NotFound(m) => format!("not-found: {m}"),
        CargoError::InvalidBooking(m) => format!("invalid-booking: {m}"),
        CargoError::InvalidLocation(m) => format!("invalid-location: {m}"),
        CargoError::Conflict(m) => format!("conflict: {m}"),
    }
}

fn error_response(msg: String) -> Vec<u8> {
    let resp = pb::GetCargoResponse {
        cargo: None,
        price: None,
        error: msg,
    };
    resp.encode_to_vec()
}

impl Guest for Component {
    fn get_cargo(request: Vec<u8>) -> Result<Vec<u8>, String> {
        // prost DECODE inside the sandbox.
        let req = pb::GetCargoRequest::decode(request.as_slice())
            .map_err(|e| format!("protobuf decode error: {e}"))?;

        let id = req.tracking_id;
        let parts: Vec<&str> = id.splitn(3, '-').collect();
        if !(parts.len() == 3 && parts[0] == "CARGO") {
            // Not a known id shape: dispatch anyway so a genuine domain miss is
            // encoded as a protobuf response-level error.
            return Ok(match booking::get_cargo(&id) {
                Ok(c) => encode_ok(&c, None),
                Err(e) => error_response(err_message(&e)),
            });
        }

        let spec = RouteSpec {
            origin: location_for(parts[1]),
            destination: location_for(parts[2]),
            arrival_deadline: ARRIVAL_DEADLINE.to_string(),
        };
        match booking::book_cargo(&spec, DEFAULT_WEIGHT_KG) {
            Ok(b) => match booking::get_cargo(&b.cargo_id) {
                Ok(cargo) => Ok(encode_ok(&cargo, Some(&b.price))),
                Err(e) => Ok(error_response(err_message(&e))),
            },
            Err(e) => Ok(error_response(err_message(&e))),
        }
    }
}

fn encode_ok(
    cargo: &bindings::patterncatalyst::cargo::types::Cargo,
    price: Option<&bindings::patterncatalyst::cargo::types::Money>,
) -> Vec<u8> {
    let resp = pb::GetCargoResponse {
        cargo: Some(pb::Cargo {
            tracking_id: cargo.tracking_id.clone(),
            origin: Some(pb::Location {
                unlocode: cargo.origin.unlocode.clone(),
                name: cargo.origin.name.clone(),
                country: cargo.origin.country.clone(),
            }),
            destination: Some(pb::Location {
                unlocode: cargo.destination.unlocode.clone(),
                name: cargo.destination.name.clone(),
                country: cargo.destination.country.clone(),
            }),
            weight_kg: cargo.weight_kg,
        }),
        price: price.map(|p| pb::Money {
            amount: p.amount.clone(),
            currency: p.currency.clone(),
        }),
        error: String::new(),
    };
    resp.encode_to_vec()
}

bindings::export!(Component with_types_in bindings);
