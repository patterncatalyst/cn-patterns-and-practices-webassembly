#!/usr/bin/env python3
"""Figures for Chapter 10 — Error and Exception Handling.

10-error-mapping : how each language's native error model lowers/lifts onto
                    the shared WIT result<_, cargo-error> boundary, and the
                    separate, un-lowerable panic/panic() -> trap path, as
                    observed by the wasmtime host in both cases.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 10.2 — Rust Result/panic! and Go cm.Err/panic() mapped onto one WIT
# result<_, cargo-error>, and onto the host's two distinct observations.
# ---------------------------------------------------------------------------
gd.emit(
    "10-error-mapping", 1080, 520,
    bands=[
        {"x":20,"y":16,"w":330,"h":420,"label":"rust/src/lib.rs","fill":"#f1f5f9"},
        {"x":375,"y":16,"w":330,"h":420,"label":"contracts/wit/types.wit","fill":"#fff3e0"},
        {"x":730,"y":16,"w":330,"h":420,"label":"go/main.go","fill":"#f1f5f9"},
    ],
    nodes=[
        {"x":45,"y":56,"w":280,"h":64,"lines":["Result<Booking, CargoError>","Err(CargoError::NotFound(..))"],"style":"box"},
        {"x":45,"y":300,"w":280,"h":64,"lines":["panic!(\"__TRAP__ sentinel...\")","in get_cargo"],"style":"ink"},

        {"x":400,"y":56,"w":280,"h":80,"lines":["variant cargo-error {","  not-found(string), invalid-booking(string),","  invalid-location(string), conflict(string) }"],"style":"accent"},
        {"x":400,"y":160,"w":280,"h":56,"lines":["result<booking, cargo-error>","(bindgen lowers/lifts both sides)"],"style":"accent"},
        {"x":400,"y":300,"w":280,"h":64,"lines":["NO WIT shape for a trap —","it bypasses the result entirely"],"style":"ink"},

        {"x":755,"y":56,"w":280,"h":64,"lines":["cm.Result[..., Booking, CargoError]","cm.Err(types.CargoErrorNotFound(..))"],"style":"box"},
        {"x":755,"y":300,"w":280,"h":64,"lines":["panic(\"__TRAP__ sentinel...\")","in GetCargo"],"style":"ink"},

        {"x":45,"y":400,"w":280,"h":0,"lines":[""],"style":"ghost"},
    ],
    edges=[
        {"x1":325,"y1":88,"x2":400,"y2":80,"label":"lowers to"},
        {"x1":400,"y1":188,"x2":325,"y2":110,"label":""},
        {"x1":680,"y1":80,"x2":755,"y2":88,"label":"lowers to"},
        {"x1":755,"y1":110,"x2":680,"y2":188,"label":""},

        {"x1":325,"y1":332,"x2":400,"y2":332,"label":"no lowering — unwinds to a trap"},
        {"x1":680,"y1":332,"x2":755,"y2":332,"label":"no lowering — unwinds to a trap"},
    ],
    notes=[
        {"x":540,"y":430,"w":0,"text":"host/src/main.rs observes the left/right paths identically: Ok(Err(cargo-error::...)) for a result, an Err from the CALL itself for a trap — regardless of which language produced it.","size":12,"color":"#555555","anchor":"middle"},
        {"x":540,"y":460,"text":"Rust Result<T, CargoError> <-> WIT result<t, cargo-error> <-> Go cm.Result[...]; Rust panic! and Go panic() both become the SAME trap at the boundary.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
