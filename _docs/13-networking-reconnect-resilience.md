---
title: "Networking, Reconnect, and Resilience"
order: 13
part: "Interfaces: HTTP & gRPC"
description: "Outbound TCP from a component through wasi:sockets, the host grant that decides whether a connect can happen at all, and the reconnect loop with exponential backoff and jitter."
duration: "14 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the four `wasi:sockets` calls behind an outbound TCP connect (`create-tcp-socket`, `start-connect`, `subscribe` and `block`, `finish-connect`) and say why the connect is asynchronous.
- Explain why the same binary gets `access-denied` under plain `wasmtime run` and can reach a socket under `wasmtime run -S inherit-network`.
- Implement exponential backoff with jitter, `base * 2^min(attempt-1, 5)` plus up to 50% jitter from `wasi:random`, and say what jitter buys.
- Explain the two TinyGo `wasi:sockets` failures: a command-adapter trap during randomness seeding, and a reactor host whose `pollable.block()` never resolves the connect.
- Decide whether a dropped connection reconnects inside the component or is left to the platform's restart behavior.

## Why this matters

A component imports exactly the capabilities its code needs. `wasi:http`'s outgoing handler covers the common outbound call through a host-managed client. The case here is a component that holds the connection itself, retries it and decides when to give up. `sockets-rust` is a command component that opens a raw outbound TCP connection with `wasi:sockets` and does the whole connect dance itself: create a socket, start a connect, wait for it, read the result, and on failure sleep a growing, jittered delay before trying again.

`wasi:sockets` makes the capability boundary visible. The component imports the raw socket interfaces and the host decides, per invocation, whether those imports resolve to anything real. `wasmtime run` with no flags links `wasi:sockets` to nothing, and every connect fails with `access-denied` before a packet leaves the process. `wasmtime run -S inherit-network` links the same imports to the host's network stack, and the identical component reaches `127.0.0.1`. A container starts with the host's network and loses it by subtraction; a component starts with none and gains what the host hands it.

The second half is what a component does once it has the capability and the peer isn't there yet. `sockets-rust` retries with exponential backoff and jitter entirely inside the component, using `wasi:clocks` to sleep and `wasi:random` to jitter. Backoff with jitter is a standard resilience pattern (see *Cloud Native Design Patterns*, "Failure Modes"). What is specific here is where the loop lives: inside the sandboxed guest, governed by the capability the host granted, not in a sidecar or mesh the component can't see.

{% include excalidraw.html file="13-capability-boundary" alt="Two columns contrasting the same sockets-rust component under two wasmtime invocations. Left, 'wasmtime run (no grant)': the component calls create-tcp-socket and start-connect; the wasi:sockets import resolves to nothing the host linked in; the connect is denied at the capability boundary with ErrorCode::AccessDenied before any packet is sent; the component exits non-zero because retrying would not help; a dashed ghost box notes there is no line to the OS socket layer at all. Right, 'wasmtime run -S inherit-network (granted)': the same two calls resolve to a real OS TCP socket the host granted; the connect reaches 127.0.0.1:port and is refused while no listener is bound yet; the component backs off and retries; once a listener appears, the same retry loop connects and returns. A caption contrasts this with a container, which starts with the host's network stack by default and loses it only by subtraction, while a component starts with none and gains exactly what -S inherit-network hands it." caption="Figure 13.1: The identical sockets-rust binary, denied at the capability boundary with no grant, reaching a real socket once the host grants one." %}

## The raw `wasi:sockets` connect

`sockets-rust` is a `cargo-component` command component: a `[[bin]]` crate with `fn main`, for which `cargo-component` synthesizes the `wasi:cli/run` export, so it runs directly under `wasmtime run`. Its world states the whole capability surface:

```wit
package patterncatalyst:sockets-client@0.1.0;

/// A capability-scoped outbound TCP client, as a WebAssembly *command*
/// component. It imports the wasi:sockets, clocks, and random interfaces
/// it needs; because it is a cargo-component bin (fn main), cargo-component
/// synthesizes the wasi:cli/run export, so it runs directly under `wasmtime run`.
///
/// The component can only open a connection when the host GRANTS network access
/// (`wasmtime run -S inherit-network`). Without the grant the connect is denied
/// by the capability boundary, and that denial is the point of the demo.
world sockets-client {
    import wasi:sockets/instance-network@0.2.8;
    import wasi:sockets/network@0.2.8;
    import wasi:sockets/tcp@0.2.8;
    import wasi:sockets/tcp-create-socket@0.2.8;
    import wasi:clocks/monotonic-clock@0.2.8;
    import wasi:random/random@0.2.8;
}
```

`instance-network` hands back the one network handle the component can address, `tcp-create-socket` allocates a socket against it, `network` carries the shared error codes and address types, and `tcp` is the resource with the connect methods. `monotonic-clock` and `random` serve the backoff. As with the HTTP front door, `Cargo.toml` declares every vendored `wasi:*` package as a path dependency, because `cargo-component` doesn't scan `wit/deps`.

The connect is four calls:

```rust
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
```

`start-connect` only starts the connect and returns immediately, which is why `finish-connect` is separate. In between, WASI uses its standard pattern for anything that takes wall-clock time: `subscribe()` returns a `pollable`, and `.block()` parks execution until the operation resolves, success or failure. A connect to a port with nothing listening can settle in microseconds (an immediate RST) or take the OS connect timeout, and blocking on the pollable is the only way to wait for it.

Errors come back as a `wasi:sockets` `ErrorCode`. Two cases matter: `access-denied`, the capability denial, and `connection-refused`, the ordinary "nothing is listening yet" outcome a reconnect loop exists to survive.

## Denied before a packet moves

Run the component with no flags against a port nothing listens on:

```bash
wasmtime run sockets-client-rust.wasm 18077 3 50
```

The first attempt fails with `access-denied` and the process exits with code 2. There is no DNS lookup, no SYN and no OS connection attempt: `create_tcp_socket` succeeds, because allocating the resource isn't restricted, but `start_connect` returns `Err(ErrorCode::AccessDenied)` from inside wasmtime's `wasi:sockets` implementation. The refusal comes from the host's policy, not the kernel, a firewall or seccomp.

The loop treats `access-denied` as final:

```rust
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
```

Retrying a `connection-refused` makes sense because the peer may appear a moment later; retrying `access-denied` accomplishes nothing, because the host's grant doesn't change between attempts. The component exits with code 2 and prints the fix, `wasmtime run -S inherit-network`, instead of spending its whole retry budget on a verdict that was final at attempt one. A `connection-refused` on the last attempt exits with code 1.

Grant the capability and start a listener late:

```bash
( sleep 1.5; python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",34601));s.listen();s.accept()' ) &
wasmtime run -S inherit-network sockets-client-rust.wasm 34601 20 100
```

`-S inherit-network` grants the guest the host's network for this invocation. Nothing else changes: same WIT world, same `.wasm`, same `try_connect`.

## Reconnect with exponential backoff and jitter

With the capability granted, the normal failure is `connection-refused`: TCP's answer to a SYN at a port with nothing bound. The loop backs off between attempts instead of hammering the port. The two helpers it uses:

```rust
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
```

The delay is `base_ms * 2^min(attempt-1, 5)`: roughly `base_ms` on attempt 1, twice that on attempt 2, doubling until the shift caps at 5 (a 32x multiplier) so the window stays bounded however many attempts are allowed. The jitter is a random value from zero to half the exponential delay, added on top, from `wasi:random/random`, the only source of randomness a component has, since neither Core Wasm nor the Component Model gives a guest hardware entropy.

A pure exponential curve has every client that failed at the same moment retry at the same moment, again and again. That is the thundering herd: a recovering dependency hit by every client's retry at once instead of a staggered trickle. Jitter de-synchronizes the clients without any coordination between them, since each draws a different offset.

`sleep_ms` also comes from a capability. A component has no instruction for sleeping; `wasi:clocks/monotonic-clock`'s `subscribe_duration` returns a pollable that resolves after the duration, and `.block()` is the same idiom `try_connect` used.

One run with base 100ms and a listener that bound about 1.5 seconds after start:

```
sockets-rust: connecting to 127.0.0.1:18092 (up to 20 attempts, base 100ms backoff)
sockets-rust: attempt 1/20 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: backing off 131ms before retry
sockets-rust: attempt 2/20 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: backing off 269ms before retry
sockets-rust: attempt 3/20 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: backing off 456ms before retry
sockets-rust: attempt 4/20 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: backing off 1031ms before retry
sockets-rust: connected to 127.0.0.1:18092 on attempt 5
```

Each wait is roughly double the last, plus jitter, so not a clean power of two. The exact values change from run to run; the shape does not: a bounded, growing wait, with the loop still running when the dependency becomes reachable.

{% include excalidraw.html file="13-reconnect-backoff-timeline" alt="A timeline of the real wasmtime run -S inherit-network transcript against sockets-rust with base 100ms. Attempt 1 fails with connection-refused, backing off 131ms. Attempt 2 fails, backing off 269ms. Attempt 3 fails, backing off 456ms. Attempt 4 fails, backing off 1031ms, each backoff box roughly double the last. A delayed listener binds to 127.0.0.1:PORT about 1.5 seconds after the component starts, shown above the timeline with a dashed arrow down to where it starts accepting. Attempt 5 connects. A caption gives the formula: delay = base * 2^min(attempt-1, 5) + random jitter up to 50% from wasi:random, and notes jitter de-synchronizes retrying clients instead of letting them retry in lockstep." caption="Figure 13.2: Four connection-refused attempts with growing, jittered backoff, then a fifth attempt connects once the delayed listener binds." %}

The loop has no retry budget, circuit breaker or bulkhead. Those belong a layer up (see *Cloud Native Design Patterns*, "Communications" and "Failure Modes"), and a production component would add a breaker above this loop to stop retrying once a dependency has been down long enough that more attempts are wasted.

## The TinyGo gap

`sockets-go` builds the same client in TinyGo. On TinyGo 0.43 **the component builds and validates but has no clean runtime path.** `build.sh` runs `wit-bindgen-go generate`, `tinygo build -target=wasip1 -buildmode=c-shared`, `wasm-tools component embed` and `component new --adapt reactor`, and `wasm-tools validate` accepts the result. Two separate failures block a live connect:

| Shape | Failure |
| --- | --- |
| Command (`wasmtime run`) | Traps at `_start` with `assertion failed at adapter line 2404` in `random_get`. TinyGo's runtime seeds randomness (`arc4random`) during startup, and the wasip1 to wasip2 command adapter's `random_get` asserts when called that early. |
| Reactor, driven by a custom native host | The connect hangs. TinyGo's asyncify-based `pollable.block()` doesn't resolve the connect and timer pollables under a hand-rolled embedding, with either the sync or the async wasmtime-wasi linker. |

The first failure happens before `sockets-go`'s own code runs. That is why the world ships as a reactor exporting `client.run-client`, which a host calls explicitly, instead of relying on the synthesized `wasi:cli/run`:

```wit
package patterncatalyst:sockets-client-go@0.1.0;

/// TinyGo outbound TCP client with reconnect + backoff.
///
/// Shipped as a REACTOR exporting `client.run-client`, driven by the native
/// sockets-host. Why not a command (`wasmtime run`): TinyGo 0.43's runtime seeds
/// randomness with arc4random during `_start`, and the wasip1->wasip2 COMMAND
/// adapter's random_get traps when called that early ("assertion failed at
/// adapter line 2404"). A reactor uses `_initialize` + the reactor adapter (the
/// same path the part2 Go provider uses successfully), which avoids the trap.
/// The host grants or withholds network access, mirroring `-S inherit-network`.
interface client {
    /// Connect to 127.0.0.1:port, retrying with exponential backoff + jitter up
    /// to max-attempts. Returns the (1-based) attempt number that succeeded, or
    /// an error string ("access-denied" when the host withheld the network).
    run-client: func(port: u16, max-attempts: u32, base-ms: u64) -> result<u32, string>;
}

world sockets-client-go {
    import wasi:sockets/instance-network@0.2.12;
    import wasi:sockets/network@0.2.12;
    import wasi:sockets/tcp@0.2.12;
    import wasi:sockets/tcp-create-socket@0.2.12;
    import wasi:clocks/monotonic-clock@0.2.12;

    export client;
}
```

A reactor runs `_initialize` through the reactor adapter, the path the Go provider already uses, so the trap goes away. The second failure remains. The loop in `main.go` has the same structure as the Rust one, with jitter derived from the monotonic clock to keep the import set smaller, and `pollable.Block()` is where it stalls:

```go
func tryConnect(port uint16) (bool, network.ErrorCode) {
	net := instancenetwork.InstanceNetwork()
	socket, sErr, isErr := tcpcreate.CreateTCPSocket(network.IPAddressFamilyIPv4).Result()
	if isErr {
		return false, sErr
	}
	remote := network.IPSocketAddressIPv4(network.IPv4SocketAddress{
		Port:    port,
		Address: network.IPv4Address{127, 0, 0, 1},
	})
	if _, cErr, isErr := socket.StartConnect(net, remote).Result(); isErr {
		return false, cErr
	}
	pollable := socket.Subscribe()
	pollable.Block()
	if _, fErr, isErr := socket.FinishConnect().Result(); isErr {
		return false, fErr
	}
	return true, 0
}
```

The Rust client runs under `wasmtime run`'s own executor, which knows how to drive `wasi:sockets` pollables to resolution. The Go component would need that executor, and the command adapter it needs to get it traps first.

**Rust is the live sockets proof; the TinyGo component is a build-and-validate artifact.** Anyone hitting a similar asyncify and pollable mismatch should expect the fix in TinyGo's runtime or in a wasmtime-wasi linker change, not in host-side wiring.

## Reconnect loops and the lattice

Everything here is one component managing one socket in one process, with one host deciding the grant. wasmCloud's lattice distributes components across hosts, links them to providers over a network and tracks link health itself, re-establishing links on failure. That is link availability across a distributed runtime, handled one layer above this in-component loop, and the two don't conflict.

## When to reconnect inside the component

| Reconnect inside the component | Leave it to the platform |
| --- | --- |
| It holds a stateful connection it must keep alive across retries | A failed connect is equivalent to a failed instance |
| The backoff parameters belong to that specific dependency | A short-lived command exits non-zero on `connection-refused` and a restart policy runs it again |

> **Decision**
>
> Reconnect inside the component when it holds a stateful connection that must survive retries and the backoff belongs to that dependency; otherwise exit non-zero and let wasmtime, wasmCloud or a Kubernetes restart policy retry, since platform restart-with-backoff and in-component backoff are the same idea one layer apart. Use a small base delay (100ms here), a capped exponent (2^5 = 32x) and jitter up to 50%: a lower cap thrashes a struggling dependency, a higher one stalls a client, and no jitter brings back the thundering herd. Never retry `access-denied`: a missing grant doesn't change between attempts.

> **🤖 Explore with your agent**
>
> "In examples/part3-interfaces/sockets-rust, change `backoff_ms` in src/main.rs so the cap is `min(attempt-1, 3)` instead of 5 and the jitter is up to 25% of the delay, rebuild with `cargo component build --release`, and run the component under `wasmtime run -S inherit-network` against a listener that binds after 1.5 seconds. Apply the decision rule: say whether this dependency justifies an in-component loop or should exit non-zero for the platform to restart, and why `access-denied` must still exit immediately."
>
> Check: the exponential part of the `backing off` delays stops growing after attempt 4 and the run still ends with `connected to 127.0.0.1:<port>`; without `-S inherit-network` the first attempt prints `access-denied` and the exit code is 2.

## Build, run, observe

```bash
cd examples/part3-interfaces && ./verify.sh
```

The script builds `sockets-rust` and runs it under `wasmtime run` twice. With no grant, the connect fails with `access-denied`. With `-S inherit-network` and a listener that binds after a delay, the component reconnects with backoff and prints `connected to 127.0.0.1:<port>`. It then builds `sockets-go` and runs `wasm-tools validate` on it, with no live connect. Expect `PASS`.

Experiments:

- Run `sockets-rust` with `-S inherit-network` against a port with no listener and `3 50` as the last arguments. It prints three `connection-refused` failures with two backoffs between them, then `giving up after 3 attempts` and exits with code 1.
- Run it with no flag. The first attempt prints `access-denied` and exits with code 2, with no backoff line.

## For deeper coverage

- *Cloud Native Design Patterns*, "Failure Modes": retry with backoff and jitter, circuit breakers, bulkheads, and the thundering herd and retry storm failure modes.
- *Cloud Native Design Patterns*, "Communications": timeout, retry and circuit-breaker policy at the mesh layer, one level above this loop.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): `wasi:sockets` and the wider WASI networking surface in more depth.
- Shashank Jain, *WebAssembly for Cloud* (Apress): cross-language component tooling, including TinyGo's WASI gaps.
