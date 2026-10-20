// Go provider for the `cargo` world (contracts/wit, package
// patterncatalyst:cargo@0.1.0). wit-bindgen-go generated the bindings under
// internal/cargo from the shared contract (see build.sh); this file wires the
// three exported interfaces — types (data only), booking, and handling
// (including the cargo-tracker resource) — to simple in-memory state by
// assigning the generated Exports function variables in init().
//
// The same domain logic is implemented in ../rust against the same contract.
// The host in ../host runs BOTH components through an identical scenario and
// asserts equal domain results, so the constants and ID/status rules below
// MUST stay in lockstep with the Rust implementation.
package main

import (
	"fmt"

	"example.com/cargo-go/internal/cargo/patterncatalyst/cargo/booking"
	"example.com/cargo-go/internal/cargo/patterncatalyst/cargo/handling"
	"example.com/cargo-go/internal/cargo/patterncatalyst/cargo/types"
	"go.bytecodealliance.org/cm"
)

// Deterministic domain constants — MUST match the Rust implementation exactly.
const (
	voyageID      = "VOY-001"
	legLoadTime   = "2026-11-01T00:00:00Z"
	priceAmount   = "1500.00"
	priceCurrency = "USD"
)

func trackingIDFor(origin, destination types.Location) string {
	return fmt.Sprintf("CARGO-%s-%s", origin.Unlocode, destination.Unlocode)
}

func bookingIDFor(origin, destination types.Location) string {
	return fmt.Sprintf("BOOKING-%s-%s", origin.Unlocode, destination.Unlocode)
}

// Map the most recent handling event to the cargo's transport status. No
// events -> unspecified (the contract's explicit zero value). Shared with the
// Rust implementation.
func statusFromLastEvent(eventType types.HandlingEventType) types.TransportStatus {
	switch eventType {
	case types.HandlingEventTypeReceived:
		return types.TransportStatusPlanned
	case types.HandlingEventTypeLoaded:
		return types.TransportStatusInTransit
	case types.HandlingEventTypeUnloaded:
		return types.TransportStatusInTransit
	case types.HandlingEventTypeCustoms:
		return types.TransportStatusInTransit
	case types.HandlingEventTypeClaimed:
		return types.TransportStatusCompleted
	default:
		return types.TransportStatusUnspecified
	}
}

// ---------------------------------------------------------------------------
// In-memory state. A component instance keeps its linear memory across export
// calls within one host Store, so these maps survive the whole scenario. WASM
// is single-threaded here, so no locking is needed.
// ---------------------------------------------------------------------------
var (
	cargos   = map[string]types.Cargo{}
	bookings = map[string]types.Booking{}
	events   = map[string][]types.HandlingEvent{}
)

// cargo-tracker resource table: maps the resource rep the component model hands
// back on method calls to the tracker's own state (just its tracking id). The
// history and status are read live from the shared event state above.
type trackerState struct {
	trackingID string
}

var (
	trackers           = map[cm.Rep]*trackerState{}
	nextTracker cm.Rep = 1
)

type bookingResult = cm.Result[booking.BookingShape, types.Booking, types.CargoError]
type cargoResult = cm.Result[booking.CargoShape, types.Cargo, types.CargoError]
type itinerariesResult = cm.Result[booking.CargoErrorShape, cm.List[types.Itinerary], types.CargoError]
type registerResult = cm.Result[types.CargoError, struct{}, types.CargoError]
type eventsResult = cm.Result[handling.CargoErrorShape, cm.List[types.HandlingEvent], types.CargoError]

func init() {
	booking.Exports.BookCargo = func(spec types.RouteSpec, weightKg float64) bookingResult {
		if spec.Origin.Unlocode == "" || spec.Destination.Unlocode == "" {
			return cm.Err[bookingResult](types.CargoErrorInvalidLocation(
				"origin and destination must each have a UN/LOCODE"))
		}
		if weightKg <= 0 {
			return cm.Err[bookingResult](types.CargoErrorInvalidBooking(
				"weight-kg must be greater than zero"))
		}

		trackingID := trackingIDFor(spec.Origin, spec.Destination)
		bookingID := bookingIDFor(spec.Origin, spec.Destination)

		cargos[trackingID] = types.Cargo{
			TrackingID:  trackingID,
			Origin:      spec.Origin,
			Destination: spec.Destination,
			WeightKg:    weightKg,
		}
		b := types.Booking{
			BookingID: bookingID,
			CargoID:   trackingID,
			RouteSpec: spec,
			Price:     types.Money{Amount: priceAmount, Currency: priceCurrency},
			Status:    types.RoutingStatusNotRouted,
		}
		bookings[bookingID] = b
		return cm.OK[bookingResult](b)
	}

	booking.Exports.RequestPossibleRoutes = func(bookingID string) itinerariesResult {
		b, ok := bookings[bookingID]
		if !ok {
			return cm.Err[itinerariesResult](types.CargoErrorNotFound("no booking " + bookingID))
		}
		spec := b.RouteSpec
		itinerary := types.Itinerary{
			BookingID: bookingID,
			Legs: cm.ToList([]types.Leg{{
				VoyageID:       voyageID,
				LoadLocation:   spec.Origin,
				UnloadLocation: spec.Destination,
				LoadTime:       legLoadTime,
				UnloadTime:     spec.ArrivalDeadline,
				Status:         types.TransportStatusPlanned,
			}}),
		}
		return cm.OK[itinerariesResult](cm.ToList([]types.Itinerary{itinerary}))
	}

	booking.Exports.AssignRoute = func(bookingID string, itinerary types.Itinerary) bookingResult {
		if itinerary.Legs.Len() == 0 {
			return cm.Err[bookingResult](types.CargoErrorInvalidBooking(
				"itinerary must have at least one leg"))
		}
		b, ok := bookings[bookingID]
		if !ok {
			return cm.Err[bookingResult](types.CargoErrorNotFound("no booking " + bookingID))
		}
		b.Status = types.RoutingStatusRouted
		bookings[bookingID] = b
		return cm.OK[bookingResult](b)
	}

	booking.Exports.GetCargo = func(trackingID string) cargoResult {
		c, ok := cargos[trackingID]
		if !ok {
			return cm.Err[cargoResult](types.CargoErrorNotFound("no cargo " + trackingID))
		}
		return cm.OK[cargoResult](c)
	}

	handling.Exports.RegisterHandlingEvent = func(cargoID string, eventType types.HandlingEventType, location types.Location, voyageID string, recordedAt string) registerResult {
		if _, ok := cargos[cargoID]; !ok {
			return cm.Err[registerResult](types.CargoErrorNotFound("no cargo " + cargoID))
		}
		events[cargoID] = append(events[cargoID], types.HandlingEvent{
			CargoID:    cargoID,
			EventType:  eventType,
			Location:   location,
			VoyageID:   voyageID,
			RecordedAt: recordedAt,
		})
		return cm.OK[registerResult](struct{}{})
	}

	handling.Exports.ListHandlingEvents = func(cargoID string) eventsResult {
		return cm.OK[eventsResult](cm.ToList(events[cargoID]))
	}

	handling.Exports.CargoTracker.Constructor = func(trackingID string) handling.CargoTracker {
		rep := nextTracker
		nextTracker++
		trackers[rep] = &trackerState{trackingID: trackingID}
		return handling.CargoTrackerResourceNew(rep)
	}

	handling.Exports.CargoTracker.Destructor = func(self cm.Rep) {
		delete(trackers, self)
	}

	handling.Exports.CargoTracker.TrackingID = func(self cm.Rep) string {
		if t, ok := trackers[self]; ok {
			return t.trackingID
		}
		return ""
	}

	handling.Exports.CargoTracker.CurrentStatus = func(self cm.Rep) types.TransportStatus {
		t, ok := trackers[self]
		if !ok {
			return types.TransportStatusUnspecified
		}
		history := events[t.trackingID]
		if len(history) == 0 {
			return types.TransportStatusUnspecified
		}
		return statusFromLastEvent(history[len(history)-1].EventType)
	}

	handling.Exports.CargoTracker.History = func(self cm.Rep) cm.List[types.HandlingEvent] {
		t, ok := trackers[self]
		if !ok {
			return cm.ToList([]types.HandlingEvent{})
		}
		return cm.ToList(events[t.trackingID])
	}
}

// main is required by the Go toolchain for the module build, but a reactor
// component never runs it — the host instantiates the component and calls the
// exported functions directly.
func main() {}
