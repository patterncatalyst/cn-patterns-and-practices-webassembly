#!/usr/bin/env python3
"""Figures for Chapter 0 — Setup.

00-toolchain-map : the two language toolchains converging on one shared
                    WIT contract and one shared host runtime — what's
                    Rust-only, what's Go-only, and what's common to both.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 0.1 — the build toolchain, two languages converging on one contract
# and one host runtime
# ---------------------------------------------------------------------------
gd.emit(
    "00-toolchain-map", 1100, 620,
    bands=[
        {"x":20,"y":16,"w":1060,"h":80,"label":"shared contract — read by every build below, modified by none of them","fill":"#fff3e0"},
        {"x":20,"y":110,"w":510,"h":300,"label":"Rust toolchain","fill":"#f1f5f9"},
        {"x":570,"y":110,"w":510,"h":300,"label":"Go toolchain","fill":"#fafafa"},
        {"x":20,"y":424,"w":1060,"h":90,"label":"shared pinned binaries — released by the Bytecode Alliance, SHA-256 verified","fill":"#f1f5f9"},
        {"x":20,"y":528,"w":1060,"h":76,"label":"shared host runtime — wasmtime, driven by the native host in examples/part2-building-components/host","fill":"#fff3e0"},
    ],
    nodes=[
        {"x":380,"y":40,"w":340,"h":44,"lines":["contracts/wit/ — package patterncatalyst:cargo@0.1.0"],"style":"accent"},

        {"x":50,"y":150,"w":220,"h":60,"lines":["Rust 1.99.1 (stable)","+ rustup target add wasm32-wasip2"],"style":"box"},
        {"x":300,"y":150,"w":210,"h":60,"lines":["cargo-component 0.21.1","built from source (cargo install)"],"style":"box"},
        {"x":50,"y":240,"w":460,"h":60,"lines":["cargo component build --release","generates bindings + builds the component in one step"],"style":"ink"},
        {"x":50,"y":330,"w":460,"h":56,"lines":["target/wasm32-wasip1/release/cargo_rust.wasm","exports world cargo"],"style":"box"},

        {"x":600,"y":150,"w":210,"h":60,"lines":["Go 1.26.9","standard toolchain, source + modules"],"style":"box"},
        {"x":840,"y":150,"w":210,"h":60,"lines":["wit-bindgen-go v0.7.0","go.bytecodealliance.org/cm v0.3.0"],"style":"box"},
        {"x":600,"y":240,"w":450,"h":60,"lines":["TinyGo 0.43.0 compiles the component","go build cannot emit Component Model exports (Ch7)"],"style":"ink"},
        {"x":600,"y":330,"w":450,"h":56,"lines":["go/cargo-go.wasm, via wasm-tools embed + adapt","exports world cargo"],"style":"box"},

        {"x":50,"y":450,"w":500,"h":46,"lines":["wasm-tools 1.262.0 — embed, adapt, inspect, validate"],"style":"accent"},
        {"x":590,"y":450,"w":470,"h":46,"lines":["wasip1→p2 reactor adapter (from the wasmtime v50 release)"],"style":"accent"},

        {"x":350,"y":546,"w":400,"h":44,"lines":["wasmtime 50.0.0 — runs both .wasm components"],"style":"accent"},
    ],
    edges=[
        {"x1":470,"y1":84,"x2":270,"y2":150,"label":""},
        {"x1":550,"y1":84,"x2":700,"y2":150,"label":""},
        {"x1":160,"y1":210,"x2":220,"y2":240,"label":""},
        {"x1":405,"y1":210,"x2":340,"y2":240,"label":"target"},
        {"x1":280,"y1":300,"x2":280,"y2":330,"label":""},
        {"x1":705,"y1":210,"x2":760,"y2":240,"label":""},
        {"x1":945,"y1":210,"x2":880,"y2":240,"label":"generates internal/cargo"},
        {"x1":825,"y1":300,"x2":825,"y2":330,"label":""},
        {"x1":280,"y1":386,"x2":280,"y2":450,"label":""},
        {"x1":825,"y1":386,"x2":825,"y2":450,"label":""},
        {"x1":300,"y1":496,"x2":450,"y2":546,"label":""},
        {"x1":825,"y1":496,"x2":650,"y2":546,"label":""},
    ],
    notes=[
        {"x":550,"y":600,"text":"Forward reference: wasmCloud / wash (Part 4) and minikube + OpenShift Local + the LGTM stack (Part 5) are each set up in their own parts, not here.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
