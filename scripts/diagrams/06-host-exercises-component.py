#!/usr/bin/env python3
"""Figures for Chapter 6: First Component in Rust.

06-host-exercises-component : the native wasmtime host (host/src/main.rs)
                               instantiating cargo_rust.wasm against world
                               cargo and driving one scenario across the
                               component boundary, including the
                               cargo-tracker resource's constructor/drop.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 6.2: host/src/main.rs instantiating and calling cargo_rust.wasm
# ---------------------------------------------------------------------------
gd.emit(
    "06-host-exercises-component", 1080, 560,
    bands=[
        {"x":20,"y":16,"w":500,"h":500,"label":"host/src/main.rs: native Rust, wasmtime::component","fill":"#f1f5f9"},
        {"x":560,"y":16,"w":500,"h":500,"label":"cargo_rust.wasm: exports world cargo","fill":"#fff3e0"},
    ],
    nodes=[
        {"x":50,"y":56,"w":440,"h":56,"lines":["bindgen!({ path: contracts/wit, world: \"cargo\" })"],"style":"box"},
        {"x":50,"y":128,"w":440,"h":56,"lines":["Component::from_file + Cargo::instantiate(linker)"],"style":"box"},
        {"x":50,"y":200,"w":440,"h":56,"lines":["booking_api.call_book_cargo(spec, weight_kg)"],"style":"box"},
        {"x":50,"y":272,"w":440,"h":56,"lines":["call_get_cargo / call_request_possible_routes /","call_assign_route"],"style":"box"},
        {"x":50,"y":344,"w":440,"h":56,"lines":["handling_api.call_register_handling_event x3,","call_list_handling_events"],"style":"box"},
        {"x":50,"y":416,"w":440,"h":80,"lines":["tracker_api.call_constructor(cargo_id)","call_tracking_id / call_current_status / call_history","tracker.resource_drop(&mut store)"],"style":"ink"},

        {"x":600,"y":56,"w":420,"h":56,"lines":["impl BookingGuest for Component"],"style":"box"},
        {"x":600,"y":200,"w":420,"h":56,"lines":["book_cargo / get_cargo / request_possible_routes /","assign_route over thread_local STATE"],"style":"box"},
        {"x":600,"y":344,"w":420,"h":56,"lines":["impl HandlingGuest for Component"],"style":"box"},
        {"x":600,"y":416,"w":420,"h":80,"lines":["struct Tracker { tracking_id }","impl GuestCargoTracker for Tracker"],"style":"ink"},
    ],
    edges=[
        {"x1":490,"y1":228,"x2":600,"y2":84,"label":"call across component boundary"},
        {"x1":490,"y1":300,"x2":600,"y2":228,"label":""},
        {"x1":490,"y1":372,"x2":600,"y2":372,"label":""},
        {"x1":490,"y1":456,"x2":600,"y2":456,"label":"constructor + 3 methods"},
    ],
    notes=[
        {"x":540,"y":540,"text":"Same host binary, same scenario, same assertions run again in Chapter 7 against cargo-go.wasm; the point is that both sides satisfy identical calls.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
