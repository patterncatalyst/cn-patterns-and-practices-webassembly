"""
diagrams.py: NEW companion-deck diagrams for "Server-Side WebAssembly in Go (TinyGo)" (201).

Red Hat-aligned Scene diagrams for figures that do not already exist in the
book's assets/diagrams/ library. Author here, then run build_diagrams.py
(it renders the full book figure library first, then builds + renders these).

Color by kind: rest=red (edge/API surface), svc=blue (services/clients),
data=purple (stores/state), platform=teal (infra/platform), govern=amber
(policy/coordination), danger=deep-red (anti-pattern/failure), neutral=grey,
muted=caption grey.

No new diagrams are authored in this unit: the 201-go deck reuses the
book's figure library (rendered into png/ by build_diagrams.py). Add Scene
functions here, and list them in SCENES, when a per-deck unit needs one.
"""
from dgen import Scene, PALETTE  # noqa: F401


SCENES = []


if __name__ == "__main__":
    for fn in SCENES:
        fn()
        print(f"built {fn.__name__}")
