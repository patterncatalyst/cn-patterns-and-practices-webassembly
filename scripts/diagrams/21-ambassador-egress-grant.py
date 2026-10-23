#!/usr/bin/env python3
"""Figure 21.2, Ch21: the AMBASSADOR's outbound call is reached only through a
GRANT, never a default; shown on both clusters in the way each can actually
express it.

CRC (top band): the ambassador's defining property runs live. The front door's
outbound call to the cargo provider crosses a runtime-granted wadm `link`.
WITH the link, the outbound hop lands (the provider's own 404 proves the wRPC
call completed). WITHOUT it (the nogrant negative control), the front door's
cargo import is unsatisfiable, the operator-created Service gets no endpoints,
and the edge Route fails fast with a 5xx. 404-vs-5xx is the capability grant,
made visible.

minikube (bottom band): the raw containerd shim exposes no outbound-network
knob, so the ambassador cannot run as a cluster workload there at all. The
minikube evidence is a LOCAL `wasmtime run` smoke against the reused
sockets-rust command component (Chapter 13): denied outbound with no grant,
a growing jittered backoff against a dead port with the grant, and a
first-attempt connect against a live listener with the grant.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 680

bands = [
    {"x": 20, "y": 40, "w": 1140, "h": 300,
     "label": "CRC: runtime-granted lattice link: egress is a grant (cluster-live)",
     "fill": "#f1f5f9"},
    {"x": 20, "y": 360, "w": 1140, "h": 300,
     "label": "minikube: LOCAL wasmtime smoke only (shim has no outbound-network knob)",
     "fill": "#f1f5f9"},
]

nodes = [
    # --- CRC band: granted path ---
    {"x": 60, "y": 90, "w": 230, "h": 60,
     "lines": ["cargo-ambassador", "front door component"],
     "style": "box"},
    {"x": 360, "y": 90, "w": 230, "h": 60,
     "lines": ["cargo-provider-am", "component"],
     "style": "box"},
    {"x": 660, "y": 90, "w": 300, "h": 60,
     "lines": ["GET /cargo/NOPE -> 404", "provider's own NotFound: outbound reached"],
     "style": "accent"},

    # --- CRC band: nogrant negative control ---
    {"x": 60, "y": 200, "w": 230, "h": 60,
     "lines": ["cargo-ambassador-nogrant", "cargo import unlinked"],
     "style": "ghost"},
    {"x": 360, "y": 200, "w": 230, "h": 60,
     "lines": ["cargo-provider-amn", "component (unreachable)"],
     "style": "ghost"},
    {"x": 660, "y": 200, "w": 300, "h": 60,
     "lines": ["Service: no endpoints", "Route -> 5xx (500 observed)"],
     "style": "ink"},

    # --- minikube band ---
    {"x": 60, "y": 410, "w": 260, "h": 60,
     "lines": ["ambassador.wasm", "(sockets-rust, Chapter 13, reused)"],
     "style": "user"},
    {"x": 400, "y": 390, "w": 240, "h": 60,
     "lines": ["wasmtime run (no grant)", "dead port"],
     "style": "ghost"},
    {"x": 400, "y": 470, "w": 240, "h": 60,
     "lines": ["-S inherit-network", "dead port"],
     "style": "box"},
    {"x": 400, "y": 550, "w": 240, "h": 60,
     "lines": ["-S inherit-network", "live listener"],
     "style": "box"},
    {"x": 700, "y": 390, "w": 420, "h": 60,
     "lines": ["access-denied on attempt 1: fails fast, no retry"],
     "style": "ink"},
    {"x": 700, "y": 470, "w": 420, "h": 60,
     "lines": ["4x connection-refused, growing jittered backoff, then exit 1"],
     "style": "ink"},
    {"x": 700, "y": 550, "w": 420, "h": 60,
     "lines": ["connected to 127.0.0.1:port on attempt 1 (exit 0)"],
     "style": "accent"},
]

edges = [
    {"x1": 290, "y1": 120, "x2": 360, "y2": 120, "amber": True, "label": "link: booking (THE GRANT)"},
    {"x1": 590, "y1": 120, "x2": 660, "y2": 120},
    {"x1": 290, "y1": 230, "x2": 360, "y2": 230, "dashed": True, "label": "no link"},
    {"x1": 590, "y1": 230, "x2": 660, "y2": 230, "dashed": True},

    {"x1": 320, "y1": 420, "x2": 400, "y2": 420},
    {"x1": 320, "y1": 440, "x2": 400, "y2": 500},
    {"x1": 320, "y1": 460, "x2": 400, "y2": 580},
    {"x1": 640, "y1": 420, "x2": 700, "y2": 420},
    {"x1": 640, "y1": 500, "x2": 700, "y2": 500},
    {"x1": 640, "y1": 580, "x2": 700, "y2": 580},
]

notes = [
    {"x": 590, "y": 665, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Verified live 2026-10-21: CRC grant/no-grant pair cluster-live; minikube backoff/capability pair is a documented local smoke."},
]

gd.emit("21-ambassador-egress-grant", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
