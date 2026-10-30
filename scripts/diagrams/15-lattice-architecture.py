#!/usr/bin/env python3
"""Figure 15.1: the wasmCloud lattice for the cargo-http app.

One `wash up -d` process starts three things in the lattice: a NATS message
bus, a wasmcloud host (1.9.1), and wadm (0.21.1) reconciling the OAM manifest.
`wash app deploy wadm.yaml` starts two things ON that host: the httpserver
capability provider (0.27.0) and the cargo-http component (the SAME app.wasm
that also runs under wasmtime serve), and establishes the link between them
on wasi:http/incoming-handler, carrying the listen address as source config.
A curl against 127.0.0.1:8000 flows in through the provider's open socket,
across the link, into the component, and the cargo JSON comes back out.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 660

bands = [
    {"x": 20, "y": 60, "w": 1140, "h": 560, "label": "lattice: everything `wash up -d` starts", "fill": "#f1f5f9"},
    {"x": 330, "y": 150, "w": 790, "h": 440, "label": "wasmcloud host 1.9.1  (sparkling-sunset-0738)", "fill": "#fff3e0"},
]

nodes = [
    {"x": 470, "y": 20, "w": 240, "h": 50,
     "lines": ["curl http://127.0.0.1:8000/cargo/{id}"],
     "style": "box"},

    {"x": 60, "y": 110, "w": 220, "h": 70,
     "lines": ["NATS 2.11.3", "lattice message bus: wash, wadm,", "and the host all talk over it"],
     "style": "box"},

    {"x": 60, "y": 210, "w": 220, "h": 70,
     "lines": ["wadm 0.21.1", "reconciles wadm.yaml against", "actual lattice state (OAM)"],
     "style": "box"},

    {"x": 360, "y": 200, "w": 330, "h": 110,
     "lines": ["httpserver capability provider  0.27.0", "image: ghcr.io/wasmcloud/http-server:0.27.0",
               "opens 0.0.0.0:8000, translates inbound", "HTTP into wasi:http/incoming-handler calls"],
     "style": "accent"},

    {"x": 360, "y": 350, "w": 330, "h": 100,
     "lines": ["cargo-http component", "image: file://./app.wasm", "spreadscaler: instances: 1",
               "exports wasi:http/incoming-handler@0.2.8"],
     "style": "box"},

    {"x": 760, "y": 230, "w": 320, "h": 150,
     "lines": ["the LINK", "namespace: wasi  package: http", "interfaces: [incoming-handler]",
               "source_config: cargo-http-listen", "address: 0.0.0.0:8000"],
     "style": "ink"},

    {"x": 360, "y": 500, "w": 330, "h": 60,
     "lines": ["same app.wasm that runs", "under wasmtime serve, too"],
     "style": "ghost"},
]

edges = [
    {"x1": 590, "y1": 70, "x2": 525, "y2": 200, "label": "HTTP GET"},
    {"x1": 170, "y1": 180, "x2": 170, "y2": 210},
    {"x1": 280, "y1": 160, "x2": 500, "y2": 200, "dashed": True, "label": "deploys / reconciles"},
    {"x1": 525, "y1": 310, "x2": 525, "y2": 350},
    {"x1": 690, "y1": 255, "x2": 760, "y2": 280, "amber": True, "label": "link"},
    {"x1": 760, "y1": 340, "x2": 690, "y2": 400, "amber": True, "label": "wrpc:http/incoming-handler"},
    {"x1": 525, "y1": 450, "x2": 525, "y2": 500, "dashed": True},
]

notes = [
    {"x": 590, "y": 630, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "One `wash up -d` starts NATS + wadm + the host; `wash app deploy wadm.yaml` starts the provider + component and establishes the link."},
    {"x": 590, "y": 648, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "The provider owns the socket; the component only ever sees a WIT call. It never parses raw HTTP."},
]

gd.emit("15-lattice-architecture", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
