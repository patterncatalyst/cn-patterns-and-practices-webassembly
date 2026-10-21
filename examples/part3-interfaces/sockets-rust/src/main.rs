// Capability-scoped outbound TCP client with reconnect + exponential backoff
// with jitter (ch13), as a WebAssembly command component.
//
// It attempts to connect to 127.0.0.1:<port> using the raw wasi:sockets TCP
// client dance (create-tcp-socket -> start-connect -> subscribe/block ->
// finish-connect). On failure it sleeps for an exponentially growing delay plus
// random jitter (wasi:clocks + wasi:random) and retries, up to a bounded number
// of attempts.
//
// Capability scoping: wasi:sockets connect works only when the host GRANTS
// network access (`wasmtime run -S inherit-network`). Without the grant the
// connect is denied at the capability boundary and every attempt fails with
// `access-denied` — the component cannot reach the network it was not given.
//
// Args: [port] [max_attempts] [base_delay_ms]  (all optional)
#[allow(warnings)]
mod bindings;

use bindings::wasi::clocks::monotonic_clock::subscribe_duration;
use bindings::wasi::random::random::get_random_u64;
use bindings::wasi::sockets::instance_network::instance_network;
use bindings::wasi::sockets::network::{
    ErrorCode, IpAddressFamily, IpSocketAddress, Ipv4SocketAddress,
};
use bindings::wasi::sockets::tcp_create_socket::create_tcp_socket;

const DEFAULT_PORT: u16 = 34567;
const DEFAULT_MAX_ATTEMPTS: u32 = 20;
const DEFAULT_BASE_MS: u64 = 100;

fn try_connect(port: u16) -> Result<(), ErrorCode> {
    let net = instance_network();
    let socket = create_tcp_socket(IpAddressFamily::Ipv4)?;
    let remote = IpSocketAddress::Ipv4(Ipv4SocketAddress {
        port,
        address: (127, 0, 0, 1),
    });
    socket.start_connect(&net, remote)?;
    // finish-connect is asynchronous: block on the socket's pollable until the
    // connect attempt resolves, then read the result.
    let pollable = socket.subscribe();
    pollable.block();
    let (_rx, _tx) = socket.finish_connect()?;
    // Streams drop here; for this demo a successful connect is the signal.
    Ok(())
}

fn sleep_ms(ms: u64) {
    let nanos = ms.saturating_mul(1_000_000);
    let pollable = subscribe_duration(nanos);
    pollable.block();
}

// Exponential backoff with jitter: delay = base * 2^min(attempt-1, 5), plus a
// random jitter of up to 50% of that delay. The cap keeps the window bounded.
fn backoff_ms(attempt: u32, base_ms: u64) -> u64 {
    let shift = (attempt - 1).min(5);
    let exp = base_ms.saturating_mul(1u64 << shift);
    let jitter = get_random_u64() % (exp / 2 + 1);
    exp + jitter
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let port: u16 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(DEFAULT_PORT);
    let max_attempts: u32 = args
        .get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_MAX_ATTEMPTS);
    let base_ms: u64 = args
        .get(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_BASE_MS);

    eprintln!("sockets-rust: connecting to 127.0.0.1:{port} (up to {max_attempts} attempts, base {base_ms}ms backoff)");

    for attempt in 1..=max_attempts {
        match try_connect(port) {
            Ok(()) => {
                println!("sockets-rust: connected to 127.0.0.1:{port} on attempt {attempt}");
                return;
            }
            Err(e) => {
                eprintln!("sockets-rust: attempt {attempt}/{max_attempts} failed: {e:?}");
                if e == ErrorCode::AccessDenied {
                    // No capability: retrying will not help. Fail fast and loud so
                    // the demo shows the capability boundary distinctly from a
                    // connection-refused (listener-down) retry.
                    eprintln!("sockets-rust: network access DENIED by the host capability boundary — grant it with `wasmtime run -S inherit-network`");
                    std::process::exit(2);
                }
                if attempt == max_attempts {
                    eprintln!("sockets-rust: giving up after {max_attempts} attempts");
                    std::process::exit(1);
                }
                let delay = backoff_ms(attempt, base_ms);
                eprintln!("sockets-rust: backing off {delay}ms before retry");
                sleep_ms(delay);
            }
        }
    }
}
