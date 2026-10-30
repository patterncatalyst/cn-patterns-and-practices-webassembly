#!/usr/bin/env python3
"""Fig 3.3/3.4: wiring one component's `cargo`-world export to
another component's `cargo-consumer`-world import (composition), and the
WIT-to-bindings-to-component pipeline each language toolchain runs to
produce that first component."""
import sys
sys.path.insert(0, "scripts")
import generate_diagram
generate_diagram.OUT = "assets/diagrams"
import os
os.makedirs(generate_diagram.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 3.3: composing two components against the same WIT package
# ---------------------------------------------------------------------------
W1, H1 = 820, 340

nodes_1 = [
    {"x": 60, "y": 110, "w": 290, "h": 120,
     "lines": ["cargo-service.wasm", "targets world cargo",
               "export booking, export handling",
               "(Rust or Go)"],
     "style": "user"},

    {"x": 470, "y": 110, "w": 290, "h": 120,
     "lines": ["gateway.wasm", "targets world cargo-consumer",
               "import booking, import handling",
               "(Rust or Go)"],
     "style": "accent"},

    {"x": 280, "y": 15, "w": 260, "h": 60,
     "lines": ["composed component", "wasm-tools compose / host wiring"],
     "style": "ink"},
]

edges_1 = [
    {"x1": 350, "y1": 150, "x2": 470, "y2": 150,
     "label": "cargo's export satisfies cargo-consumer's import"},
    {"x1": 360, "y1": 75, "x2": 300, "y2": 110, "dashed": True},
    {"x1": 460, "y1": 75, "x2": 520, "y2": 110, "dashed": True},
]

notes_1 = [
    {"x": 410, "y": 300, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Composition links an export to an import by interface identifier, not by language: a Go gateway can import a Rust-built cargo-service."},
]

generate_diagram.emit("03-component-composition", W1, H1, nodes=nodes_1, edges=edges_1, notes=notes_1)

# ---------------------------------------------------------------------------
# Figure 3.4: WIT to bindings to component, one pipeline, two toolchains
# ---------------------------------------------------------------------------
W2, H2 = 820, 400

nodes_2 = [
    {"x": 300, "y": 15, "w": 220, "h": 70,
     "lines": ["contracts/wit/", "types.wit · booking.wit",
               "handling.wit · world.wit"],
     "style": "ink"},

    {"x": 80, "y": 130, "w": 280, "h": 85,
     "lines": ["Rust toolchain", "cargo-component generates",
               "the binding crate from the WIT world"],
     "style": "user"},

    {"x": 460, "y": 130, "w": 280, "h": 85,
     "lines": ["Go toolchain", "wasm-tools + wit-bindgen-go generate",
               "the binding package from the WIT world"],
     "style": "accent"},

    {"x": 80, "y": 265, "w": 280, "h": 65,
     "lines": ["generated Rust bindings", "trait + types per interface"],
     "style": "box"},

    {"x": 460, "y": 265, "w": 280, "h": 65,
     "lines": ["generated Go bindings", "interface + types per package"],
     "style": "box"},

    {"x": 260, "y": 350, "w": 300, "h": 45,
     "lines": ["a .wasm component implementing world cargo"],
     "style": "ghost"},
]

edges_2 = [
    {"x1": 370, "y1": 85, "x2": 260, "y2": 130, "label": "cargo-component new"},
    {"x1": 450, "y1": 85, "x2": 560, "y2": 130, "label": "wit-bindgen-go generate"},
    {"x1": 220, "y1": 215, "x2": 220, "y2": 265},
    {"x1": 600, "y1": 215, "x2": 600, "y2": 265},
    {"x1": 280, "y1": 330, "x2": 350, "y2": 350, "amber": True},
    {"x1": 540, "y1": 330, "x2": 480, "y2": 350, "amber": True},
]

notes_2 = [
    {"x": 410, "y": 390, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Same WIT, two independent toolchains, each handing its own code the generated trait/interface to implement; no shared runtime step."},
]

generate_diagram.emit("03-wit-bindings-pipeline", W2, H2, nodes=nodes_2, edges=edges_2, notes=notes_2)
