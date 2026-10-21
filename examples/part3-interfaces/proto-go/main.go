// TinyGo protobuf codec component for the cargo domain (ch12, reflection-free).
//
// Exports `codec.get-cargo(list<u8>) -> result<list<u8>, string>` and imports
// the cargo `booking` interface. It decodes a protobuf GetCargoRequest, dispatches
// over WIT, and encodes a protobuf GetCargoResponse — all inside the Wasm sandbox
// — using the hand-written reflection-free wire codec in wire.go (the standard
// reflection-based google.golang.org/protobuf traps at runtime under TinyGo 0.43).
package main

import (
	"strings"

	booking "example.com/proto-go/internal/proto/patterncatalyst/cargo/booking"
	cargotypes "example.com/proto-go/internal/proto/patterncatalyst/cargo/types"
	codec "example.com/proto-go/internal/proto/patterncatalyst/cargo-proto/codec"

	"go.bytecodealliance.org/cm"
)

const (
	defaultWeightKg = 1200.5
	arrivalDeadline = "2026-12-01T00:00:00Z"
)

func init() {
	codec.Exports.GetCargo = getCargo
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

func okResult(b []byte) cm.Result[cm.List[uint8], cm.List[uint8], string] {
	return cm.OK[cm.Result[cm.List[uint8], cm.List[uint8], string]](cm.ToList(b))
}

func errResult(msg string) cm.Result[cm.List[uint8], cm.List[uint8], string] {
	return cm.Err[cm.Result[cm.List[uint8], cm.List[uint8], string]](msg)
}

// encodeDomainError builds a GetCargoResponse carrying only the error string.
func encodeDomainError(msg string) []byte {
	return encodeGetCargoResponse(nil, nil, msg)
}

func getCargo(request cm.List[uint8]) cm.Result[cm.List[uint8], cm.List[uint8], string] {
	trackingID, err := decodeGetCargoRequest(request.Slice())
	if err != nil {
		return errResult("protobuf decode error: " + err.Error())
	}

	parts := strings.SplitN(trackingID, "-", 3)
	if !(len(parts) == 3 && parts[0] == "CARGO") {
		cargo, cErr, isErr := booking.GetCargo(trackingID).Result()
		if isErr {
			return okResult(encodeDomainError(cErr.String()))
		}
		return okResult(encodeCargoResponse(cargo, nil))
	}

	spec := cargotypes.RouteSpec{
		Origin:          locationFor(parts[1]),
		Destination:     locationFor(parts[2]),
		ArrivalDeadline: arrivalDeadline,
	}
	b, bErr, isErr := booking.BookCargo(spec, defaultWeightKg).Result()
	if isErr {
		return okResult(encodeDomainError(bErr.String()))
	}
	cargo, cErr, isErr := booking.GetCargo(b.CargoID).Result()
	if isErr {
		return okResult(encodeDomainError(cErr.String()))
	}
	price := &money{amount: b.Price.Amount, currency: b.Price.Currency}
	return okResult(encodeCargoResponse(cargo, price))
}

func encodeCargoResponse(cargo cargotypes.Cargo, price *money) []byte {
	cargoMsg := encodeCargo(
		cargo.TrackingID,
		location{cargo.Origin.Unlocode, cargo.Origin.Name, cargo.Origin.Country},
		location{cargo.Destination.Unlocode, cargo.Destination.Name, cargo.Destination.Country},
		cargo.WeightKg,
	)
	return encodeGetCargoResponse(cargoMsg, price, "")
}
