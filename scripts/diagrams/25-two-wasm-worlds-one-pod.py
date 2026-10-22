#!/usr/bin/env python3
"""Figure 25.1 — Ch25: two Wasm worlds, one Pod.

The cargo-http Pod runs two independently toolchained Wasm artifacts side by
side. The app container still runs the Part 5 substrate unchanged: a
Component-Model cargo-http component (wasi:http, built with cargo-component)
hosted by containerd-shim-wasmtime. Istio's sidecar injection adds a second,
unrelated Wasm world into the same Pod: an Envoy sidecar running a proxy-wasm
filter (cargo-wasmfilter), a core-module-ABI artifact built with the
proxy-wasm crate and plain cargo — never cargo-component — and loaded by a
WasmPlugin CR. A request enters through the sidecar, so the filter always
runs before the component sees the request. Same Pod, same container image
set, two different Wasm hosts and two different toolchains.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 700

bands = [
    {"x": 20, "y": 90, "w": 1140, "h": 440,
     "label": "Pod: cargo-http — two Wasm worlds, one network namespace",
     "fill": "#f1f5f9"},
]

nodes = [
    {"x": 480, "y": 20, "w": 220, "h": 50,
     "lines": ["client request", "GET /cargo/{id}"],
     "style": "sub"},

    {"x": 60, "y": 150, "w": 480, "h": 340,
     "lines": ["Envoy sidecar container", "injected by Istio"],
     "style": "box"},
    {"x": 640, "y": 150, "w": 480, "h": 340,
     "lines": ["cargo-http container", "Part 5 Wasm substrate, unchanged"],
     "style": "box"},

    {"x": 100, "y": 300, "w": 400, "h": 150,
     "lines": ["proxy-wasm filter: cargo-wasmfilter", "core-module ABI (proxy-wasm crate)",
               "loaded by WasmPlugin CR — runs FIRST"],
     "style": "accent"},
    {"x": 680, "y": 300, "w": 400, "h": 150,
     "lines": ["cargo-http component (wasi:http)", "Component Model ABI (cargo-component)",
               "hosted by containerd-shim-wasmtime"],
     "style": "user"},

    {"x": 80, "y": 555, "w": 1020, "h": 110,
     "lines": ["proxy-wasm core-module ABI (Envoy host) != Component Model (wasmtime host)",
               "different toolchain — proxy-wasm crate / plain cargo, not cargo-component",
               "different host runtime, same Pod"],
     "style": "ink"},
]

edges = [
    {"x1": 590, "y1": 70, "x2": 300, "y2": 150, "label": "enters via sidecar first"},
    {"x1": 500, "y1": 375, "x2": 680, "y2": 375, "label": "to cargo-http component"},
]

notes = [
    {"x": 590, "y": 685, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Istio injects the sidecar; the WasmPlugin-loaded filter runs before the request reaches the Component-Model app."},
]

gd.emit("25-two-wasm-worlds-one-pod", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
