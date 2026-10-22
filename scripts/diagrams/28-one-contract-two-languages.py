#!/usr/bin/env python3
"""Figure 28.2 — Ch28: the thread map. One WIT contract, two language builds,
one set of shared deploy targets the final project assembles.

contracts/wit (patterncatalyst:cargo) is implemented twice — once by the Part
2 Rust provider, once by the Part 2 Go provider — and each is plugged into
its Part 3 HTTP component (http-rust, http-go/TinyGo) with wac plug to
produce cargo-rust.wasm and cargo-go.wasm. Both composed components then feed
the same four deploy targets built in earlier parts: the containerd shim
(Part 5), the Istio gateway filter (Part 6, Ch25), the shim-to-otel-lgtm OTel
pipeline (Ch24), and the wasmCloud operator on CRC (Ch19).
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1400, 1020

bands = [
    {"x": 20, "y": 620, "w": 1360, "h": 240,
     "label": "Shared deploy targets — where the final project assembles",
     "fill": "#f1f5f9"},
]

nodes = [
    {"x": 520, "y": 20, "w": 360, "h": 90,
     "lines": ["contracts/wit", "patterncatalyst:cargo", "the one contract"],
     "style": "accent"},

    # Rust column
    {"x": 100, "y": 150, "w": 400, "h": 80,
     "lines": ["Part 2 — Rust cargo provider", "implements contracts/wit"],
     "style": "box"},
    {"x": 100, "y": 270, "w": 400, "h": 80,
     "lines": ["Part 3 — http-rust component", "wasi:http/incoming-handler"],
     "style": "box"},
    {"x": 100, "y": 390, "w": 400, "h": 60,
     "lines": ["wac plug --plug provider http-rust"],
     "style": "ink"},
    {"x": 100, "y": 490, "w": 400, "h": 80,
     "lines": ["cargo-rust.wasm", "composed, self-contained"],
     "style": "accent"},

    # Go column
    {"x": 900, "y": 150, "w": 400, "h": 80,
     "lines": ["Part 2 — Go cargo provider", "implements contracts/wit"],
     "style": "box"},
    {"x": 900, "y": 270, "w": 400, "h": 80,
     "lines": ["Part 3 — http-go component (TinyGo)", "wasi:http/incoming-handler"],
     "style": "box"},
    {"x": 900, "y": 390, "w": 400, "h": 60,
     "lines": ["wac plug --plug provider http-go"],
     "style": "ink"},
    {"x": 900, "y": 490, "w": 400, "h": 80,
     "lines": ["cargo-go.wasm", "composed, self-contained"],
     "style": "accent"},

    {"x": 55, "y": 670, "w": 310, "h": 110,
     "lines": ["containerd-shim-wasmtime", "Part 5 — RuntimeClass: wasmtime"],
     "style": "box"},
    {"x": 385, "y": 670, "w": 310, "h": 110,
     "lines": ["Istio gateway filter", "Part 6, Ch25 — proxy-wasm"],
     "style": "box"},
    {"x": 715, "y": 670, "w": 310, "h": 110,
     "lines": ["shim OTel → otel-lgtm", "Ch24 — Tempo traces"],
     "style": "box"},
    {"x": 1045, "y": 670, "w": 310, "h": 110,
     "lines": ["wasmCloud operator", "Ch19 — CRC"],
     "style": "box"},

    {"x": 20, "y": 890, "w": 1360, "h": 70,
     "lines": ["One WIT contract; every part of the book plugs into it."],
     "style": "ink"},
]

edges = [
    {"x1": 600, "y1": 110, "x2": 300, "y2": 150, "label": "implements"},
    {"x1": 800, "y1": 110, "x2": 1100, "y2": 150, "label": "implements"},

    {"x1": 300, "y1": 230, "x2": 300, "y2": 270},
    {"x1": 300, "y1": 350, "x2": 300, "y2": 390},
    {"x1": 300, "y1": 450, "x2": 300, "y2": 490},

    {"x1": 1100, "y1": 230, "x2": 1100, "y2": 270},
    {"x1": 1100, "y1": 350, "x2": 1100, "y2": 390},
    {"x1": 1100, "y1": 450, "x2": 1100, "y2": 490},

    {"x1": 300, "y1": 570, "x2": 300, "y2": 620, "amber": True, "label": "feeds"},
    {"x1": 1100, "y1": 570, "x2": 1100, "y2": 620, "amber": True, "label": "feeds"},
]

notes = [
    {"x": 700, "y": 1010, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Two languages, four targets, one contract — nothing here is new infrastructure, only assembly."},
]

gd.emit("28-one-contract-two-languages", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
