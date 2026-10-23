#!/usr/bin/env python3
"""Figures for Chapter 0: Setup.

00-dev-loop : the build -> inspect -> run -> verify cycle readers repeat
              while working through Part 2's examples, and where teardown
              fits once a cycle is done.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 0.2: the dev loop: build, inspect, run, verify, teardown
# ---------------------------------------------------------------------------
gd.emit(
    "00-dev-loop", 1100, 460,
    bands=[
        {"x":20,"y":16,"w":1060,"h":340,"label":"examples/part2-building-components/: repeat this loop per language, then run verify.sh for both","fill":"#f1f5f9"},
    ],
    nodes=[
        {"x":50,"y":70,"w":230,"h":80,"lines":["1. build","cargo component build --release","./go/build.sh (TinyGo)"],"style":"box"},
        {"x":320,"y":70,"w":230,"h":80,"lines":["2. inspect","wasm-tools component wit <file>.wasm"],"style":"ink"},
        {"x":590,"y":70,"w":230,"h":80,"lines":["3. run","cargo-host <wasm> scenario.json <lang>"],"style":"box"},
        {"x":860,"y":70,"w":190,"h":80,"lines":["4. verify","./verify.sh"],"style":"accent"},

        {"x":320,"y":200,"w":460,"h":70,"lines":["verify.sh diffs Rust output vs Go output","and checks exported interfaces against contracts/wit"],"style":"box"},

        {"x":200,"y":310,"w":700,"h":40,"lines":["5. teardown: cargo clean; rm core.wasm embedded.wasm cargo-go.wasm (see .gitignore)"],"style":"sub"},
    ],
    edges=[
        {"x1":280,"y1":110,"x2":320,"y2":110,"label":""},
        {"x1":550,"y1":110,"x2":590,"y2":110,"label":"exports match?"},
        {"x1":820,"y1":110,"x2":860,"y2":110,"label":""},
        {"x1":955,"y1":150,"x2":700,"y2":200,"label":"runs both languages"},
        {"x1":550,"y1":270,"x2":550,"y2":310,"label":"between runs"},
    ],
    notes=[
        {"x":550,"y":420,"text":"check-prereqs.sh runs once, before step 1, to confirm the toolchain this loop depends on.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
