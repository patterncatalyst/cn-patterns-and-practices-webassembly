---
title: "Networking, Reconnect, and Resilience"
order: 13
part: "Interfaces: HTTP & gRPC"
description: "Outbound TCP from a sandboxed component through wasi:sockets, the capability grant that decides whether a connect attempt can happen at all, and the reconnect-with-backoff loop a component runs when it can."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the four calls `wasi:sockets` requires for an outbound TCP connect from inside a component (`create-tcp-socket`, `start-connect`, `subscribe`/`block`, `finish-connect`) and explain why the connect is asynchronous even though the calling code reads top to bottom.
- Explain capability-scoped networking for sockets specifically: why `examples/part3-interfaces/sockets-rust` gets `access-denied` on every attempt under plain `wasmtime run`, and why the identical binary, run under `wasmtime run -S inherit-network`, can reach a real socket instead.
- Contrast that default with a container's ambient network access, tying the contrast back to Chapter 2's capability model rather than re-deriving it.
- Implement exponential backoff with jitter from the actual formula in `sockets-rust/src/main.rs` (`base * 2^min(attempt-1, 5)`, plus random jitter up to 50% from `wasi:random`), and explain what jitter buys that a pure exponential curve does not.
- State, without hedging, the real TinyGo 0.43 runtime gap this example hit on `wasi:sockets`: `sockets-go` builds and validates as a component, but has no clean runtime path, and explain the two separate failure modes (a command-adapter trap during Go's own randomness seeding, and a reactor host whose `pollable.block()` never resolves the connect/timer pollables).
- Decide, for a given component, whether a dropped connection should reconnect inside the component or whether the host platform's own restart behavior makes an in-component retry loop redundant.

## Why this matters

Every component built so far in this site imports exactly the capabilities its own code needs and nothing more: Chapter 4 named this WASI's capability-granting model, Chapter 11 and Chapter 12 used `wasi:http`'s outgoing-handler to make outbound calls through a capability the host wires in. This chapter asks what happens when a component needs to be the one holding the connection open, retrying it, and deciding when to give up, rather than handing a single request to a host-managed client and waiting for a response. `examples/part3-interfaces/sockets-rust` is a Wasm **command** component that opens a raw outbound TCP connection with `wasi:sockets`, the lowest-level networking interface WASI Preview 2 defines, and it does the entire connect dance itself: create a socket, start a connect, wait for it to resolve, read the result, and on failure, sleep for a growing, jittered delay before trying again.

The reason this example exists is not "components can open sockets" on its own; `wasi:http`'s outgoing-handler already covers the common outbound-call case more conveniently. It's that `wasi:sockets` makes the capability boundary visible in a way `wasi:http` usually doesn't: the component imports the raw socket interfaces, and the host decides, per invocation, whether those imports resolve to anything real. `wasmtime run` with no flags links `wasi:sockets` to nothing; every connect attempt the component makes fails with `access-denied` before a single packet leaves the process, regardless of whether a listener exists anywhere to receive it. `wasmtime run -S inherit-network` links the same imports to the host's real network stack, and the identical component, unmodified, can now reach `127.0.0.1` and whatever it's listening to. Chapter 2 drew this contrast at the Core-spec level, between a container's ambient OS access and a Wasm guest's default of nothing; this chapter is where that contrast becomes a concrete, runnable demonstration against a real socket, not an abstract claim about imports.

The second half of this chapter is what a component does once it has that capability and the thing on the other end of the socket isn't there yet, or stops being there. `sockets-rust` retries with exponential backoff and jitter, entirely inside the component, using `wasi:clocks` to sleep and `wasi:random` to jitter: the same two capability-scoped primitives Chapter 4 introduced, now doing real work. This is not a new pattern invented for WebAssembly: Chapter 10 covered the two failure channels a call across the component boundary can produce, and backoff-with-jitter is a standard resilience pattern this site borrows rather than reinvents (see *Cloud Native Design Patterns*' "Failure Modes" chapter for the general catalog this example implements one corner of). What's specific to this chapter is where the retry loop lives: inside the sandboxed guest, governed by whatever capability the host decided to grant it, rather than in a sidecar or a service mesh the component has no visibility into.

{% include excalidraw.html file="13-capability-boundary" alt="Two columns contrasting the same sockets-rust component under two wasmtime invocations. Left, 'wasmtime run (no grant)': the component calls create-tcp-socket and start-connect; the wasi:sockets import resolves to nothing the host linked in; the connect is denied at the capability boundary with ErrorCode::AccessDenied before any packet is sent; the component exits non-zero because retrying would not help; a dashed ghost box notes there is no line to the OS socket layer at all. Right, 'wasmtime run -S inherit-network (granted)': the same two calls resolve to a real OS TCP socket the host granted; the connect reaches 127.0.0.1:port and is refused while no listener is bound yet; the component backs off and retries; once a listener appears, the same retry loop connects and returns. A caption contrasts this with Chapter 2: a container starts with the host's network stack by default and loses it only by subtraction, while a component starts with none and gains exactly what -S inherit-network hands it." caption="Figure 13.1: the identical sockets-rust binary, denied at the capability boundary with no grant, reaching a real socket once the host grants one." %}

## The raw wasi:sockets connect dance

`examples/part3-interfaces/sockets-rust` is a `cargo-component` **command** component: a `[[bin]]` crate with a `fn main`, which means `cargo-component` synthesizes the `wasi:cli/run` export automatically, and the build output runs directly under `wasmtime run` with no extra host code. Its `wit/world.wit` states the whole capability surface up front:

```wit
package patterncatalyst:sockets-client@0.1.0;

/// A capability-scoped outbound TCP client, as a WebAssembly *command*
/// component (ch13). It imports the wasi:sockets, clocks, and random interfaces
/// it needs; because it is a cargo-component bin (fn main), cargo-component
/// synthesizes the wasi:cli/run export, so it runs directly under `wasmtime run`.
///
/// The component can only open a connection when the host GRANTS network access
/// (`wasmtime run -S inherit-network`). Without the grant the connect is denied
/// by the capability boundary — that denial is the point of the demo.
world sockets-client {
    import wasi:sockets/instance-network@0.2.8;
    import wasi:sockets/network@0.2.8;
    import wasi:sockets/tcp@0.2.8;
    import wasi:sockets/tcp-create-socket@0.2.8;
    import wasi:clocks/monotonic-clock@0.2.8;
    import wasi:random/random@0.2.8;
}
```

Four `wasi:sockets` interfaces cover the whole raw-socket surface this component needs: `instance-network` hands back the one network handle this component can address, `tcp-create-socket` allocates a socket resource against it, `network` carries the shared error-code and address types, and `tcp` is the resource type with the connect/accept/send/receive methods. `wasi:clocks/monotonic-clock` and `wasi:random/random` round it out for the backoff sleep and its jitter, covered later in this chapter. `Cargo.toml` vendors each of these as a path dependency under `wit/deps/`, because `cargo-component` (unlike `wasm-tools`) does not auto-scan that directory; the gotcha is the same one `examples/part3-interfaces/README.md` calls out for the HTTP components in Chapter 11, and it bites here identically:

```toml
[package.metadata.component.target.dependencies]
"wasi:io" = { path = "wit/deps/io" }
"wasi:clocks" = { path = "wit/deps/clocks" }
"wasi:random" = { path = "wit/deps/random" }
"wasi:cli" = { path = "wit/deps/cli" }
"wasi:filesystem" = { path = "wit/deps/filesystem" }
"wasi:sockets" = { path = "wit/deps/sockets" }
"wasi:http" = { path = "wit/deps/http" }
```

The connect itself, in `src/main.rs`'s `try_connect`, is four calls, and the second one is the one worth slowing down on:

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

`start-connect` does not connect; it only *starts* the connect and returns immediately, which is why `wasi:sockets` separates it from `finish-connect`. The pattern in between is the one WASI Preview 2 uses everywhere an operation can take real wall-clock time to settle: the socket resource exposes `subscribe()`, which returns a `pollable`, and the caller calls `.block()` on that pollable to park the current execution until the underlying operation resolves, success or failure, before calling `finish-connect` to read the actual result. This is the same subscribe/block shape Chapter 9's debugging chapter and Chapter 11's HTTP chapter both touch in passing; here the whole connect depends on it, because a TCP connect to a port with nothing listening on it can take anywhere from microseconds (an immediate RST) to the OS's own connect timeout, and the component has no other way to wait for that outcome than blocking on the pollable the host handed back.

Error codes resolved through `finish-connect` (and, as this chapter's capability discussion depends on, through `start-connect` itself when the capability isn't granted) come back as a `wasi:sockets` `ErrorCode` variant. Two of its cases do all the work in this example: `access-denied`, the capability-boundary denial covered next, and `connection-refused`, the ordinary "nothing is listening on that port yet" outcome a reconnect loop exists to survive.

## Capability-scoped networking: denied before a packet moves

Run the built component with no flags, against a port nothing is listening on:

```bash
wasmtime run target/wasm32-wasip1/release/sockets-client-rust.wasm 18077 3 50
```

The real captured output:

```
sockets-rust: connecting to 127.0.0.1:18077 (up to 3 attempts, base 50ms backoff)
sockets-rust: attempt 1/3 failed: ErrorCode { code: 1, name: "access-denied", message: "Access denied.\n\n            POSIX equivalent: EACCES, EPERM" }
sockets-rust: network access DENIED by the host capability boundary — grant it with `wasmtime run -S inherit-network`
```

and the process exits non-zero. Notice what did *not* happen: there was no DNS lookup, no SYN packet, no OS-level connection attempt of any kind, because `start_connect` returned `Err(ErrorCode::AccessDenied)` directly. This is the same shape of denial Chapter 4 described for `wasi:filesystem` (a component with no preopened directory capability cannot construct a path into one, because nothing resolved that import), applied to sockets instead: `wasmtime run`'s default `wasi:sockets` implementation links zero network capability into the instance, so `instance_network()` returns a handle, `create_tcp_socket` succeeds (allocating the socket resource is itself not restricted), but the moment the code tries to use that socket to actually reach the network, the host's own policy (not the OS, not a firewall, not a seccomp filter) refuses it. The denial happens inside wasmtime's `wasi:sockets` host implementation, before the request ever reaches a kernel socket call.

`sockets-rust/src/main.rs` treats `access-denied` as a distinct, unrecoverable case rather than something the retry loop should ever attempt to ride out:

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

The comment states the reasoning directly: a missing capability is structurally different from a listener that hasn't started yet, and the two should never be handled by the same backoff loop. Retrying a `connection-refused` makes sense, because the thing on the other end might show up a moment later; retrying an `access-denied` accomplishes nothing, because the host's grant decision does not change between one `wasmtime run` process and the next invocation of the same binary. The component fails fast and names the fix in its own stderr output rather than burning twenty attempts proving the same denial twenty times.

Grant the capability and point the same component at a port that has a listener (even one that starts late):

```bash
( sleep 1.5; python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",34601));s.listen();s.accept()' ) &
wasmtime run -S inherit-network target/wasm32-wasip1/release/sockets-client-rust.wasm 34601 20 100
```

`-S inherit-network` is wasmtime's CLI flag for granting the guest the host's real network access for this invocation; it is the one line standing between "every attempt fails identically" and "the retry loop actually has something to reach." No other part of the component changes. The same WIT world, the same compiled `.wasm`, the same `try_connect` function: only the host's grant decision is different, which is the whole point this example exists to make concrete rather than asserted.

## Reconnect with exponential backoff and jitter

Once the capability is granted, the normal failure mode is `connection-refused`: TCP's own answer when a SYN arrives at a port with nothing bound to it yet. `sockets-rust`'s retry loop treats this as expected and recoverable, backing off between attempts rather than hammering the port in a tight loop:

```rust
fn main() {
    // ...parse port, max_attempts, base_ms from argv...
    for attempt in 1..=max_attempts {
        match try_connect(port) {
            Ok(()) => {
                println!("sockets-rust: connected to 127.0.0.1:{port} on attempt {attempt}");
                return;
            }
            Err(e) => {
                eprintln!("sockets-rust: attempt {attempt}/{max_attempts} failed: {e:?}");
                if e == ErrorCode::AccessDenied {
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
```

The backoff calculation itself is small enough to read in full, and every line of it maps onto a named idea from the broader resilience literature:

```rust
// Exponential backoff with jitter: delay = base * 2^min(attempt-1, 5), plus a
// random jitter of up to 50% of that delay. The cap keeps the window bounded.
fn backoff_ms(attempt: u32, base_ms: u64) -> u64 {
    let shift = (attempt - 1).min(5);
    let exp = base_ms.saturating_mul(1u64 << shift);
    let jitter = get_random_u64() % (exp / 2 + 1);
    exp + jitter
}
```

`base_ms * 2^min(attempt-1, 5)` is the exponential part: attempt 1 waits roughly `base_ms`, attempt 2 roughly `2 * base_ms`, attempt 3 roughly `4 * base_ms`, doubling each time, until the shift hits its cap at `5` (a `32x` multiplier) so the window stops growing without bound no matter how many attempts a caller allows. `get_random_u64() % (exp / 2 + 1)` is the jitter: a random value from zero up to half the exponential delay, added on top, so the actual wait for a given attempt is never exactly the same number twice. `get_random_u64` comes from `wasi:random/random`, the same capability-scoped primitive Chapter 4 named as the standard source of randomness a component has no other way to obtain, since nothing in the Wasm Core spec or the Component Model gives a guest access to hardware entropy on its own.

Jitter matters here for a reason that has nothing to do with this one component and everything to do with what happens when many instances of it exist at once. A pure exponential backoff with no randomness has every client that failed at the same moment (because the same listener went down, say) retry at the same moment again, and again, each retry a synchronized wave instead of a spread: that's the thundering-herd failure mode *Cloud Native Design Patterns*' "Failure Modes" chapter catalogs directly, where a recovering dependency gets hit by every client's retry at once instead of a staggered trickle it can actually absorb. Adding jitter de-synchronizes the clients from each other without requiring any of them to coordinate: each one's `get_random_u64()` call produces a different offset, so the same population of clients that would have retried in lockstep spreads its retries across a window instead.

`sleep_ms` is the other capability this loop depends on, again sourced from a capability-scoped WASI interface rather than anything the Wasm Core spec provides on its own:

```rust
fn sleep_ms(ms: u64) {
    let nanos = ms.saturating_mul(1_000_000);
    let pollable = subscribe_duration(nanos);
    pollable.block();
}
```

`wasi:clocks/monotonic-clock`'s `subscribe_duration` returns a `pollable` that resolves after the given duration, and blocking on it is the same subscribe/block idiom `try_connect` used to wait for the connect to settle. A component has no instruction for "sleep"; like every other capability this site has covered since Chapter 4, sleeping for a duration is something the host grants through an import, not an ambient ability every program starts with.

A real transcript, captured against the recipe above (`sockets-rust`, base 100ms, a listener that binds roughly 1.5 seconds after the component starts):

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

Four refusals, each backoff roughly double the last (131, 269, 456, 1031ms: the doubling plus jitter, not a clean power of two, which is expected), and by the time attempt 5 fires the delayed listener has bound and the connect finally succeeds. Run the same recipe again and the exact millisecond values change (jitter is random by construction), but the shape doesn't: a bounded, growing wait between attempts, the loop still running at the moment the dependency actually becomes reachable.

{% include excalidraw.html file="13-reconnect-backoff-timeline" alt="A timeline of the real wasmtime run -S inherit-network transcript against sockets-rust with base 100ms. Attempt 1 fails with connection-refused, backing off 131ms. Attempt 2 fails, backing off 269ms. Attempt 3 fails, backing off 456ms. Attempt 4 fails, backing off 1031ms, each backoff box roughly double the last. A delayed listener binds to 127.0.0.1:PORT about 1.5 seconds after the component starts, shown above the timeline with a dashed arrow down to where it starts accepting. Attempt 5 connects. A caption gives the formula: delay = base * 2^min(attempt-1, 5) + random jitter up to 50% from wasi:random, and notes jitter de-synchronizes retrying clients instead of letting them retry in lockstep." caption="Figure 13.2: four connection-refused attempts with growing, jittered backoff, then a fifth attempt connects once the delayed listener binds." %}

This example doesn't reimplement retry-budget caps, circuit breakers, or bulkheading, and it shouldn't: those are the next layer up in the same resilience toolkit, covered in depth in *Cloud Native Design Patterns*' "Communications" and "Failure Modes" chapters, and this component's job is to demonstrate the one primitive (backoff with jitter, running inside a capability-scoped sandbox) cleanly rather than build a general-purpose resilience library inside a teaching example. A production component built on this pattern would likely add a circuit breaker above this loop to stop retrying entirely once a dependency has been down long enough that further attempts are just wasted capability, exactly as that chapter describes.

## The TinyGo gap

`examples/part3-interfaces/sockets-go` is TinyGo's attempt at the identical client, and the state it's in is this: **the component builds and validates, but it has no clean runtime path on TinyGo 0.43.** `sockets-go/build.sh` runs cleanly end to end: `wit-bindgen-go generate`, `tinygo build -target=wasip1 -buildmode=c-shared`, `wasm-tools component embed`, `wasm-tools component new --adapt reactor`, then `wasm-tools validate` passes on the output. The artifact is a real, spec-valid component. It just cannot be driven to a successful connect in this example's test harness, for two separate reasons depending on how it's shaped, both documented in `examples/part3-interfaces/README.md`'s gotcha list:

> **TinyGo 0.43 `wasi:sockets`: no clean runtime path (documented gap).** The `sockets-go` component builds and validates, but:
> - As a **command** (`wasmtime run`), it traps at `_start` with `assertion failed at adapter line 2404` in `random_get`: TinyGo's runtime seeds randomness (`arc4random`) during startup, and the wasip1→wasip2 **command** adapter's `random_get` asserts when invoked that early.
> - As a **reactor** driven by a custom native host, the connect dance hangs: TinyGo's asyncify-based `pollable.block()` does not resolve the `wasi:sockets` connect/timer pollables under a hand-rolled embedding (tried both the sync and the async wasmtime-wasi linker). The Rust client works because it runs under the `wasmtime run` CLI's own executor.

These are two distinct failures, not one problem described two ways. The command-adapter trap happens before `sockets-go`'s own code runs at all: TinyGo's Go runtime calls into `arc4random` as part of its own startup sequence, regardless of whether the program needs randomness yet, and the wasip1-to-wasip2 command adapter's `random_get` implementation has an internal assertion that fires when it's invoked that early in the instance's life. That's why `sockets-go`'s `wit/world.wit` ships it as a **reactor** instead, exporting a `client.run-client` function a host calls explicitly rather than relying on the synthesized `wasi:cli/run` a command gets:

```wit
/// Shipped as a REACTOR exporting `client.run-client`, driven by the native
/// sockets-host. Why not a command (`wasmtime run`): TinyGo 0.43's runtime seeds
/// randomness with arc4random during `_start`, and the wasip1->wasip2 COMMAND
/// adapter's random_get traps when called that early ("assertion failed at
/// adapter line 2404"). A reactor uses `_initialize` + the reactor adapter (the
/// same path the part2 Go provider uses successfully), which avoids the trap.
world sockets-client-go {
    import wasi:sockets/instance-network@0.2.12;
    import wasi:sockets/network@0.2.12;
    import wasi:sockets/tcp@0.2.12;
    import wasi:sockets/tcp-create-socket@0.2.12;
    import wasi:clocks/monotonic-clock@0.2.12;

    export client;
}
```

Switching to a reactor sidesteps the trap (the reactor adapter runs `_initialize` instead of the command adapter's `_start`, and the part2 Go provider already proves this same adapter path works for a component with no sockets involved at all), but it runs into the second, independent failure: a hand-rolled native host driving this reactor through `wasmtime-wasi`'s linker finds that TinyGo's asyncify-based implementation of `pollable.block()` never resolves the connect and timer pollables `sockets-go`'s own connect loop depends on. The loop in `main.go` is structurally identical to the Rust version (`create-tcp-socket`, `start-connect`, `subscribe`/`block`, `finish-connect`, the same shape `backoff_ms` and `sleep_ms` the Rust side uses), with jitter derived from the monotonic clock instead of `wasi:random` to keep the import set smaller:

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

but `pollable.Block()` is where the reactor's execution stalls under a hand-rolled host, tried against both wasmtime-wasi's sync and async linkers, with neither resolving the pollable. The Rust client has no equivalent problem because it runs under `wasmtime run`'s own built-in CLI executor, which already knows how to drive `wasi:sockets` pollables to resolution; `sockets-go` would need that same executor, and a command adapter it cannot currently use without hitting the `random_get` assertion first.

So the summary is the one the README already gives: **Rust is the live sockets proof in this example; the TinyGo sockets component is kept as a build-and-validate artifact**, not a live one. This is not a verdict on TinyGo's `wasi:sockets` support in general: it's one combination of TinyGo 0.43, the reactor adapter, and a hand-rolled wasmtime-wasi host that doesn't resolve the connect pollable yet, next to one combination (TinyGo 0.43, the command adapter) that traps on an unrelated startup assertion before the sockets code runs at all. `examples/part3-interfaces/verify.sh`'s GATE D exercises both facts directly: the Rust build is driven through the full deny-then-reconnect sequence and asserted, while the Go build is only compiled and `wasm-tools validate`d:

```bash
echo
echo "=== GATE D (ch13): wasi-sockets reconnect (Rust) ==="
( cd "$SCRIPT_DIR/sockets-rust" && cargo component build --release )
SOCKETS_RUST="$(find "$SCRIPT_DIR/sockets-rust/target" -name sockets-client-rust.wasm -not -path '*/deps/*' | head -1)"
assert_file "$SOCKETS_RUST" "sockets-rust component"

# D.1 — capability withheld: no network grant -> access denied, non-zero exit.
DENY_OUT="$(wasmtime run "$SOCKETS_RUST" 18090 2 50 2>&1 || true)"
assert_contains "access-denied" "$DENY_OUT" "sockets-rust without grant is denied"

# D.2 — capability granted + listener appears after a delay -> reconnect succeeds.
SOCK_PORT=18091
( sleep 1.5; python3 -I -c 'import socket;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",'"$SOCK_PORT"'));s.listen();c,_=s.accept();c.close();s.close()' ) &
LISTENER_PID=$!
register_cleanup "kill $LISTENER_PID 2>/dev/null"
CONNECT_OUT="$(wasmtime run -S inherit-network "$SOCKETS_RUST" $SOCK_PORT 20 100 2>&1)"
wait "$LISTENER_PID" 2>/dev/null || true
assert_contains "connected to 127.0.0.1:$SOCK_PORT" "$CONNECT_OUT" "sockets-rust reconnects after backoff"

echo
echo "=== GATE D (ch13): wasi-sockets (TinyGo) builds + validates (runtime gap documented) ==="
bash "$SCRIPT_DIR/sockets-go/build.sh"
assert_file "$SCRIPT_DIR/sockets-go/sockets-client-go.wasm" "sockets-go component (build+validate only; see README)"
```

Nothing in that script papers over the gap: the Go gate exists, it builds a real component, and it never claims to reconnect anything. A reader hitting a similar asyncify/pollable mismatch in their own TinyGo `wasi:sockets` work should expect that the fix lives in TinyGo's own runtime or in a wasmtime-wasi linker change, not in anything this example's host-side wiring could paper over; the two projects named in "For deeper coverage" below are the places to track that work as it lands.

## Reconnect loops and the lattice: a forward reference, not a chapter

One more boundary worth drawing before the decision this chapter ends on: everything here is a single component managing a single socket, in a single process, with a single host deciding its capability grant. Part 4 covers wasmCloud's lattice, where components are distributed across hosts, linked to providers over a network of their own, and the platform itself tracks link health and re-establishes links on failure as a lattice-level concern. That's a different resilience question (link availability across a distributed runtime) answered at a different layer (the lattice's own supervision), not something this chapter teaches or this example builds toward. Chapter 15 and Chapter 16 pick wasmCloud resilience up properly, once the lattice itself has been introduced; nothing about `sockets-rust`'s in-component retry loop needs to be unlearned or contradicted to get there; it is simply one layer below where wasmCloud's own reconnect behavior operates.

## Build, run, observe

```bash
cd examples/part3-interfaces && ./verify.sh
```

`verify.sh` builds the Rust `sockets-rust` command component and asserts two things under `wasmtime run`: with no capability grant, the connect attempt fails with `access-denied`; with `-S inherit-network` granted and a listener that binds after a delay, the component reconnects with backoff and reports `connected to 127.0.0.1:<port>`. It then builds the TinyGo `sockets-go` component and validates it with `wasm-tools validate`, without asserting a live connect, consistent with the TinyGo runtime gap this chapter documents. Expect `PASS` once every assertion holds; see `examples/part3-interfaces/README.md` for the full walkthrough.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reconnect inside a component when the component itself is the thing holding a stateful connection it needs to keep alive across the retry (as <code>sockets-rust</code> does here) and the backoff parameters are a property of that specific dependency, not of the platform running the component. Let the host platform's own restart behavior handle the retry instead when a failed connection attempt is equivalent to a failed instance: a short-lived command component that exits non-zero on <code>connection-refused</code> and relies on wasmtime, wasmCloud, or a Kubernetes restart policy to simply run it again is often simpler and no less correct, because the platform's restart-with-backoff and this chapter's in-component backoff are the same idea implemented one layer apart. Default to a small base delay (100ms in this example) with a capped exponential ceiling (<code>2^5 = 32x</code> here) and jitter of up to 50% of the computed delay: a smaller cap thrashes a struggling dependency, a larger one leaves a reader-facing client visibly stalled, and skipping jitter entirely reintroduces the thundering-herd failure this pattern exists to avoid. Never retry an <code>access-denied</code>: a missing capability grant does not change between attempts, and a component that treats it the same as <code>connection-refused</code> burns its entire retry budget proving a denial that was already final on attempt one.</p></div>

## For deeper coverage

- *Cloud Native Design Patterns*, "Failure Modes" chapter: the full catalog of retry-with-backoff-and-jitter, circuit breakers, bulkheads, and the thundering-herd and retry-storm failure modes this chapter's jitter exists to avoid.
- *Cloud Native Design Patterns*, "Communications" chapter: timeout, retry, and circuit-breaker policy at the service-mesh layer, one level above where this chapter's in-component retry loop operates.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): `wasi:sockets` and the broader WASI networking surface covered in more implementation depth than this chapter's model-level treatment.
- Shashank Jain, *WebAssembly for Cloud* (Apress): cross-language component tooling and the operational realities of running polyglot components, including TinyGo's WASI gaps this chapter's TinyGo gap section names directly.
- Chapter 2, "The Execution Model": the capability-based security model (no ambient authority, authority only through resolved imports) this chapter's `access-denied` demonstration makes concrete against a real socket.
- Chapter 4, "WASI Preview 2": the capability-granting model in general, and `wasi:clocks` and `wasi:random` specifically, both used directly by this chapter's backoff loop.
- Chapter 10, "Error and Exception Handling": the two failure channels a call across the component boundary can produce; this chapter's `ErrorCode` values are the recoverable channel in practice.
- Chapter 15, "wasmCloud" and Chapter 16, "wasmtime and wasmCloud Together": where link-level resilience across a distributed lattice is covered properly, one layer above this chapter's single-process retry loop.
