#!/usr/bin/env python3
"""Figure 11.2: Ch11: the build/compose/serve pipeline for both language
front doors. `http-rust` builds with `cargo-component`; `http-go` builds with
the TinyGo wasip1-reactor + wasm-tools pipeline from Chapter 7. Either
artifact is `wac plug`-composed with the matching Part 2 provider (one source
of truth for the domain, never edited here), then served directly by
`wasmtime serve -S cli` with no native host in the loop."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1040, 480

nodes = [
    {"x": 30, "y": 30, "w": 320, "h": 100,
     "lines": ["http-rust/", "cargo component build --release",
               "-> cargo_http_rust.wasm"],
     "style": "user"},

    {"x": 400, "y": 30, "w": 320, "h": 100,
     "lines": ["http-go/", "bash build.sh (wit-bindgen-go + tinygo",
               "+ wasm-tools component new --adapt)",
               "-> cargo-http-go.wasm"],
     "style": "user"},

    {"x": 770, "y": 30, "w": 250, "h": 100,
     "lines": ["part2 provider", "cargo_rust.wasm / cargo-go.wasm",
               "(built from its own recipe, not edited here)"],
     "style": "accent"},

    {"x": 300, "y": 200, "w": 440, "h": 90,
     "lines": ["wac plug --plug <part2 provider> <http component>",
               "-o composed.wasm",
               "provider = --plug, http component = socket"],
     "style": "ink"},

    {"x": 300, "y": 350, "w": 440, "h": 100,
     "lines": ["wasmtime serve -S cli composed.wasm --addr 127.0.0.1:8080",
               "curl /cargo/CARGO-USNYC-DEHAM -> 200 JSON",
               "curl /cargo/NOPE -> 404 JSON"],
     "style": "box"},
]

edges = [
    {"x1": 190, "y1": 130, "x2": 450, "y2": 200, "label": "cargo_http_rust.wasm"},
    {"x1": 560, "y1": 130, "x2": 530, "y2": 200, "label": "cargo-http-go.wasm"},
    {"x1": 890, "y1": 130, "x2": 650, "y2": 200, "label": "--plug"},
    {"x1": 520, "y1": 290, "x2": 520, "y2": 350, "amber": True, "label": "composed.wasm"},
]

notes = [
    {"x": 520, "y": 455, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Two toolchains, one WIT world (cargo-http), one wac recipe, one serve command; Rust and Go produce byte-identical responses under wasmtime serve."},
]

gd.emit("11-build-compose-serve-pipeline", W, H, nodes=nodes, edges=edges, notes=notes)
