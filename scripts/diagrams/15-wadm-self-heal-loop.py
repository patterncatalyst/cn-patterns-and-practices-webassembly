#!/usr/bin/env python3
"""Figure 15.2 — Ch15: wadm's reconcile loop self-healing the component.

The real captured sequence from evidence/2026-10-21/05-resilience.txt:
service healthy (200) -> `wash scale component ... --max-instances 0` removes
the component while the httpserver provider's listener stays up -> traffic
fails (500, "no component to handle it") -> wadm's SpreadScaler notices the
declared instance count (1) no longer matches actual (0) and restarts the
component -> traffic recovers to 200, within 2 seconds, with no redeploy.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 460

nodes = [
    {"x": 20, "y": 60, "w": 220, "h": 80,
     "lines": ["1. healthy", "GET /cargo/... -> 200", "component: 1 instance"],
     "style": "box"},

    {"x": 280, "y": 60, "w": 220, "h": 80,
     "lines": ["2. wash scale --max-instances 0", "provider's listener stays up;", "component instance count -> 0"],
     "style": "ink"},

    {"x": 540, "y": 60, "w": 220, "h": 80,
     "lines": ["3. traffic fails", "GET /cargo/... -> 500", "\"failed to invoke wrpc:http/", "incoming-handler\" — no component"],
     "style": "ghost"},

    {"x": 800, "y": 60, "w": 180, "h": 80,
     "lines": ["4. wadm reconciles", "SpreadScaler sees", "desired=1, actual=0"],
     "style": "accent"},

    {"x": 1000, "y": 60, "w": 160, "h": 80,
     "lines": ["5. recovered", "GET /cargo/... -> 200", "~2s, no redeploy"],
     "style": "box"},

    {"x": 280, "y": 230, "w": 740, "h": 150,
     "lines": ["wadm's continuous reconcile loop (the point of a declarative OAM manifest)",
               "desired state = wadm.yaml's spreadscaler: instances: 1, always",
               "actual state = what the lattice reports right now",
               "every drift between desired and actual gets corrected automatically —",
               "no human ran `wash start component` to bring it back"],
     "style": "box"},
]

edges = [
    {"x1": 240, "y1": 100, "x2": 280, "y2": 100},
    {"x1": 500, "y1": 100, "x2": 540, "y2": 100},
    {"x1": 760, "y1": 100, "x2": 800, "y2": 100, "amber": True},
    {"x1": 980, "y1": 100, "x2": 1000, "y2": 100, "amber": True},
    {"x1": 910, "y1": 140, "x2": 650, "y2": 230, "dashed": True, "label": "reconcile fires here"},
]

notes = [
    {"x": 590, "y": 20, "size": 13, "color": "#1d1d1d", "anchor": "middle", "bold": True,
     "text": "Real transcript: evidence/2026-10-21/05-resilience.txt — fail_observed=1 recovered=1, recovered after 2s"},
    {"x": 590, "y": 440, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "`wash app status: deployed` means the desired state was accepted at step 2 already — it does not mean step 3's 500s aren't happening."},
]

gd.emit("15-wadm-self-heal-loop", W, H, nodes=nodes, edges=edges, notes=notes)
