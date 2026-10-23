#!/usr/bin/env python3
"""Figure 21.1, Ch21: the shape-translation ADAPTER, two substrate expressions.

minikube (top band): compile-time `wac plug` composition. The Part 3 http-rust
front door, the cargo-adapter interposer, and the Part 2 cargo provider are
spliced into ONE app-adapted.wasm, run as a single Pod behind the containerd
wasmtime shim. `book-cargo` round-trips canonical -> legacy -> canonical inside
one in-process instance, so the exact cargo JSON comes back.

CRC (bottom band): runtime-link composition. The same three logical pieces run
as THREE SEPARATE wasmCloud components wired by wadm `link` traits over wRPC.
The round-trip still runs and is still lossless, but a valid tracking id now
returns the provider's own 404: the same per-invocation statelessness finding
Chapter 20 documents for the filter, because book-cargo and get-cargo land on
two different fresh instances across a runtime link.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 660

bands = [
    {"x": 20, "y": 40, "w": 1140, "h": 260,
     "label": "minikube: compile-time composition (wac plug): ONE Pod, round-trip in ONE instance",
     "fill": "#f1f5f9"},
    {"x": 20, "y": 340, "w": 1140, "h": 300,
     "label": "CRC: runtime-link composition (wadm links): THREE components, round-trip across links",
     "fill": "#f1f5f9"},
]

nodes = [
    # --- minikube band ---
    {"x": 60, "y": 90, "w": 230, "h": 70,
     "lines": ["Part 3 http-rust", "imports cargo, exports wasi:http"],
     "style": "box"},
    {"x": 330, "y": 90, "w": 250, "h": 70,
     "lines": ["cargo-adapter", "book-cargo: canonical -> legacy", "-> canonical (round-trip)"],
     "style": "accent"},
    {"x": 620, "y": 90, "w": 230, "h": 70,
     "lines": ["Part 2 cargo provider", "exports patterncatalyst:cargo/*"],
     "style": "box"},
    {"x": 890, "y": 90, "w": 230, "h": 70,
     "lines": ["app-adapted.wasm", "wac plug x2, ONE Pod"],
     "style": "user"},
    {"x": 60, "y": 200, "w": 790, "h": 70,
     "lines": ["origin_code=USNYC dest_code=DEHAM cargo_weight=1200.5 service_level=Economy",
               "-> re-inflated origin=USNYC destination=DEHAM weight_kg=1200.5 -> exact cargo JSON (200)"],
     "style": "ink"},

    # --- CRC band ---
    {"x": 60, "y": 390, "w": 220, "h": 70,
     "lines": ["cargo-adapted", "front door component"],
     "style": "box"},
    {"x": 330, "y": 390, "w": 220, "h": 70,
     "lines": ["cargo-adapter", "interposer component"],
     "style": "accent"},
    {"x": 600, "y": 390, "w": 220, "h": 70,
     "lines": ["cargo-provider-a", "fresh instance per call"],
     "style": "box"},
    {"x": 870, "y": 390, "w": 250, "h": 70,
     "lines": ["httpserver provider 0.27.0", "edge-TLS Route, CA-verified"],
     "style": "user"},
    {"x": 60, "y": 500, "w": 790, "h": 90,
     "lines": ["round-trip still runs (lossless); but book-cargo and get-cargo are TWO wRPC calls",
               "across TWO fresh provider instances: valid id -> provider's own 404, not 200",
               "(same per-invocation statelessness as Chapter 20's filter)"],
     "style": "ink"},
]

edges = [
    # minikube chain
    {"x1": 290, "y1": 125, "x2": 330, "y2": 125, "label": "wac plug"},
    {"x1": 580, "y1": 125, "x2": 620, "y2": 125, "label": "wac plug"},
    {"x1": 850, "y1": 125, "x2": 890, "y2": 125},
    {"x1": 455, "y1": 160, "x2": 455, "y2": 200, "dashed": True},

    # CRC chain (amber links)
    {"x1": 280, "y1": 425, "x2": 330, "y2": 425, "amber": True, "label": "link: booking"},
    {"x1": 550, "y1": 425, "x2": 600, "y2": 425, "amber": True, "label": "link: booking,handling"},
    {"x1": 820, "y1": 425, "x2": 870, "y2": 425, "amber": True, "label": "link: incoming-handler"},
    {"x1": 300, "y1": 460, "x2": 300, "y2": 500, "dashed": True},
]

notes = [
    {"x": 590, "y": 645, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Verified live 2026-10-21: minikube returns the exact cargo JSON; CRC's round-trip runs but hits the Chapter 20 state finding."},
]

gd.emit("21-adapter-shape-translation", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
