#!/usr/bin/env python3
"""Figure 20.2, Ch20: why the SAME request shape returns 200 on minikube and
404 on CRC for a valid tracking id.

The Part 3 front door handles GET /cargo/CARGO-{ORIGIN}-{DEST} by calling
book-cargo (seed a booking) and then get-cargo (read it back): two calls, one
HTTP request. Under wac plug those two calls land in the SAME in-process
component instance, so the thread_local HashMap the provider seeded in call 1
is still there for call 2: 200 with the exact cargo JSON. Under a wasmCloud
runtime link, wasmCloud gives every invocation a fresh instance with reset
linear memory, so call 2 runs against an EMPTY HashMap: the provider's own
NotFound, surfaced as 404.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 520

bands = [
    {"x": 20, "y": 40, "w": 550, "h": 440, "label": "minikube: one instance, two calls, shared memory", "fill": "#f1f5f9"},
    {"x": 610, "y": 40, "w": 550, "h": 440, "label": "CRC: two instances, one call each, reset memory", "fill": "#f1f5f9"},
]

nodes = [
    # minikube side
    {"x": 60, "y": 90, "w": 470, "h": 60,
     "lines": ["GET /cargo/CARGO-USNYC-DEHAM  (ONE HTTP request)"],
     "style": "box"},
    {"x": 60, "y": 190, "w": 470, "h": 150,
     "lines": ["ONE provider component instance",
               "call 1: book-cargo  -> HashMap.insert(booking)",
               "call 2: get-cargo   -> HashMap.get(booking)  <- SAME map",
               "same linear memory for both calls"],
     "style": "user"},
    {"x": 60, "y": 380, "w": 470, "h": 70,
     "lines": ["200  exact cargo JSON", "tracking_id, origin, destination, weight_kg, price"],
     "style": "accent"},

    # CRC side
    {"x": 650, "y": 90, "w": 470, "h": 60,
     "lines": ["GET /cargo/CARGO-USNYC-DEHAM  (ONE HTTP request)"],
     "style": "box"},
    {"x": 650, "y": 190, "w": 470, "h": 70,
     "lines": ["wRPC call 1: book-cargo", "fresh provider instance A -> HashMap.insert(booking)"],
     "style": "ink"},
    {"x": 650, "y": 280, "w": 470, "h": 70,
     "lines": ["wRPC call 2: get-cargo", "fresh provider instance B -> HashMap is EMPTY"],
     "style": "ink"},
    {"x": 650, "y": 380, "w": 470, "h": 70,
     "lines": ["404  {\"error\":\"no cargo ...\"}", "the provider's own NotFound, not a crash"],
     "style": "accent"},
]

edges = [
    {"x1": 295, "y1": 150, "x2": 295, "y2": 190},
    {"x1": 295, "y1": 340, "x2": 295, "y2": 380},
    {"x1": 885, "y1": 150, "x2": 885, "y2": 190},
    {"x1": 885, "y1": 260, "x2": 885, "y2": 280, "amber": True, "label": "fresh instance"},
    {"x1": 885, "y1": 350, "x2": 885, "y2": 380},
]

notes = [
    {"x": 590, "y": 505, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Compile-time composition shares state; runtime links give independent lifecycle but not in-memory state."},
]

gd.emit("20-state-contrast", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
