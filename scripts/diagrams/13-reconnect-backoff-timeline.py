#!/usr/bin/env python3
"""Figure for Chapter 13 — Networking, Reconnect, and Resilience.

13-reconnect-backoff-timeline : the real `wasmtime run -S inherit-network`
                                 transcript (sockets-rust, base 100ms) as a
                                 timeline — four connection-refused attempts
                                 against growing backoff-with-jitter delays,
                                 then a delayed listener binds and attempt 5
                                 connects.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# (attempt label, backoff-before-next label, node width — widening with the backoff)
attempts = [
    ("attempt 1", "connection-refused", "backing off 131ms", 150),
    ("attempt 2", "connection-refused", "backing off 269ms", 170),
    ("attempt 3", "connection-refused", "backing off 456ms", 190),
    ("attempt 4", "connection-refused", "backing off 1031ms", 220),
    ("attempt 5", "connects", None, 180),
]

nodes = []
edges = []
x = 30
y_box = 120
h_box = 90
gap = 36
for i, (label, outcome, backoff, w) in enumerate(attempts):
    style = "box" if backoff else "accent"
    lines = [label, outcome] if outcome != "connects" else [label, "connected to 127.0.0.1:PORT"]
    nodes.append({"x": x, "y": y_box, "w": w, "h": h_box, "lines": lines, "style": style})
    if backoff:
        bx = x + w + gap
        ghost_x, ghost_y, ghost_w = bx - gap + 6, y_box + h_box + 24, gap + 40
        nodes.append({"x": ghost_x, "y": ghost_y, "w": ghost_w, "h": 40,
                      "lines": [backoff], "style": "ghost"})
        edges.append({"x1": x + w, "y1": y_box + h_box / 2, "x2": bx, "y2": y_box + h_box / 2})
        edges.append({"x1": (x + w + bx) / 2, "y1": y_box + h_box / 2, "x2": ghost_x + ghost_w / 2,
                      "y2": ghost_y, "dashed": True})
    x = x + w + gap

listener_x = 30 + sum(w for *_, w in attempts[:4]) + gap * 4 - 40
nodes.append({"x": listener_x, "y": 20, "w": 260, "h": 56,
              "lines": ["delayed listener binds", "127.0.0.1:PORT ~1.5s in"], "style": "ink"})
edges.append({"x1": listener_x + 130, "y1": 76, "x2": listener_x + 130, "y2": y_box, "dashed": True})

width = x + 40
height = 320

gd.emit(
    "13-reconnect-backoff-timeline", width, height,
    bands=[
        {"x": 10, "y": 10, "w": width - 20, "h": height - 60, "label": "wasmtime run -S inherit-network  —  sockets-rust <wasm> PORT 20 100 (base 100ms)", "fill": "#f1f5f9"},
    ],
    nodes=nodes,
    edges=edges,
    notes=[
        {"x": width / 2, "y": height - 16, "text": "delay = base * 2^min(attempt-1, 5) + random jitter up to 50% (wasi:random) — jitter de-synchronizes retrying clients instead of making them all retry in lockstep.", "size": 12, "color": "#555555", "anchor": "middle"},
    ],
)
