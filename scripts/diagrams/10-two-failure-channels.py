#!/usr/bin/env python3
"""Figures for Chapter 10 — Error and Exception Handling.

10-two-failure-channels : the two distinct ways a call across the component
                           boundary can fail — a recoverable result<_,
                           cargo-error> the host receives as Ok(Err(..)), and
                           an unrecoverable panic/trap the host receives as
                           Err on the wasmtime CALL itself, which poisons the
                           Store's instance.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 10.1 — recoverable cargo-error vs. unrecoverable trap
# ---------------------------------------------------------------------------
gd.emit(
    "10-two-failure-channels", 1080, 620,
    bands=[
        {"x":20,"y":16,"w":500,"h":560,"label":"RECOVERABLE — result<_, cargo-error>","fill":"#f1f5f9"},
        {"x":560,"y":16,"w":500,"h":560,"label":"UNRECOVERABLE — panic! / panic() -> trap","fill":"#fff3e0"},
    ],
    nodes=[
        {"x":50,"y":56,"w":440,"h":56,"lines":["get-cargo(\"NO-SUCH-CARGO\")"],"style":"box"},
        {"x":50,"y":128,"w":440,"h":64,"lines":["component returns","Err(CargoError::NotFound(msg)) / cm.Err(...)"],"style":"box"},
        {"x":50,"y":208,"w":440,"h":56,"lines":["wasmtime CALL returns Ok(..)"],"style":"box"},
        {"x":50,"y":280,"w":440,"h":72,"lines":["host sees Ok(Err(cargo-error::not-found))","a DOMAIN result, not a call failure"],"style":"ink"},
        {"x":50,"y":368,"w":440,"h":56,"lines":["Store + instance remain alive"],"style":"box"},
        {"x":50,"y":440,"w":440,"h":64,"lines":["host can call it again,","or any other export, on this Store"],"style":"box"},

        {"x":600,"y":56,"w":420,"h":56,"lines":["get-cargo(\"__TRAP__\")"],"style":"box"},
        {"x":600,"y":128,"w":420,"h":64,"lines":["component code runs","panic!(...) / panic(...)"],"style":"box"},
        {"x":600,"y":208,"w":420,"h":56,"lines":["unwinds to a wasm TRAP"],"style":"box"},
        {"x":600,"y":280,"w":420,"h":72,"lines":["wasmtime CALL ITSELF returns Err","no domain value at all — not Ok(Err(..))"],"style":"ink"},
        {"x":600,"y":368,"w":420,"h":56,"lines":["Store's instance is POISONED"],"style":"box"},
        {"x":600,"y":440,"w":420,"h":64,"lines":["no further exports may be called","on this Store — it must be the LAST call"],"style":"box"},
    ],
    edges=[
        {"x1":270,"y1":112,"x2":270,"y2":128},
        {"x1":270,"y1":192,"x2":270,"y2":208},
        {"x1":270,"y1":264,"x2":270,"y2":280},
        {"x1":270,"y1":352,"x2":270,"y2":368},
        {"x1":270,"y1":424,"x2":270,"y2":440},

        {"x1":810,"y1":112,"x2":810,"y2":128},
        {"x1":810,"y1":192,"x2":810,"y2":208},
        {"x1":810,"y1":264,"x2":810,"y2":280},
        {"x1":810,"y1":352,"x2":810,"y2":368},
        {"x1":810,"y1":424,"x2":810,"y2":440},
    ],
    notes=[
        {"x":540,"y":600,"text":"examples/part2-building-components/host/src/main.rs runs the trap call LAST, against both providers, specifically because of the bottom-right box.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
