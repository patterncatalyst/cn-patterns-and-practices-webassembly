#!/usr/bin/env python3
"""Figure for Chapter 14 — wasmtime: Store safety controls.

14-store-safety-controls : the three host-side controls (fuel, epoch
                            interruption, ResourceLimiter) each gating the
                            same guest, contrasted against a clean run with
                            none of them tripped.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 14.2 — fuel / epoch / ResourceLimiter, each gating the guest, each
# contrasted with a clean run that succeeds.
# ---------------------------------------------------------------------------
gd.emit(
    "14-store-safety-controls", 1080, 640,
    bands=[
        {"x":20,"y":16,"w":1040,"h":60,"label":"guest: run(\"spin\", N) or run(\"grow\", N) — same component, three Stores","fill":"#fff3e0"},
        {"x":20,"y":92,"w":330,"h":520,"label":"Fuel","fill":"#f1f5f9"},
        {"x":375,"y":92,"w":330,"h":520,"label":"Epoch interruption","fill":"#f1f5f9"},
        {"x":730,"y":92,"w":330,"h":520,"label":"ResourceLimiter","fill":"#f1f5f9"},
    ],
    nodes=[
        {"x":45,"y":36,"w":280,"h":24,"lines":["run(\"spin\", 1_000_000_000)"],"style":"box"},

        {"x":45,"y":130,"w":280,"h":56,"lines":["Config::consume_fuel(true)"],"style":"box"},
        {"x":45,"y":198,"w":280,"h":56,"lines":["store.set_fuel(100_000)"],"style":"box"},
        {"x":45,"y":266,"w":280,"h":70,"lines":["budget exhausted mid-loop"],"style":"accent"},
        {"x":45,"y":350,"w":280,"h":56,"lines":["trapped with OutOfFuel"],"style":"ink"},
        {"x":45,"y":430,"w":280,"h":70,"lines":["contrast: set_fuel(50_000_000)","clean mode=ok, fuel remaining logged"],"style":"box"},

        {"x":400,"y":130,"w":280,"h":56,"lines":["Config::epoch_interruption(true)"],"style":"box"},
        {"x":400,"y":198,"w":280,"h":56,"lines":["store.set_epoch_deadline(1)"],"style":"box"},
        {"x":400,"y":266,"w":280,"h":70,"lines":["ticker thread: sleep(5ms);","engine.increment_epoch()"],"style":"accent"},
        {"x":400,"y":350,"w":280,"h":56,"lines":["trapped with Interrupt"],"style":"ink"},
        {"x":400,"y":430,"w":280,"h":70,"lines":["contrast: set_epoch_deadline(1_000_000)","far deadline: clean run ok"],"style":"box"},

        {"x":755,"y":130,"w":280,"h":56,"lines":["StoreLimitsBuilder","  .memory_size(8 * 1024 * 1024)"],"style":"box"},
        {"x":755,"y":198,"w":280,"h":56,"lines":["store.limiter(|s| &mut s.limits)"],"style":"box"},
        {"x":755,"y":266,"w":280,"h":70,"lines":["run(\"grow\", 64) needs 64 MiB","growth past 8 MiB cap DENIED"],"style":"accent"},
        {"x":755,"y":350,"w":280,"h":56,"lines":["allocator abort -> trap","(UnreachableCodeReached)"],"style":"ink"},
        {"x":755,"y":430,"w":280,"h":70,"lines":["contrast: memory_size(256 MiB)","same grow -> 64 blocks, 67108864 bytes"],"style":"box"},
    ],
    edges=[
        {"x1":185,"y1":60,"x2":185,"y2":130,"label":""},
        {"x1":540,"y1":60,"x2":540,"y2":130,"label":""},
        {"x1":895,"y1":60,"x2":895,"y2":130,"label":""},
        {"x1":185,"y1":186,"x2":185,"y2":198,"label":""},
        {"x1":540,"y1":186,"x2":540,"y2":198,"label":""},
        {"x1":895,"y1":186,"x2":895,"y2":198,"label":""},
        {"x1":185,"y1":254,"x2":185,"y2":266,"label":""},
        {"x1":540,"y1":254,"x2":540,"y2":266,"label":""},
        {"x1":895,"y1":254,"x2":895,"y2":266,"label":""},
        {"x1":185,"y1":336,"x2":185,"y2":350,"label":""},
        {"x1":540,"y1":336,"x2":540,"y2":350,"label":""},
        {"x1":895,"y1":336,"x2":895,"y2":350,"label":""},
    ],
    notes=[
        {"x":540,"y":610,"text":"Each column gates the SAME guest; the contrast row below each trap is the proof the control fired rather than the guest simply failing.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
