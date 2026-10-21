// Reflection-free protobuf wire codec for the cargo messages (ch12, TinyGo).
//
// Why hand-written: TinyGo 0.43 COMPILES google.golang.org/protobuf but TRAPS at
// runtime — proto.Marshal reaches reflect.Type.MethodByName inside
// impl.MessageInfo.makeStructInfo, which TinyGo's partial reflect does not
// implement (see proto-go/README/notes). So the component cannot use the
// reflection-based library. This file encodes/decodes the proto3 wire format
// directly (varints, length-delimited strings/messages, fixed64 doubles) with no
// reflection, producing bytes that interoperate with the Rust prost side.
package main

import (
	"encoding/binary"
	"errors"
	"math"
)

// --- encoding ---

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func appendTag(b []byte, field int, wire int) []byte {
	return appendVarint(b, uint64(field)<<3|uint64(wire))
}

func appendString(b []byte, field int, s string) []byte {
	if s == "" {
		return b
	}
	b = appendTag(b, field, 2) // length-delimited
	b = appendVarint(b, uint64(len(s)))
	return append(b, s...)
}

func appendMessage(b []byte, field int, msg []byte) []byte {
	b = appendTag(b, field, 2)
	b = appendVarint(b, uint64(len(msg)))
	return append(b, msg...)
}

func appendDouble(b []byte, field int, f float64) []byte {
	if f == 0 {
		return b
	}
	b = appendTag(b, field, 1) // 64-bit
	var tmp [8]byte
	binary.LittleEndian.PutUint64(tmp[:], math.Float64bits(f))
	return append(b, tmp[:]...)
}

// --- decoding ---

func readVarint(b []byte, i int) (uint64, int, error) {
	var v uint64
	var shift uint
	for {
		if i >= len(b) {
			return 0, 0, errors.New("varint truncated")
		}
		c := b[i]
		i++
		v |= uint64(c&0x7f) << shift
		if c < 0x80 {
			return v, i, nil
		}
		shift += 7
		if shift >= 64 {
			return 0, 0, errors.New("varint overflow")
		}
	}
}

// decodeGetCargoRequest returns the tracking_id from a GetCargoRequest.
func decodeGetCargoRequest(b []byte) (string, error) {
	i := 0
	trackingID := ""
	for i < len(b) {
		tag, ni, err := readVarint(b, i)
		if err != nil {
			return "", err
		}
		i = ni
		field := int(tag >> 3)
		wire := int(tag & 0x7)
		switch {
		case field == 1 && wire == 2:
			n, ni, err := readVarint(b, i)
			if err != nil {
				return "", err
			}
			i = ni
			end := i + int(n)
			if end > len(b) {
				return "", errors.New("string truncated")
			}
			trackingID = string(b[i:end])
			i = end
		default:
			// Skip any unknown field so the decoder tolerates additions.
			ni, err := skipField(b, i, wire)
			if err != nil {
				return "", err
			}
			i = ni
		}
	}
	return trackingID, nil
}

func skipField(b []byte, i int, wire int) (int, error) {
	switch wire {
	case 0: // varint
		_, ni, err := readVarint(b, i)
		return ni, err
	case 1: // 64-bit
		if i+8 > len(b) {
			return 0, errors.New("fixed64 truncated")
		}
		return i + 8, nil
	case 2: // length-delimited
		n, ni, err := readVarint(b, i)
		if err != nil {
			return 0, err
		}
		end := ni + int(n)
		if end > len(b) {
			return 0, errors.New("length-delimited truncated")
		}
		return end, nil
	case 5: // 32-bit
		if i+4 > len(b) {
			return 0, errors.New("fixed32 truncated")
		}
		return i + 4, nil
	default:
		return 0, errors.New("unknown wire type")
	}
}

// --- message builders ---

type location struct{ unlocode, name, country string }
type money struct{ amount, currency string }

func encodeLocation(l location) []byte {
	var b []byte
	b = appendString(b, 1, l.unlocode)
	b = appendString(b, 2, l.name)
	b = appendString(b, 3, l.country)
	return b
}

func encodeMoney(m money) []byte {
	var b []byte
	b = appendString(b, 1, m.amount)
	b = appendString(b, 2, m.currency)
	return b
}

// encodeCargo builds a Cargo message (fields: tracking_id=1, origin=2,
// destination=3, weight_kg=4).
func encodeCargo(trackingID string, origin, destination location, weightKg float64) []byte {
	var b []byte
	b = appendString(b, 1, trackingID)
	b = appendMessage(b, 2, encodeLocation(origin))
	b = appendMessage(b, 3, encodeLocation(destination))
	b = appendDouble(b, 4, weightKg)
	return b
}

// encodeGetCargoResponse builds a GetCargoResponse (cargo=1, price=2, error=3).
func encodeGetCargoResponse(cargo []byte, price *money, errMsg string) []byte {
	var b []byte
	if cargo != nil {
		b = appendMessage(b, 1, cargo)
	}
	if price != nil {
		b = appendMessage(b, 2, encodeMoney(*price))
	}
	b = appendString(b, 3, errMsg)
	return b
}
