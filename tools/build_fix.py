#!/usr/bin/env python3
"""Post-process the authored buildings/*.json to fix two universal defects found in the
2026-06-20 playtest:

  1. No ground floor — build_gen only emitted a roof (bfloor at y=h), so every building stood on
     bare grass with an open underside. We add a bfloor at y=0 across the full footprint.
  2. Open corners — a perimeter cell that is exposed on two faces (a corner) only carried ONE thin
     wall piece, leaving the other face open. We drop a bcolumn into each such corner so the
     silhouette closes.

Footprint is recovered from the roof layer (the bfloor slab at max y already covers every cell).
Idempotent: re-running won't double-add (skips a building that already has a y=0 floor).

Run:  python3 tools/build_fix.py
"""
import json, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def cells_at(pieces, y, typ=None):
    return {(p["offset"][0], p["offset"][2]) for p in pieces
            if p["offset"][1] == y and (typ is None or p["type"] == typ)}

def fix(path):
    d = json.load(open(path))
    name = os.path.basename(path)[:-5]
    pieces = d.get("pieces", [])
    if not pieces:
        return f"{name}: empty, skipped"
    maxy = max(p["offset"][1] for p in pieces)
    if maxy == 0:
        return f"{name}: flat, skipped"
    footprint = cells_at(pieces, maxy, "bfloor")
    if not footprint:
        # fall back to union of all cells if the roof isn't a clean bfloor slab
        footprint = {(p["offset"][0], p["offset"][2]) for p in pieces}

    # Floor only the INTERIOR cells — perimeter cells already hold a wall/door/window at y=0, and the
    # stamp model is one piece per (x,y,z) cell, so a floor there would collide and be dropped. The
    # interior slab gives a standable deck; walls ring it at the footprint edge.
    occupied_y0 = cells_at(pieces, 0)              # cells with any piece at ground level (the walls)
    interior = sorted(footprint - occupied_y0)
    added_floor = 0
    if not cells_at(pieces, 0, "bfloor"):
        for (x, z) in interior:
            pieces.append({"type": "bfloor", "offset": [x, 0, z], "yaw": 0})
            added_floor += 1

    # Interior props — the playtest saw bare rooms. The cell model is one piece per cell, so a prop
    # can't stack on a floor tile; instead convert a sparse subset of interior floor cells into props
    # (the prop rests on the cell base; the missing slab under it is hidden by the prop). Idempotent:
    # skip if any prop already placed.
    PROPS = ["prop_crate", "prop_barrel", "prop_shelf", "prop_table", "prop_locker", "prop_chair"]
    added_props = 0
    has_props = any(p["type"].startswith("prop_") for p in pieces)
    floor0 = sorted((p["offset"][0], p["offset"][2]) for p in pieces
                    if p["type"] == "bfloor" and p["offset"][1] == 0)
    if not has_props and len(floor0) >= 3:
        every = max(3, len(floor0) // 4)          # ~a quarter of the room, min spacing 3 cells
        prop_cells = {floor0[i] for i in range(0, len(floor0), every)}
        kept = [p for p in pieces
                if not (p["type"] == "bfloor" and p["offset"][1] == 0
                        and (p["offset"][0], p["offset"][2]) in prop_cells)]
        pieces = kept
        for idx, (x, z) in enumerate(sorted(prop_cells)):
            pieces.append({"type": PROPS[idx % len(PROPS)], "offset": [x, 0, z], "yaw": 0})
            added_props += 1

    d["pieces"] = pieces
    json.dump(d, open(path, "w"), indent=2)
    return f"{name}: +{added_floor} ground-floor, +{added_props} props -> {len(pieces)}p"

if __name__ == "__main__":
    for path in sorted(glob.glob(os.path.join(ROOT, "buildings", "*.json"))):
        print("  " + fix(path))
