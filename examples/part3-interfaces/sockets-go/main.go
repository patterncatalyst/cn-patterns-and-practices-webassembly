// TinyGo capability-scoped outbound TCP client with reconnect + exponential
// backoff with jitter (ch13, GATE D Go). REACTOR component: it EXPORTS
// `client.run-client`, driven by the native sockets-host (see that crate and
// wit/world.wit for why a reactor rather than a `wasmtime run` command).
//
// The raw wasi:sockets dance mirrors sockets-rust: create-tcp-socket ->
// start-connect -> subscribe/block -> finish-connect. Whether the connect is
// permitted is decided by the HOST's WASI network grant (inherit_network),
// mirroring `wasmtime run -S inherit-network`.
package main

import (
	clock "example.com/sockets-go/internal/sock/wasi/clocks/monotonic-clock"
	client "example.com/sockets-go/internal/sock/patterncatalyst/sockets-client-go/client"
	instancenetwork "example.com/sockets-go/internal/sock/wasi/sockets/instance-network"
	network "example.com/sockets-go/internal/sock/wasi/sockets/network"
	tcpcreate "example.com/sockets-go/internal/sock/wasi/sockets/tcp-create-socket"

	"go.bytecodealliance.org/cm"
)

func init() {
	client.Exports.RunClient = runClient
}

func main() {}

type result = cm.Result[string, uint32, string]

func okResult(attempt uint32) result {
	return cm.OK[result](attempt)
}

func errResult(msg string) result {
	return cm.Err[result](msg)
}

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

func sleepMs(ms uint64) {
	pollable := clock.SubscribeDuration(clock.Duration(ms * 1_000_000))
	pollable.Block()
}

// backoff = base * 2^min(attempt-1, 5) + jitter up to 50%, jitter from the
// monotonic clock's low bits (wasi:random is not imported — see sockets-rust for
// the direct wasi:random path; here the clock suffices and keeps imports minimal).
func backoffMs(attempt uint32, baseMs uint64) uint64 {
	shift := attempt - 1
	if shift > 5 {
		shift = 5
	}
	exp := baseMs << shift
	jitter := uint64(clock.Now()) % (exp/2 + 1)
	return exp + jitter
}

func runClient(port uint16, maxAttempts uint32, baseMs uint64) result {
	for attempt := uint32(1); attempt <= maxAttempts; attempt++ {
		ok, ec := tryConnect(port)
		if ok {
			return okResult(attempt)
		}
		if ec == network.ErrorCodeAccessDenied {
			return errResult("access-denied: network capability was not granted by the host")
		}
		if attempt == maxAttempts {
			return errResult("giving up after max attempts")
		}
		sleepMs(backoffMs(attempt, baseMs))
	}
	return errResult("unreachable")
}
