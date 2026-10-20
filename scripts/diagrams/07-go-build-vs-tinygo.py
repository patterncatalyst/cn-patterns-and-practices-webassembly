#!/usr/bin/env python3
"""Figure for Chapter 7 — First Component in Go.

07-go-build-vs-tinygo : the same main.go and the same generated bindings fed
                         to two compilers — standard `go build` rejects the
                         pointerful result/parameter types wit-bindgen-go
                         emits via its `//go:wasmexport` check, while TinyGo,
                         targeting wasm32 natively, accepts the identical
                         source and produces a working wasip1 reactor core.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 7.2 — go build (rejects) vs TinyGo (accepts), same source either way
# ---------------------------------------------------------------------------
gd.emit(
    "07-go-build-vs-tinygo", 1100, 460,
    bands=[
        {"x":20,"y":76,"w":500,"h":360,"label":"GOOS=wasip1 GOARCH=wasm go build","fill":"#fff0ef"},
        {"x":580,"y":76,"w":500,"h":360,"label":"tinygo build -target=wasip1","fill":"#f1f8f2"},
    ],
    nodes=[
        {"x":310,"y":16,"w":480,"h":48,"lines":["Same main.go + internal/cargo/** bindings, unmodified"],"style":"ink"},

        {"x":50,"y":120,"w":440,"h":56,"lines":["go1.26.9, GOARCH=wasm = 64-bit pointers"],"style":"box"},
        {"x":50,"y":188,"w":440,"h":70,"lines":["//go:wasmexport checks every exported","result and parameter type"],"style":"box"},
        {"x":50,"y":270,"w":440,"h":110,"lines":["rejects: *cm.Result[...], *cm.List[...],","*string, *types.Leg","— pointerful types forbidden"],"style":"ink"},
        {"x":50,"y":392,"w":440,"h":36,"lines":["✗ compile fails, no core.wasm"],"style":"box"},

        {"x":610,"y":120,"w":440,"h":56,"lines":["TinyGo 0.43, wasm32 target natively"],"style":"box"},
        {"x":610,"y":188,"w":440,"h":70,"lines":["no //go:wasmexport pointer-width","restriction on this target"],"style":"box"},
        {"x":610,"y":270,"w":440,"h":110,"lines":["accepts the same exported signatures","as ordinary 32-bit wasm functions"],"style":"accent"},
        {"x":610,"y":392,"w":440,"h":36,"lines":["✓ core.wasm written, reactor exports"],"style":"accent"},
    ],
    edges=[
        {"x1":270,"y1":176,"x2":270,"y2":188},
        {"x1":270,"y1":258,"x2":270,"y2":270},
        {"x1":270,"y1":380,"x2":270,"y2":392},

        {"x1":830,"y1":176,"x2":830,"y2":188},
        {"x1":830,"y1":258,"x2":830,"y2":270},
        {"x1":830,"y1":380,"x2":830,"y2":392,"amber":True},
    ],
    notes=[
        {"x":550,"y":440,"text":"Not a Go-dialect rewrite: the compiler changes, the source and bindings do not.","size":12,"color":"#555555","anchor":"middle"},
    ],
)
