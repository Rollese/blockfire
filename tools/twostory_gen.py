#!/usr/bin/env python3
"""Generate buildings/twostory_house.json — walkable two-story house for M14 playtest.

Improvements over test_twostory (3x3, single flight, 2 m ceilings):
  - 7x6 footprint (14 x 12 m) with a 4 m ground-floor volume (perimeter walls at y=0 and y=1)
  - Two northbound stair flights on the entry axis (door -> flight1 -> mid landing -> flight2)
  - Upper living floor at y=2 (world 4 m) with another 4 m ceiling band (walls y=2, y=3)
  - Flat roof slab at y=4; south door + windows on both floors

Run:  python3 tools/twostory_gen.py && python3 tools/build_fix.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NX, NZ = 7, 6
FP = {(x, z) for x in range(NX) for z in range(NZ)}


def open_face(x, z):
    return [(dx, dz) for (dx, dz) in ((0, 1), (0, -1), (1, 0), (-1, 0)) if (x + dx, z + dz) not in FP]


def correct_yaw(x, z):
    ofs = open_face(x, z)
    return 0 if any(dz != 0 for (_dx, dz) in ofs) else 2


PERIM = sorted((x, z) for (x, z) in FP if open_face(x, z))
INTERIOR = sorted(FP - set(PERIM))
DOOR = (3, 0)
STAIR1 = (3, 2)   # ground flight straight ahead of the door, ascends +Z (yaw 0)
STAIR2 = (3, 3)   # mid flight on the north landing, continues +Z to the upper floor (yaw 0)
STAIR_CELLS = {STAIR1, STAIR2}

pieces = []


def P(t, x, y, z, yaw=0):
    pieces.append({"type": t, "offset": [x, y, z], "yaw": yaw})


# Ground + upper perimeter bands (4 m each). Door column stays open at y=1 so the 4 m entry clears.
for y in (0, 1):
    for i, (x, z) in enumerate(PERIM):
        if y == 1 and (x, z) == DOOR:
            continue
        yaw = correct_yaw(x, z)
        if y == 0 and (x, z) == DOOR:
            P("bwall_door", x, y, z, yaw)
        elif y == 0 and i % 2 == 0:
            P("bwall_window", x, y, z, yaw)
        else:
            P("bwall", x, y, z, yaw)

for y in (2, 3):
    for i, (x, z) in enumerate(PERIM):
        yaw = correct_yaw(x, z)
        if i % 2 == 1:
            P("bwall_window", x, y, z, yaw)
        else:
            P("bwall", x, y, z, yaw)

# Ground interior deck (stair wells left open).
for (x, z) in INTERIOR:
    if (x, z) not in STAIR_CELLS:
        P("bfloor", x, 0, z)

# Mid landing deck between flights (y=1) — cells flanking the upper flight.
for (x, z) in ((2, 3), (4, 3), (2, 4), (3, 4), (4, 4)):
    P("bfloor", x, 1, z)

# Upper living floor (upper flight cell stays open at y=2).
for (x, z) in INTERIOR:
    if (x, z) != STAIR2:
        P("bfloor", x, 2, z)

# Roof.
for (x, z) in sorted(FP):
    P("bfloor", x, 4, z)

# Two northbound flights on the entry axis.
P("bstair", STAIR1[0], 0, STAIR1[1], 0)
P("bstair", STAIR2[0], 1, STAIR2[1], 0)

# Light set-dressing on the ground floor (props replace floor tiles — one piece per cell).
PROP_CELLS = [(2, 0, 1, "prop_table"), (4, 0, 1, "prop_chair"), (5, 0, 4, "prop_shelf")]
prop_at = {(x, z): t for (x, _y, z, t) in PROP_CELLS}
pieces = [p for p in pieces
          if not (p["type"] == "bfloor" and p["offset"][1] == 0
                  and (p["offset"][0], p["offset"][2]) in prop_at)]
for (x, y, z, t) in PROP_CELLS:
    P(t, x, y, z)

out = os.path.join(ROOT, "buildings", "twostory_house.json")
json.dump({"name": "twostory_house", "pieces": pieces}, open(out, "w"), indent=2)

seen = {}
dups = 0
for p in pieces:
    k = tuple(p["offset"])
    dups += 1 if k in seen else 0
    seen[k] = 1
print("wrote twostory_house.json: %d pieces, %d perim, dups=%d" % (len(pieces), len(PERIM), dups))
