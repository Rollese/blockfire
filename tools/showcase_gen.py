#!/usr/bin/env python3
"""Generate maps/conquest_showcase.json — one of every building type laid out in a single row on a
flat field, spaced so you can walk around each and inspect it. Meant to be run WITH NO BOTS so the
buildings survive and you can explore in peace:

    godot --headless --path . -- --server --map=conquest_showcase --human-rpg
    godot --path . -- --connect=<host> --map=conquest_showcase --name=You    # no --bots

A label-free tour: walk east down the row. One spawn base behind you, a far base at the end, and a
single capture point so the match loads (it won't end without bots on the other team).

Run:  python3 tools/showcase_gen.py
"""
import json, os, glob

CELL = 2.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_FP = {}

def extent(name):
    if name not in _FP:
        d = json.load(open(os.path.join(ROOT, "buildings", name + ".json")))
        xs = [p["offset"][0] for p in d["pieces"]]
        zs = [p["offset"][2] for p in d["pieces"]]
        _FP[name] = (min(xs), max(xs), min(zs), max(zs))
    return _FP[name]

def footprint(name):
    minx, maxx, minz, maxz = extent(name)
    return (maxx - minx + 1, maxz - minz + 1)

# Every building type except the prop sampler. Sorted residential->commercial loosely by size.
NAMES = sorted(os.path.basename(f)[:-5] for f in glob.glob(os.path.join(ROOT, "buildings", "*.json")))
NAMES = [n for n in NAMES if n != "props"]

buildings = []
GAP = 8.0   # metres of clear ground between buildings
x = -160.0  # start well to the west; row marches east (+x)
z0 = 0.0    # all buildings share a min-z edge so their fronts line up facing south (-z)
for name in NAMES:
    minx, _mx, minz, _mz = extent(name)
    nx, nz = footprint(name)
    cx = round(x / CELL) - minx
    cz = round(z0 / CELL) - minz
    buildings.append({"prefab": name, "origin_cell": [cx, 0, cz], "yaw": 0})
    x += nx * CELL + GAP

row_span = x + 160.0
half = max(120.0, row_span * 0.5 + 30.0)

out = {
    "name": "Showcase",
    "world_half": half,
    "buildings": buildings,
    # Single point south of the row centre so you spawn looking at the buildings; one base each side.
    "points": [{"id": "C", "pos": [0, 0, -30], "radius": 18, "start_owner": 0}],
    "bases": [
        {"team": 0, "pos": [0, 0, -60], "radius": 16},
        {"team": 1, "pos": [0, 0, 60], "radius": 16},
    ],
}

path = os.path.join(ROOT, "maps", "conquest_showcase.json")
json.dump(out, open(path, "w"), indent=2)
print("wrote %s: %d buildings (%s), world_half=%.0f"
      % (path, len(buildings), ", ".join(NAMES), half))
