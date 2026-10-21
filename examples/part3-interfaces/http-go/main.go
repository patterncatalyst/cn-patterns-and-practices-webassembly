// TinyGo HTTP front door for the cargo domain (ch11, GATE B).
//
// Exports `wasi:http/incoming-handler` (a reactor export) and imports the
// `patterncatalyst:cargo` booking interface. Same routing and byte-identical
// JSON as http-rust, so the composed Go front door serves the same responses as
// the Rust one.
//
//   GET /cargo/CARGO-{ORIGIN}-{DEST} -> book-cargo (seed) + get-cargo -> 200 JSON
//   GET /cargo/{other}              -> get-cargo misses -> 404
//
// Built with the explicit TinyGo wasip1 reactor + wasm-tools embed + component
// new --adapt reactor pipeline (see build.sh): TinyGo 0.43's one-shot
// -target=wasip2 WIT embedding fails to reconcile wasi versions, same as the
// part2 providers.
package main

import (
	"strconv"
	"strings"

	booking "example.com/cargo-http-go/internal/http/patterncatalyst/cargo/booking"
	cargotypes "example.com/cargo-http-go/internal/http/patterncatalyst/cargo/types"
	incominghandler "example.com/cargo-http-go/internal/http/wasi/http/incoming-handler"
	httptypes "example.com/cargo-http-go/internal/http/wasi/http/types"

	"go.bytecodealliance.org/cm"
)

const (
	defaultWeightKg = 1200.5
	arrivalDeadline = "2026-12-01T00:00:00Z"
)

// Reactor export: wire up the handler during package init so it is live by the
// time `_initialize` returns and the host delivers the first request.
func init() {
	incominghandler.Exports.Handle = handle
}

func main() {}

func locationFor(unlocode string) cargotypes.Location {
	name, country := unlocode, ""
	switch unlocode {
	case "USNYC":
		name, country = "New York", "US"
	case "DEHAM":
		name, country = "Hamburg", "DE"
	}
	return cargotypes.Location{Unlocode: unlocode, Name: name, Country: country}
}

func jsonEscape(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	return strings.ReplaceAll(s, "\"", "\\\"")
}

func send(responseOut httptypes.ResponseOutparam, status uint16, body []byte) {
	headers := httptypes.NewFields()
	ct := httptypes.FieldValue(cm.ToList([]byte("application/json")))
	headers.Set("content-type", cm.ToList([]httptypes.FieldValue{ct}))

	resp := httptypes.NewOutgoingResponse(headers)
	resp.SetStatusCode(httptypes.StatusCode(status))

	// Obtain the body handle before handing the response to the outparam: the
	// set call consumes the OutgoingResponse. OK() is a pointer method, so the
	// cm.Result must live in a local first.
	bodyRes := resp.Body()
	outBody := *bodyRes.OK()
	ok := cm.OK[cm.Result[httptypes.ErrorCodeShape, httptypes.OutgoingResponse, httptypes.ErrorCode]](resp)
	httptypes.ResponseOutparamSet(responseOut, ok)

	streamRes := outBody.Write()
	stream := *streamRes.OK()
	stream.BlockingWriteAndFlush(cm.ToList(body))
	stream.ResourceDrop()
	httptypes.OutgoingBodyFinish(outBody, cm.None[httptypes.Trailers]())
}

func sendError(responseOut httptypes.ResponseOutparam, e cargotypes.CargoError) {
	// CargoError is a variant; its String() yields "case(msg)". Map the case to
	// an HTTP status; default to 400.
	msg := e.String()
	var status uint16 = 400
	if strings.HasPrefix(msg, "not-found") {
		status = 404
	} else if strings.HasPrefix(msg, "conflict") {
		status = 409
	}
	body := "{\"error\":\"" + jsonEscape(msg) + "\"}"
	send(responseOut, status, []byte(body))
}

func handle(request httptypes.IncomingRequest, responseOut httptypes.ResponseOutparam) {
	path := request.PathWithQuery().Value()
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}

	const prefix = "/cargo/"
	if !strings.HasPrefix(path, prefix) || len(path) == len(prefix) {
		send(responseOut, 404, []byte(`{"error":"not found","hint":"GET /cargo/{id}"}`))
		return
	}
	id := path[len(prefix):]

	parts := strings.SplitN(id, "-", 3)
	if len(parts) == 3 && parts[0] == "CARGO" {
		spec := cargotypes.RouteSpec{
			Origin:          locationFor(parts[1]),
			Destination:     locationFor(parts[2]),
			ArrivalDeadline: arrivalDeadline,
		}
		b, bErr, isErr := booking.BookCargo(spec, defaultWeightKg).Result()
		if isErr {
			sendError(responseOut, bErr)
			return
		}
		cargo, cErr, isErr := booking.GetCargo(b.CargoID).Result()
		if isErr {
			sendError(responseOut, cErr)
			return
		}
		body := "{\"tracking_id\":\"" + jsonEscape(cargo.TrackingID) +
			"\",\"origin\":\"" + jsonEscape(cargo.Origin.Unlocode) +
			"\",\"destination\":\"" + jsonEscape(cargo.Destination.Unlocode) +
			"\",\"weight_kg\":" + strconv.FormatFloat(cargo.WeightKg, 'g', -1, 64) +
			",\"price\":{\"amount\":\"" + jsonEscape(b.Price.Amount) +
			"\",\"currency\":\"" + jsonEscape(b.Price.Currency) + "\"}}"
		send(responseOut, 200, []byte(body))
		return
	}

	// Any other id is never booked, so get-cargo legitimately misses.
	cargo, cErr, isErr := booking.GetCargo(id).Result()
	if isErr {
		sendError(responseOut, cErr)
		return
	}
	send(responseOut, 200, []byte("{\"tracking_id\":\""+jsonEscape(cargo.TrackingID)+"\"}"))
}
