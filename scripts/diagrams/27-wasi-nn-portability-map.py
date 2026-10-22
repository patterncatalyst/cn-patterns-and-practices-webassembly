#!/usr/bin/env python3
"""Figure 27.2 — Ch27: one wasi:nn API, swappable backends.

The same cargo-wasi-nn component sits above the model-agnostic wasi:nn API;
the host wires that API to whichever inference backend it has installed —
OpenVINO (this chapter), ONNX Runtime, PyTorch, or WinML — without the
component's WIT imports or its compiled bytes changing. The right-hand band
contrasts the alternative most teams reach for instead: calling a separate
model server over HTTP, which adds a network hop, a second deployment, and
request/response serialization on every call, and ties the component to
whatever backend that server happens to run.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1500, 950

bands = [
    {"x": 20, "y": 90, "w": 980, "h": 680,
     "label": "wasi:nn — one API, swappable backends",
     "fill": "#f1f5f9"},
    {"x": 1020, "y": 90, "w": 460, "h": 680,
     "label": "Alternative — external model server over HTTP",
     "fill": "#f1f5f9"},
]

nodes = [
    # main flow: component -> wasi:nn API -> backends
    {"x": 250, "y": 140, "w": 500, "h": 80,
     "lines": ["cargo-wasi-nn component", "unchanged across backends"],
     "style": "box"},
    {"x": 300, "y": 300, "w": 400, "h": 90,
     "lines": ["wasi:nn API", "load-by-name · init-execution-context · compute"],
     "style": "accent"},

    {"x": 60, "y": 500, "w": 200, "h": 140,
     "lines": ["OpenVINO", "this chapter"], "style": "accent"},
    {"x": 280, "y": 500, "w": 200, "h": 140,
     "lines": ["ONNX Runtime"], "style": "user"},
    {"x": 500, "y": 500, "w": 200, "h": 140,
     "lines": ["PyTorch"], "style": "user"},
    {"x": 720, "y": 500, "w": 200, "h": 140,
     "lines": ["WinML"], "style": "user"},

    # alternative: HTTP to an external model server
    {"x": 1060, "y": 170, "w": 380, "h": 90,
     "lines": ["Wasm component", "+ HTTP client + serialization"],
     "style": "ghost"},
    {"x": 1100, "y": 330, "w": 300, "h": 70,
     "lines": ["network hop", "serialize request / response"],
     "style": "ghost"},
    {"x": 1080, "y": 460, "w": 340, "h": 100,
     "lines": ["external model server", "backend fixed in server, separate deploy"],
     "style": "ghost"},

    {"x": 20, "y": 800, "w": 1460, "h": 90,
     "lines": [
         "One import surface; the host chooses the backend — the component does not change.",
         "The HTTP alternative adds a network hop, a separate deployment, and serialization on every call.",
     ],
     "style": "ink"},
]

edges = [
    {"x1": 500, "y1": 220, "x2": 500, "y2": 300},
    {"x1": 500, "y1": 390, "x2": 160, "y2": 500},
    {"x1": 500, "y1": 390, "x2": 380, "y2": 500},
    {"x1": 500, "y1": 390, "x2": 600, "y2": 500},
    {"x1": 500, "y1": 390, "x2": 820, "y2": 500},

    {"x1": 1250, "y1": 260, "x2": 1250, "y2": 330},
    {"x1": 1250, "y1": 400, "x2": 1250, "y2": 460},

    {"x1": 750, "y1": 180, "x2": 1060, "y2": 215, "dashed": True, "label": "vs"},
]

notes = [
    {"x": 750, "y": 930, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "The four backends are interchangeable from the component's side — only the host's wasi:nn wiring picks one."},
]

gd.emit("27-wasi-nn-portability-map", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
