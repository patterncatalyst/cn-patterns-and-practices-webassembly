#!/usr/bin/env python3
"""Figure 27.1: the wasi-nn inference path for one classification call.

One call through cargo-wasi-nn (the classify-cli component): decode and
preprocess the cargo fixture image entirely in the guest, cross the wasi:nn
import boundary with three host calls (load-by-name, init-execution-context,
compute), let the host's wasmtime-wasi-nn crate drive the OpenVINO backend
against the CPU, then return the output tensor to the guest for top-5
ranking. The component band and the host band are the two trust/execution
domains this figure contrasts: everything inside the top band is portable
Wasm; everything inside the bottom band is native code picked by the host,
not the component.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1500, 950

bands = [
    {"x": 20, "y": 100, "w": 1460, "h": 240,
     "label": "Wasm component: cargo-wasi-nn (classify-cli), sandboxed guest",
     "fill": "#f1f5f9"},
    {"x": 20, "y": 410, "w": 1460, "h": 240,
     "label": "Host process: wasmtime, --features wasi-nn",
     "fill": "#f1f5f9"},
]

nodes = [
    # input, above the component band
    {"x": 60, "y": 20, "w": 230, "h": 60,
     "lines": ["fixtures/cargo.jpg"], "style": "sub"},

    # component band: preprocessing and the wasi:nn call sites
    {"x": 60, "y": 150, "w": 250, "h": 160,
     "lines": ["cargo-wasi-nn", "decode → resize 224×224",
               "→ BGR/NCHW f32 tensor"],
     "style": "box"},
    {"x": 340, "y": 150, "w": 290, "h": 160,
     "lines": ["wasi:nn calls", "graph::load-by-name(\"mobilenet\")",
               "init-execution-context", "compute(named-tensor)"],
     "style": "accent"},

    # component band: post-inference, right side
    {"x": 1000, "y": 150, "w": 210, "h": 160,
     "lines": ["output tensor", "1001-way softmax"],
     "style": "box"},
    {"x": 1250, "y": 150, "w": 210, "h": 160,
     "lines": ["top-5 labels", "background index 0 skipped"],
     "style": "box"},

    # host band
    {"x": 340, "y": 460, "w": 220, "h": 160,
     "lines": ["wasmtime CLI", "--features wasi-nn"],
     "style": "user"},
    {"x": 600, "y": 460, "w": 230, "h": 160,
     "lines": ["wasmtime-wasi-nn", "crates/wasi-nn"],
     "style": "user"},
    {"x": 870, "y": 460, "w": 230, "h": 160,
     "lines": ["OpenVINO backend", "openvino crate v0.11.0"],
     "style": "accent"},
    {"x": 1140, "y": 460, "w": 170, "h": 160,
     "lines": ["CPU"],
     "style": "kernel"},

    {"x": 20, "y": 700, "w": 1460, "h": 100,
     "lines": [
         "mobilenet.xml + mobilenet.bin (OpenVINO IR) are loaded by name from a host-preloaded directory",
         "(-S nn-graph=openvino::<dir>); the model ships with the host, not inside the component.",
     ],
     "style": "ink"},
]

edges = [
    # image into the component
    {"x1": 175, "y1": 80, "x2": 175, "y2": 150},
    # within the component: preprocessing -> wasi:nn calls
    {"x1": 310, "y1": 230, "x2": 340, "y2": 230},
    # component -> host: the wasi:nn call crosses the sandbox boundary
    {"x1": 485, "y1": 310, "x2": 450, "y2": 460, "amber": True, "label": "wasi:nn call"},
    # host chain: wasmtime -> wasmtime-wasi-nn -> OpenVINO -> CPU
    {"x1": 560, "y1": 540, "x2": 600, "y2": 540},
    {"x1": 830, "y1": 540, "x2": 870, "y2": 540},
    {"x1": 1100, "y1": 540, "x2": 1140, "y2": 540, "label": "inference"},
    # host -> component: compute() returns the output tensor
    {"x1": 1225, "y1": 460, "x2": 1105, "y2": 310, "amber": True, "label": "output tensor"},
    # within the component: output tensor -> top-5 labels
    {"x1": 1210, "y1": 230, "x2": 1250, "y2": 230},
]

notes = [
    {"x": 750, "y": 930, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Only load-by-name, init-execution-context, and compute cross the wasi:nn boundary; decode, resize, and ranking stay in the guest."},
]

gd.emit("27-wasi-nn-inference-path", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
