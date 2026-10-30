#!/usr/bin/env python3
"""Figure 8.1: the `wac plug` socket/plug model. A consumer component
(the socket: it IMPORTS the cargo interfaces) is plugged by a provider
component (the plug: it EXPORTS them) into one composed, self-contained
component. WASI imports are left untouched by wac; wasmtime's own WASI
implementation satisfies them at instantiation."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 980, 460

nodes = [
    {"x": 40, "y": 150, "w": 300, "h": 130,
     "lines": ["consumer-rust.wasm / consumer-go.wasm", "SOCKET: imports",
               "patterncatalyst:cargo/{types,booking,handling}",
               "exports wasi:cli/run"],
     "style": "user"},

    {"x": 640, "y": 150, "w": 300, "h": 130,
     "lines": ["rust/ or go/ provider component", "PLUG: exports",
               "patterncatalyst:cargo/{types,booking,handling}"],
     "style": "accent"},

    {"x": 330, "y": 20, "w": 320, "h": 70,
     "lines": ["wac plug --plug <provider> <consumer>", "-o composed.wasm"],
     "style": "ink"},

    {"x": 330, "y": 320, "w": 320, "h": 110,
     "lines": ["composed.wasm", "self-contained: wasmtime run composed.wasm",
               "no native host required"],
     "style": "box"},

    {"x": 700, "y": 320, "w": 240, "h": 110,
     "lines": ["wasi:cli, wasi:io, wasi:clocks, ...", "left as unresolved imports",
               "wasmtime satisfies any 0.2.x at instantiation"],
     "style": "ghost"},
]

edges = [
    {"x1": 190, "y1": 150, "x2": 420, "y2": 90, "label": "socket"},
    {"x1": 790, "y1": 150, "x2": 580, "y2": 90, "label": "plug"},
    {"x1": 490, "y1": 90, "x2": 490, "y2": 320, "amber": True, "label": "wac plug"},
    {"x1": 630, "y1": 375, "x2": 700, "y2": 375, "dashed": True},
]

notes = [
    {"x": 490, "y": 440, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Composition matches by WIT identifier (patterncatalyst:cargo@0.1.0/booking, ...), not by source language; any consumer plugs into any provider."},
]

gd.emit("08-wac-plug-socket-and-plug", W, H, nodes=nodes, edges=edges, notes=notes)
