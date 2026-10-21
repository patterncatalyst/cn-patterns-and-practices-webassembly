#!/usr/bin/env python3
"""Figure 22.2 — Ch22: cold-start scaling math.

A Wasm replica becomes ready in single-digit to low-hundreds of milliseconds
(instantiation, not a boot sequence). A container or JVM workload needs
several seconds (image already resident, but process init, classloading, and
JIT warmup still run). The gap matters for HPA tuning: the default sync
interval and stabilization windows are calibrated for container-class
startup, so a wasm replica can be ready and serving well before the next HPA
sync tick even evaluates it.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1040, 420

bands = [
    {"x": 20, "y": 20, "w": 1000, "h": 240,
     "label": "time-to-ready, same scale-up event",
     "fill": "#f1f5f9"},
]

nodes = [
    {"x": 40, "y": 70, "w": 230, "h": 60,
     "lines": ["Wasm replica", "(raw-shim or wasmCloud)"],
     "style": "sub"},
    {"x": 300, "y": 70, "w": 60, "h": 60,
     "lines": ["~ms"],
     "style": "accent"},
    {"x": 380, "y": 70, "w": 600, "h": 60,
     "lines": ["ready in single-digit to low-hundreds of ms", "(instantiate, not boot)"],
     "style": "sub"},

    {"x": 40, "y": 170, "w": 230, "h": 60,
     "lines": ["Container / JVM workload"],
     "style": "sub"},
    {"x": 300, "y": 170, "w": 680, "h": 60,
     "lines": ["ready in several seconds", "process init, classloading, JIT warmup"],
     "style": "box"},

    {"x": 40, "y": 280, "w": 960, "h": 130,
     "lines": ["HPA's default syncPeriod / readiness-probe cadence and scale-up",
               "stabilizationWindowSeconds are tuned for container-class startup.",
               "A wasm replica can be ready and serving before the next HPA sync",
               "tick even fires — shorten probe intervals and the scale-up window",
               "for wasm Deployments, or the autoscaler reacts a full cycle late."],
     "style": "ink"},
]

edges = [
    {"x1": 850, "y1": 55, "x2": 850, "y2": 225, "dashed": True, "label": "~15s typical HPA sync interval"},
]

notes = [
    {"x": 520, "y": 410, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Cold-start speed is an HPA-tuning input, not just a nice-to-have: it changes which window settings are correct."},
]

gd.emit("22-cold-start-scaling-math", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)
