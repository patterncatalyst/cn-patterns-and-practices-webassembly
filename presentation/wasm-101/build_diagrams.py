"""
build_diagrams.py: render the figure library for this deck (SVG -> PNG).

Step 1: cairosvg-render every book figure (assets/diagrams/*.svg in the
        cn-patterns-and-practices-webassembly repo) into ./png/<name>.png
        at output_width=1400, so any slide can reuse any book figure by name.
Step 2: build + render any NEW deck-only diagrams defined in diagrams.py
        (Scene API -> SVG + Excalidraw), via cairosvg at output_width=1600.

Usage:
    python3 build_diagrams.py
"""
import os
import subprocess
import sys
import glob

WORK = os.environ.get("DECK_WORK", ".")
DIAG = f"{WORK}/diagrams"
PNG = f"{WORK}/png"

# Pinned to THIS repo's book figure library (63 paired SVG/Excalidraw figures).
BOOK_DIAGRAMS = os.environ.get(
    "BOOK_DIAGRAMS",
    os.path.normpath(os.path.join(WORK, "..", "..", "assets", "diagrams")),
)

sys.path.insert(0, WORK)
import diagrams as _diagrams  # noqa: E402


def main():
    os.makedirs(DIAG, exist_ok=True)
    os.makedirs(PNG, exist_ok=True)

    import cairosvg

    # 1) Render every book figure into png/ so any slide can reference it by name.
    book_svgs = sorted(glob.glob(f"{BOOK_DIAGRAMS}/*.svg"))
    print(f"Rendering {len(book_svgs)} book figures from {BOOK_DIAGRAMS} ...")
    for svg in book_svgs:
        out = f"{PNG}/{os.path.splitext(os.path.basename(svg))[0]}.png"
        cairosvg.svg2png(url=svg, write_to=out, output_width=1400)
    print(f"  wrote {len(book_svgs)} book figure PNGs")

    # 2) Build all NEW deck-only scenes via the Scene API.
    print("\nBuilding new deck scenes...")
    for fn in _diagrams.SCENES:
        fn()
        print(f"  built {fn.__name__}")

    # 3) Render each new SVG to PNG via cairosvg.
    new_svgs = sorted(glob.glob(f"{DIAG}/*.svg"))
    print(f"\nRendering {len(new_svgs)} new deck SVGs to PNG...")
    for svg in new_svgs:
        out = f"{PNG}/{os.path.splitext(os.path.basename(svg))[0]}.png"
        cairosvg.svg2png(url=svg, write_to=out, output_width=1600)

    # 4) Report
    total = sorted(glob.glob(f"{PNG}/*.png"))
    print(f"\n{len(total)} PNGs in {PNG}/ ({len(book_svgs)} book + {len(new_svgs)} new).")


if __name__ == "__main__":
    main()
