// examples/part6-deviations/istio-wasmfilter/src/lib.rs
//
// A proxy-wasm HTTP filter for Envoy / Istio's WasmPlugin resource.
//
// This is the Envoy ABI, not the Component Model: `proxy_wasm::main!` wires
// this module's exports straight to the `proxy_on_*` symbols the Envoy
// proxy-wasm host calls directly. There is no WIT world, no cargo-component
// build, and no generated bindings — the `proxy-wasm` crate's traits
// (`RootContext`, `HttpContext`) are the entire ABI surface. Build with
// `cargo build --target wasm32-wasip1` (see build.sh), not `cargo component
// build`.
//
// Behavior (deliberately small and deterministic so a `curl` through Istio's
// sidecar proves the filter ran):
//   - on_http_request_headers: requests missing `x-cargo-tenant` get a local
//     403 JSON response and the filter chain stops there (Action::Pause).
//     Requests that carry the header continue down the chain.
//   - on_http_response_headers: every response that reaches this point gets
//     an `x-cargo-filtered-by: cargo-wasmfilter` header, so the allowed path
//     is provably different from a response the filter never saw.

use proxy_wasm::traits::{Context, HttpContext, RootContext};
use proxy_wasm::types::{Action, ContextType, LogLevel};

const TENANT_HEADER: &str = "x-cargo-tenant";
const FILTERED_BY_HEADER: &str = "x-cargo-filtered-by";
const FILTER_NAME: &str = "cargo-wasmfilter";
const DENY_BODY: &str = r#"{"error":"x-cargo-tenant header required"}"#;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_root_context(|_context_id| -> Box<dyn RootContext> {
        Box::new(CargoFilterRoot)
    });
}}

/// Root context: one per Envoy worker thread / VM. Its only job is to hand
/// out a fresh `CargoFilter` for each HTTP stream the proxy opens.
struct CargoFilterRoot;

impl Context for CargoFilterRoot {}

impl RootContext for CargoFilterRoot {
    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }

    fn create_http_context(&self, _context_id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(CargoFilter))
    }
}

/// One instance per HTTP stream. proxy-wasm calls these methods as Envoy's
/// filter chain reaches the corresponding phase for this stream.
struct CargoFilter;

impl Context for CargoFilter {}

impl HttpContext for CargoFilter {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        match self.get_http_request_header(TENANT_HEADER) {
            Some(tenant) => {
                proxy_wasm::hostcalls::log(
                    LogLevel::Info,
                    &format!("{FILTER_NAME}: allowing request for tenant '{tenant}'"),
                )
                .ok();
                Action::Continue
            }
            None => {
                proxy_wasm::hostcalls::log(
                    LogLevel::Warn,
                    &format!("{FILTER_NAME}: denying request missing '{TENANT_HEADER}'"),
                )
                .ok();
                self.send_http_response(
                    403,
                    vec![("content-type", "application/json")],
                    Some(DENY_BODY.as_bytes()),
                );
                Action::Pause
            }
        }
    }

    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        self.set_http_response_header(FILTERED_BY_HEADER, Some(FILTER_NAME));
        Action::Continue
    }
}
