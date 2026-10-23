#!/usr/bin/env python3
"""Figures for Chapter 6: First Component in Rust.

06-rust-build-pipeline : contracts/wit feeding cargo-component's generated
                          bindings, src/lib.rs implementing the generated
                          Guest traits over them, the wasm32-wasip1 core
                          module cargo-component builds, and the internal
                          adapt step that turns it into cargo_rust.wasm.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 6.1: contracts/wit to cargo_rust.wasm, via generated bindings and
# the implemented Guest traits
# ---------------------------------------------------------------------------
gd.emit(
    "06-rust-build-pipeline", 1080, 520,
    bands=[
        {"x":20,"y":16,"w":1040,"h":150,"label":"cargo component build --release, driven by Cargo.toml's [package.metadata.component.target]","fill":"#f1f5f9"},
        {"x":20,"y":188,"w":1040,"h":150,"label":"the crate's own source, written once the bindings exist","fill":"#fafafa"},
        {"x":20,"y":360,"w":1040,"h":130,"label":"build output: one core module, adapted internally into one component","fill":"#fff3e0"},
    ],
    nodes=[
        {"x":50,"y":56,"w":260,"h":90,"lines":["contracts/wit/","package patterncatalyst:cargo@0.1.0","world cargo"],"style":"box"},
        {"x":400,"y":56,"w":280,"h":90,"lines":["cargo-component 0.21.1","reads target.path + target.world"],"style":"accent"},
        {"x":780,"y":56,"w":260,"h":90,"lines":["bindings.rs (generated)","Guest trait per interface,","GuestCargoTracker for the resource"],"style":"box"},

        {"x":50,"y":228,"w":440,"h":90,"lines":["src/lib.rs","impl BookingGuest, impl HandlingGuest,","impl GuestCargoTracker for Tracker"],"style":"box"},
        {"x":560,"y":228,"w":480,"h":90,"lines":["Result<Booking, CargoError>","lowered to WIT result<booking, cargo-error>","by generated code, not hand-written"],"style":"ink"},

        {"x":50,"y":398,"w":320,"h":68,"lines":["wasm32-wasip1 core module","(cargo-component's internal build target)"],"style":"box"},
        {"x":430,"y":398,"w":60,"h":68,"lines":["adapt"],"style":"sub"},
        {"x":540,"y":398,"w":500,"h":68,"lines":["target/wasm32-wasip1/release/cargo_rust.wasm","exports world cargo"],"style":"accent"},
    ],
    edges=[
        {"x1":310,"y1":101,"x2":400,"y2":101,"label":"path, world"},
        {"x1":680,"y1":101,"x2":780,"y2":101,"label":"generates"},
        {"x1":910,"y1":146,"x2":500,"y2":228,"label":"bindings module, use bindings::exports::..."},
        {"x1":490,"y1":273,"x2":560,"y2":273,"label":"return type"},
        {"x1":270,"y1":318,"x2":270,"y2":398,"label":"cargo component build --release"},
        {"x1":370,"y1":432,"x2":430,"y2":432,"label":""},
        {"x1":490,"y1":432,"x2":540,"y2":432,"label":"internal, one step"},
    ],
    notes=[
        {"x":540,"y":505,"text":"The artifact lands under wasm32-wasip1/, not wasm32-wasip2/; cargo-component adapts a wasip1 core module into the component internally.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
