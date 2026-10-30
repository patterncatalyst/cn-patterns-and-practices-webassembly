#!/usr/bin/env python3
"""Figure 8.2: the 2x2 polyglot composition matrix. Two consumers
(Rust, Go) x two providers (Rust, Go) = four `wac plug` compositions, matched
purely by WIT identifier. All four, including the two cross-language pairs,
print the byte-identical normalized summary line under `wasmtime run`."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1040, 560

nodes = [
    # column headers: providers
    {"x": 300, "y": 20, "w": 280, "h": 70,
     "lines": ["provider: rust/", "cargo-component: exports cargo/*"],
     "style": "accent"},
    {"x": 620, "y": 20, "w": 280, "h": 70,
     "lines": ["provider: go/", "TinyGo + wasm-tools: exports cargo/*"],
     "style": "accent"},

    # row headers: consumers
    {"x": 20, "y": 140, "w": 240, "h": 70,
     "lines": ["consumer: consumer-rust/", "imports cargo/*, exports wasi:cli/run"],
     "style": "user"},
    {"x": 20, "y": 280, "w": 240, "h": 70,
     "lines": ["consumer: consumer-go/", "imports cargo/*, exports wasi:cli/run"],
     "style": "user"},

    # 2x2 matrix cells
    {"x": 300, "y": 140, "w": 280, "h": 70,
     "lines": ["rustC x rustP", "wac plug --plug rustP rustC"],
     "style": "box"},
    {"x": 620, "y": 140, "w": 280, "h": 70,
     "lines": ["rustC x goP", "wac plug --plug goP rustC"],
     "style": "box"},
    {"x": 300, "y": 280, "w": 280, "h": 70,
     "lines": ["goC x rustP", "wac plug --plug rustP goC"],
     "style": "box"},
    {"x": 620, "y": 280, "w": 280, "h": 70,
     "lines": ["goC x goP", "wac plug --plug goP goC"],
     "style": "box"},

    # shared result banner
    {"x": 160, "y": 420, "w": 720, "h": 110,
     "lines": ["wasmtime run composed-<name>.wasm", "identical normalized summary, all four combos",
               "booking=...|cargo=...|weight=1200.5|...|events=3|tracker=... in-transit 3|history=..."],
     "style": "ink"},
]

edges = [
    {"x1": 440, "y1": 90, "x2": 440, "y2": 140},
    {"x1": 760, "y1": 90, "x2": 760, "y2": 140},
    {"x1": 440, "y1": 90, "x2": 440, "y2": 280, "lx": 36},
    {"x1": 760, "y1": 90, "x2": 760, "y2": 280, "lx": 36},
    {"x1": 260, "y1": 175, "x2": 300, "y2": 175},
    {"x1": 260, "y1": 315, "x2": 300, "y2": 315},

    {"x1": 440, "y1": 210, "x2": 440, "y2": 420, "amber": True},
    {"x1": 760, "y1": 210, "x2": 700, "y2": 420, "amber": True},
    {"x1": 440, "y1": 350, "x2": 440, "y2": 420, "amber": True},
    {"x1": 760, "y1": 350, "x2": 700, "y2": 420, "amber": True},
]

notes = [
    {"x": 520, "y": 548, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Match-by-WIT-identifier, not by source language: the two cross-language cells compose and run exactly like the two same-language cells."},
]

gd.emit("08-polyglot-composition-matrix", W, H, nodes=nodes, edges=edges, notes=notes)
