#!/usr/bin/env python3
"""Figure 11.1 — Ch11: one HTTP request's path through `wasmtime serve` into a
composed wasi-http component. `wasmtime serve -S cli` terminates the TCP
connection and HTTP framing itself; the composed component's two halves
(the http-rust/http-go adapter, wac-plugged to the Part 2 cargo provider)
handle exactly one request as a fresh instance, calling booking::book-cargo
then booking::get-cargo across the component boundary before the adapter
writes a JSON body back out."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1040, 470

nodes = [
    {"x": 20, "y": 180, "w": 220, "h": 120,
     "lines": ["curl client", "GET /cargo/CARGO-USNYC-DEHAM",
               "(or GET /cargo/NOPE)"],
     "style": "user"},

    {"x": 300, "y": 180, "w": 220, "h": 120,
     "lines": ["wasmtime serve -S cli", "composed.wasm",
               "--addr 127.0.0.1:8080"],
     "style": "ink"},

    # Outer frame for the composed component, drawn first so the two inner
    # boxes paint on top of it.
    {"x": 600, "y": 40, "w": 420, "h": 390,
     "lines": ["composed.wasm — wac plug output", "", ""],
     "style": "box"},

    {"x": 630, "y": 90, "w": 360, "h": 120,
     "lines": ["http-rust / http-go adapter", "exports wasi:http/incoming-handler",
               "imports booking + handling (resolved by wac plug)"],
     "style": "accent"},

    {"x": 630, "y": 250, "w": 360, "h": 140,
     "lines": ["part2 cargo provider (Rust or Go)", "exports booking + handling",
               "fresh instance per request — in-memory state",
               "book-cargo then get-cargo, one request"],
     "style": "user"},
]

edges = [
    {"x1": 240, "y1": 210, "x2": 300, "y2": 210, "label": "HTTP request"},
    {"x1": 520, "y1": 210, "x2": 630, "y2": 150, "label": "incoming-handler.handle"},
    {"x1": 810, "y1": 210, "x2": 810, "y2": 250, "amber": True,
     "label": "WIT call: book-cargo, get-cargo"},
    {"x1": 630, "y1": 170, "x2": 520, "y2": 260, "dashed": True,
     "label": "200 JSON / 404 error"},
    {"x1": 300, "y1": 260, "x2": 240, "y2": 260, "label": "HTTP response"},
]

notes = [
    {"x": 520, "y": 440, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Rust and Go front doors produce byte-identical JSON. An id that is never booked (GET /cargo/NOPE) legitimately misses get-cargo and maps to a 404."},
]

gd.emit("11-wasi-http-request-path", W, H, nodes=nodes, edges=edges, notes=notes)
