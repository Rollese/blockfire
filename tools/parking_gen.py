#!/usr/bin/env python3
"""Regenerate buildings/parking.json as a coherent multi-deck parking structure.

The old version was an open column-and-slab garage, which fights the one-piece-per-cell stamp model:
it read as skeletal, had no real walls, 2 m levels (no headroom), and perimeter half-wall barriers
that floated (a barrier cell can't also hold a floor tile). This rebuilds it like every other working
template — solid perimeter walls, interior floor decks — but with an open garage-bay front and two
4 m decks so it still reads as a parking structure you can drive into.

Run:  python3 tools/parking_gen.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NX, NZ = 7, 5                      # footprint in cells (14 x 10 m)
FP = {(x, z) for x in range(NX) for z in range(NZ)}

def open_face(x, z):
    return [(dx, dz) for (dx, dz) in ((0, 1), (0, -1), (1, 0), (-1, 0)) if (x + dx, z + dz) not in FP]

def correct_yaw(x, z):
    # N or S exposed -> wall faces along X (yaw 0); only E/W exposed -> faces along Z (yaw 2).
    ofs = open_face(x, z)
    return 0 if any(dz != 0 for (_dx, dz) in ofs) else 2

PERIM = [(x, z) for (x, z) in sorted(FP) if open_face(x, z)]
INTERIOR = sorted(FP - set(PERIM))

pieces = []
def P(t, x, y, z, yaw=0):
    pieces.append({"type": t, "offset": [x, y, z], "yaw": yaw})

# Perimeter walls, 4 levels (y=0..3 -> 8 m, two 4 m decks). Front row (z=0) at ground = garage bays
# (open vehicle access); a few high windows on the upper band; everything else solid wall.
for y in range(4):
    for i, (x, z) in enumerate(PERIM):
        # Front row, lower two cells (y=0,1) = an open 4 m drive-in entrance with only corner posts.
        # The old garage-bay piece had a header beam at ~1.8 m that clipped a standing pawn's head.
        if z == 0 and y <= 1:
            if x in (0, NX - 1):
                P("bcolumn", x, y, z)          # corner posts carry the front of the upper deck
            continue                            # other front-ground cells stay fully open
        yaw = correct_yaw(x, z)
        t = "bwall_window" if (y >= 2 and i % 3 == 0) else "bwall"
        P(t, x, y, z, yaw)

# Floor decks: ground (y=0) + mid deck (y=2) interior-only (perimeter holds walls), roof (y=4) full.
for (x, z) in INTERIOR:
    P("bfloor", x, 0, z)
    P("bfloor", x, 2, z)
for (x, z) in sorted(FP):
    P("bfloor", x, 4, z)

json.dump({"name": "parking", "pieces": pieces},
          open(os.path.join(ROOT, "buildings", "parking.json"), "w"), indent=2)
# sanity: no two pieces in the same cell (stamp would drop them)
seen = {}
dups = 0
for p in pieces:
    k = tuple(p["offset"])
    dups += k in seen
    seen[k] = 1
print("wrote parking.json: %d pieces, %d perim, %d interior, dups=%d" % (len(pieces), len(PERIM), len(INTERIOR), dups))
