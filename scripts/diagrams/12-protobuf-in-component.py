#!/usr/bin/env python3
"""Figure 12.1: Protobuf runs server-side INSIDE a Wasm component.

Request bytes cross the host->component boundary as a plain `list<u8>`. Inside
the sandbox, a codec (prost in Rust, a reflection-free wire codec in TinyGo)
decodes the protobuf message, dispatches to the cargo domain over WIT, encodes
a protobuf response, and returns bytes. No gRPC transport is involved here;
this is Protobuf-the-serialization, which is pure computation and needs
nothing the sandbox denies it.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1080, 520

nodes = [
    {"x": 40, "y": 220, "w": 220, "h": 90,
     "lines": ["caller (host or test)", "GetCargoRequest bytes", "(prost-encoded, 19 bytes)"],
     "style": "box"},

    {"x": 330, "y": 80, "w": 420, "h": 360,
     "lines": ["codec.get-cargo(list<u8>) -> result<list<u8>, string>"],
     "style": "accent"},

    {"x": 360, "y": 140, "w": 360, "h": 60,
     "lines": ["decode: prost (Rust) / wire.go (TinyGo)", "GetCargoRequest bytes -> tracking_id"],
     "style": "box"},

    {"x": 360, "y": 220, "w": 360, "h": 60,
     "lines": ["dispatch over WIT", "booking.book-cargo / booking.get-cargo"],
     "style": "ink"},

    {"x": 360, "y": 300, "w": 360, "h": 60,
     "lines": ["encode: prost (Rust) / wire.go (TinyGo)", "Cargo + Money -> GetCargoResponse bytes"],
     "style": "box"},

    {"x": 830, "y": 220, "w": 210, "h": 90,
     "lines": ["caller decodes response", "91 bytes, byte-identical", "Rust prost <-> TinyGo wire codec"],
     "style": "box"},
]

edges = [
    {"x1": 260, "y1": 265, "x2": 360, "y2": 170, "label": "list<u8>"},
    {"x1": 540, "y1": 200, "x2": 540, "y2": 220},
    {"x1": 540, "y1": 280, "x2": 540, "y2": 300},
    {"x1": 690, "y1": 330, "x2": 830, "y2": 265, "label": "list<u8>", "amber": True},
]

notes = [
    {"x": 540, "y": 40, "size": 13, "color": "#1d1d1d", "anchor": "middle", "bold": True,
     "text": "INSIDE THE WASM SANDBOX: no network, no gRPC transport, just bytes in and bytes out"},
    {"x": 540, "y": 495, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Protobuf is varints, length-delimited fields, fixed64 doubles: pure computation, so it runs in a component with no transport capability at all."},
]

gd.emit("12-protobuf-in-component", W, H, nodes=nodes, edges=edges, notes=notes)
