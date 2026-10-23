#!/usr/bin/env python3
"""Figure 16.1, Ch16: ONE component artifact, app.wasm, built once by
examples/part4-runtimes/wasmcloud/build.sh (the Part 2 Rust cargo provider
wac-plugged under the Part 3 http-rust front door), fans into two independent
runtimes: wasmtime serve -S cli (ch14) on the left and the wasmCloud lattice's
httpserver provider, linked to the component via wadm (ch15), on the right.
Both serve the identical cargo JSON for a known tracking ID and the identical
404 for an unknown one. sha256sum agrees on both sides: same bytes, two
runtimes, no rebuild between them."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 660

bands = [
    {"x": 20, "y": 120, "w": 540, "h": 420, "label": "wasmtime serve -S cli  (ch14)", "fill": "#f1f5f9"},
    {"x": 620, "y": 120, "w": 540, "h": 420, "label": "wasmCloud lattice  (ch15)", "fill": "#fff3e0"},
]

nodes = [
    {"x": 340, "y": 16, "w": 500, "h": 70,
     "lines": ["app.wasm: built ONCE by build.sh", "sha256 eff7f5ee81db5f9f...4c9909b3"],
     "style": "accent"},

    {"x": 50, "y": 160, "w": 480, "h": 56,
     "lines": ["single process; wasmtime loads the", "component directly, no lattice"],
     "style": "box"},
    {"x": 50, "y": 232, "w": 480, "h": 56,
     "lines": ["GET /cargo/CARGO-USNYC-DEHAM"],
     "style": "box"},
    {"x": 50, "y": 304, "w": 480, "h": 72,
     "lines": ["200  tracking_id=CARGO-USNYC-DEHAM", "origin=USNYC destination=DEHAM weight=1200.5"],
     "style": "ink"},
    {"x": 50, "y": 392, "w": 480, "h": 56,
     "lines": ["GET /cargo/NOPE  ->  404"],
     "style": "box"},

    {"x": 650, "y": 160, "w": 480, "h": 56,
     "lines": ["httpserver provider  <--link-->  cargo-http", "component, wired by wadm.yaml"],
     "style": "box"},
    {"x": 650, "y": 232, "w": 480, "h": 56,
     "lines": ["GET /cargo/CARGO-USNYC-DEHAM"],
     "style": "box"},
    {"x": 650, "y": 304, "w": 480, "h": 72,
     "lines": ["200  tracking_id=CARGO-USNYC-DEHAM", "origin=USNYC destination=DEHAM weight=1200.5"],
     "style": "ink"},
    {"x": 650, "y": 392, "w": 480, "h": 56,
     "lines": ["GET /cargo/NOPE  ->  404"],
     "style": "box"},

    {"x": 240, "y": 500, "w": 700, "h": 80,
     "lines": ["IDENTICAL JSON on both sides, IDENTICAL sha256 on both sides",
               "one build, two runtimes, no rebuild in between"],
     "style": "ink"},
]

edges = [
    {"x1": 500, "y1": 86, "x2": 290, "y2": 120},
    {"x1": 680, "y1": 86, "x2": 890, "y2": 120},

    {"x1": 290, "y1": 216, "x2": 290, "y2": 232},
    {"x1": 290, "y1": 288, "x2": 290, "y2": 304},
    {"x1": 290, "y1": 376, "x2": 290, "y2": 392},

    {"x1": 890, "y1": 216, "x2": 890, "y2": 232},
    {"x1": 890, "y1": 288, "x2": 890, "y2": 304},
    {"x1": 890, "y1": 376, "x2": 890, "y2": 392},

    {"x1": 290, "y1": 448, "x2": 400, "y2": 500, "amber": True},
    {"x1": 890, "y1": 448, "x2": 780, "y2": 500, "amber": True},
]

notes = [
    {"x": 590, "y": 610, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Caveat: wasmCloud ignores EXPORTED component resources (our cargo-tracker), a WARN at start, harmless here"},
    {"x": 590, "y": 628, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "because the HTTP path only uses booking. wasmtime serve runs the component as-is, resource and all."},
]

gd.emit("16-same-bytes-two-runtimes", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
