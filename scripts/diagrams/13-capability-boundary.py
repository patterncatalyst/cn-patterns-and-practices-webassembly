#!/usr/bin/env python3
"""Figure for Chapter 13 — Networking, Reconnect, and Resilience.

13-capability-boundary : the same sockets-rust component run twice under
                          wasmtime, once with no network grant (every connect
                          attempt is denied at the capability boundary, before
                          a single byte reaches the OS) and once with
                          `-S inherit-network` (the connect dance actually
                          reaches a real TCP socket). A bottom note ties this
                          back to Chapter 2's container contrast: a container
                          process starts with ambient network access by
                          default; a component starts with none.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

gd.emit(
    "13-capability-boundary", 1180, 640,
    bands=[
        {"x": 20, "y": 16, "w": 540, "h": 560, "label": "wasmtime run  (no grant)", "fill": "#f1f5f9"},
        {"x": 600, "y": 16, "w": 560, "h": 560, "label": "wasmtime run -S inherit-network  (granted)", "fill": "#fff3e0"},
    ],
    nodes=[
        {"x": 50, "y": 56, "w": 480, "h": 56, "lines": ["component: create-tcp-socket + start-connect"], "style": "box"},
        {"x": 50, "y": 128, "w": 480, "h": 56, "lines": ["wasi:sockets import resolves to NOTHING", "the host linked for this instance"], "style": "box"},
        {"x": 50, "y": 200, "w": 480, "h": 64, "lines": ["connect denied AT THE BOUNDARY —", "ErrorCode::AccessDenied, before any packet"], "style": "ink"},
        {"x": 50, "y": 284, "w": 480, "h": 56, "lines": ["component exits non-zero;", "retrying would not help"], "style": "box"},
        {"x": 50, "y": 400, "w": 480, "h": 72, "lines": ["no line to the OS socket layer at all —", "there is nothing to retry past"], "style": "ghost"},

        {"x": 630, "y": 56, "w": 500, "h": 56, "lines": ["component: create-tcp-socket + start-connect"], "style": "box"},
        {"x": 630, "y": 128, "w": 500, "h": 56, "lines": ["wasi:sockets import resolves to a REAL", "OS TCP socket the host granted"], "style": "box"},
        {"x": 630, "y": 200, "w": 500, "h": 64, "lines": ["connect REACHES 127.0.0.1:port —", "refused while no listener is bound yet"], "style": "ink"},
        {"x": 630, "y": 284, "w": 500, "h": 56, "lines": ["component backs off and retries", "(see Figure 13.2)"], "style": "box"},
        {"x": 630, "y": 400, "w": 500, "h": 72, "lines": ["once a listener appears, the SAME", "retry loop connects and returns"], "style": "box"},
    ],
    edges=[
        {"x1": 290, "y1": 112, "x2": 290, "y2": 128},
        {"x1": 290, "y1": 184, "x2": 290, "y2": 200},
        {"x1": 290, "y1": 264, "x2": 290, "y2": 284},
        {"x1": 290, "y1": 340, "x2": 290, "y2": 400, "dashed": True},

        {"x1": 880, "y1": 112, "x2": 880, "y2": 128},
        {"x1": 880, "y1": 184, "x2": 880, "y2": 200},
        {"x1": 880, "y1": 264, "x2": 880, "y2": 284},
        {"x1": 880, "y1": 340, "x2": 880, "y2": 400},
    ],
    notes=[
        {"x": 590, "y": 600, "text": "Contrast with Chapter 2: a container starts with the host's network stack by default and loses it only by subtraction (namespaces, egress policy).", "size": 12, "color": "#555555", "anchor": "middle"},
        {"x": 590, "y": 620, "text": "A component starts with none and gains exactly what -S inherit-network hands it — no grant, no socket, no exception.", "size": 12, "color": "#555555", "anchor": "middle"},
    ],
)
