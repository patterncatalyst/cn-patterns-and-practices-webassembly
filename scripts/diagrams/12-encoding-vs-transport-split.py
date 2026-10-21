#!/usr/bin/env python3
"""Figure 12.3 — Ch12: Protobuf-the-encoding vs gRPC-the-transport.

The chapter's central split: Protobuf (varints, length-delimited fields,
fixed64 doubles) is pure computation and runs fine inside a component.
gRPC adds HTTP/2 framing, trailers, and bidirectional streaming on top of
that encoding — a transport layer no component exposes a server side of
today. Two different concerns, two different verdicts.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1080, 420

bands = [
    {"x": 20, "y": 16, "w": 500, "h": 384, "label": "PROTOBUF — the encoding", "fill": "#f1f5f9"},
    {"x": 560, "y": 16, "w": 500, "h": 384, "label": "gRPC — the transport", "fill": "#fff3e0"},
]

nodes = [
    {"x": 50, "y": 70, "w": 440, "h": 60,
     "lines": ["varints, length-delimited fields,", "fixed64 doubles"],
     "style": "box"},
    {"x": 50, "y": 150, "w": 440, "h": 60,
     "lines": ["pure computation — decode bytes,", "build a struct, encode bytes"],
     "style": "box"},
    {"x": 50, "y": 230, "w": 440, "h": 70,
     "lines": ["runs fully INSIDE the sandbox", "prost (Rust) or a reflection-free codec (TinyGo)"],
     "style": "ink"},
    {"x": 50, "y": 320, "w": 440, "h": 60,
     "lines": ["needs nothing the component model denies —", "no network, no server socket"],
     "style": "box"},

    {"x": 600, "y": 70, "w": 420, "h": 60,
     "lines": ["HTTP/2 framing, trailers,", "bidirectional streaming"],
     "style": "box"},
    {"x": 600, "y": 150, "w": 420, "h": 60,
     "lines": ["needs a listening server socket", "and an HTTP/2 stack"],
     "style": "box"},
    {"x": 600, "y": 230, "w": 420, "h": 70,
     "lines": ["no component HTTP/2 server surface today", "(wasi:http exports a request handler, not this)"],
     "style": "ink"},
    {"x": 600, "y": 320, "w": 420, "h": 60,
     "lines": ["terminated by a host-mediated bridge", "(tonic) in front of the component"],
     "style": "box"},
]

edges = [
    {"x1": 270, "y1": 130, "x2": 270, "y2": 150},
    {"x1": 270, "y1": 210, "x2": 270, "y2": 230},
    {"x1": 270, "y1": 300, "x2": 270, "y2": 320},

    {"x1": 810, "y1": 130, "x2": 810, "y2": 150},
    {"x1": 810, "y1": 210, "x2": 810, "y2": 230},
    {"x1": 810, "y1": 300, "x2": 810, "y2": 320},
]

notes = [
    {"x": 540, "y": 410, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Same proto/cargo.proto, two different verdicts: the message format runs in Wasm; the RPC transport does not, yet."},
]

gd.emit("12-encoding-vs-transport-split", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
