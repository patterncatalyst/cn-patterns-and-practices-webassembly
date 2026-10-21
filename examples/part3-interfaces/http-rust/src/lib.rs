// HTTP front door for the cargo domain, as a WebAssembly component (ch11).
//
// The component EXPORTS `wasi:http/incoming-handler` (via the `wasi:http/proxy`
// world) and IMPORTS the three `patterncatalyst:cargo` interfaces (see
// wit/world.wit). It terminates HTTP inside the sandbox and, per request, calls
// the imported `booking` interface ACROSS the component boundary. Composed with
// a `cargo` provider (`wac plug`), the composed artifact serves directly under
// `wasmtime serve` — no native host.
//
// Routing:
//   GET /cargo/{id}  where id == CARGO-{ORIGIN}-{DEST} (two UN/LOCODEs)
//     -> book-cargo (seeds this per-request provider instance) then get-cargo
//     -> 200 application/json with the cargo + agreed price
//   GET /cargo/{anything-else}
//     -> get-cargo returns cargo-error::not-found -> 404
//
// Why book THEN get in one request: the part2 provider keeps domain state in
// component-instance memory, and `wasmtime serve` uses a fresh instance per
// request, so a bare get-cargo on a cold instance always misses. Booking first
// is how the handler demonstrates a real cross-component call that returns data
// AND the not-found -> 404 mapping (any id that is not a CARGO-O-D triple is
// never booked, so get-cargo legitimately misses).
#[allow(warnings)]
mod bindings;

use bindings::exports::wasi::http::incoming_handler::Guest;
use bindings::patterncatalyst::cargo::booking;
use bindings::patterncatalyst::cargo::types::{CargoError, Location, RouteSpec};
use bindings::wasi::http::types::{
    Fields, IncomingRequest, OutgoingBody, OutgoingResponse, ResponseOutparam,
};

const DEFAULT_WEIGHT_KG: f64 = 1200.5;
const ARRIVAL_DEADLINE: &str = "2026-12-01T00:00:00Z";

struct Component;

// Minimal UN/LOCODE -> (name, country) lookup for the demo locations. The
// provider does not validate name/country, so unknown codes fall back to the
// code itself and an empty country; the tracking id and price are unaffected.
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

fn send(response_out: ResponseOutparam, status: u16, body: &[u8]) {
    let headers = Fields::new();
    headers
        .set(&"content-type".to_string(), &[b"application/json".to_vec()])
        .expect("set content-type");
    let resp = OutgoingResponse::new(headers);
    resp.set_status_code(status).expect("set status code");
    // Obtain the body handle BEFORE handing the response to the outparam: the
    // outparam call moves the OutgoingResponse.
    let out_body = resp.body().expect("response body");
    ResponseOutparam::set(response_out, Ok(resp));
    let stream = out_body.write().expect("body write stream");
    stream
        .blocking_write_and_flush(body)
        .expect("write body bytes");
    drop(stream);
    OutgoingBody::finish(out_body, None).expect("finish body");
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

impl Guest for Component {
    fn handle(request: IncomingRequest, response_out: ResponseOutparam) {
        let path = request.path_with_query().unwrap_or_default();
        let raw = path.split('?').next().unwrap_or("");

        let id = match raw.strip_prefix("/cargo/") {
            Some(rest) if !rest.is_empty() => rest.to_string(),
            _ => {
                send(
                    response_out,
                    404,
                    br#"{"error":"not found","hint":"GET /cargo/{id}"}"#,
                );
                return;
            }
        };

        // Known shape CARGO-{ORIGIN}-{DEST}: book (seed) then read back.
        let parts: Vec<&str> = id.splitn(3, '-').collect();
        if parts.len() == 3 && parts[0] == "CARGO" {
            let spec = RouteSpec {
                origin: location_for(parts[1]),
                destination: location_for(parts[2]),
                arrival_deadline: ARRIVAL_DEADLINE.to_string(),
            };
            match booking::book_cargo(&spec, DEFAULT_WEIGHT_KG) {
                Ok(b) => match booking::get_cargo(&b.cargo_id) {
                    Ok(cargo) => {
                        let body = format!(
                            "{{\"tracking_id\":\"{}\",\"origin\":\"{}\",\"destination\":\"{}\",\"weight_kg\":{},\"price\":{{\"amount\":\"{}\",\"currency\":\"{}\"}}}}",
                            json_escape(&cargo.tracking_id),
                            json_escape(&cargo.origin.unlocode),
                            json_escape(&cargo.destination.unlocode),
                            cargo.weight_kg,
                            json_escape(&b.price.amount),
                            json_escape(&b.price.currency),
                        );
                        send(response_out, 200, body.as_bytes());
                    }
                    Err(e) => send_error(response_out, &e),
                },
                Err(e) => send_error(response_out, &e),
            }
            return;
        }

        // Any other id is never booked, so get-cargo legitimately misses.
        match booking::get_cargo(&id) {
            Ok(cargo) => {
                let body = format!(
                    "{{\"tracking_id\":\"{}\"}}",
                    json_escape(&cargo.tracking_id)
                );
                send(response_out, 200, body.as_bytes());
            }
            Err(e) => send_error(response_out, &e),
        }
    }
}

fn send_error(response_out: ResponseOutparam, e: &CargoError) {
    let (status, msg): (u16, String) = match e {
        CargoError::NotFound(m) => (404, m.clone()),
        CargoError::InvalidBooking(m) => (400, m.clone()),
        CargoError::InvalidLocation(m) => (400, m.clone()),
        CargoError::Conflict(m) => (409, m.clone()),
    };
    let body = format!("{{\"error\":\"{}\"}}", json_escape(&msg));
    send(response_out, status, body.as_bytes());
}

bindings::export!(Component with_types_in bindings);
