#!/usr/bin/env python3
"""Generate a coherent Conquest gameplay map: a small town with a road network,
buildings laid out in districts beside the streets, 5 capture points, and 2 main bases.

Buildings are placed by their *min world corner* (x0,z0). origin_cell = round(corner/CELL).
We read each prefab's actual cell footprint so rows pack without overlapping the streets.
All placements use yaw=0 (footprint stays axis-aligned -> simple, overlap-free packing).

Run:  python3 tools/map_gen.py   ->  writes maps/conquest_town.json
"""
import json, os, glob

CELL = 2.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def footprint(name):
    """Return (nx, nz) cell footprint of a prefab from its piece offsets."""
    data = json.load(open(os.path.join(ROOT, "buildings", name + ".json")))
    xs = [p["offset"][0] for p in data["pieces"]]
    zs = [p["offset"][2] for p in data["pieces"]]
    return (max(xs) - min(xs) + 1, max(zs) - min(zs) + 1)

buildings = []
def place(name, x0, z0):
    """Place a building with its min corner at world (x0,z0). Returns world width,depth (m)."""
    nx, nz = footprint(name)
    cx = round(x0 / CELL)
    cz = round(z0 / CELL)
    buildings.append({"prefab": name, "origin_cell": [cx, 0, cz], "yaw": 0})
    return nx * CELL, nz * CELL

def row(names, x_start, z_corner, gap=6.0):
    """Lay a row of buildings west->east, min-corner z = z_corner."""
    x = x_start
    for n in names:
        w, _d = place(n, x, z_corner)
        x += w + gap

# ---------------------------------------------------------------- roads
# N-S main avenue down the middle, three E-W cross streets (south/center/north).
HALF = 11.0  # avenue half-width / street half-width band
roads = [
    {"min": [-6, 0, -170], "max": [6, 0, 170]},      # Main Avenue (N-S spine)
    {"min": [-150, 0, -66], "max": [150, 0, -54]},   # South Street
    {"min": [-150, 0, -6],  "max": [150, 0, 6]},     # Center Street
    {"min": [-150, 0, 54],  "max": [150, 0, 66]},    # North Street
]

# ---------------------------------------------------------------- districts
# One row per inter-street band so footprints never collide and the streets stay clear.
# Buildings extend toward +z from their min-corner z. West rows run from x=-150 toward the
# avenue (x=-6); east rows start past the avenue (x>=20). z-bands (corner -> deepest end):
#   A1 -145, A2 -100, B -52  (south of / flanking South St),  D 12  (flanking Center St),
#   E1 72, E2 118 (flanking North St, toward team-1 base). Center square (point C) left open.

# SOUTH industrial depot (point A, SW) + commercial market (point B, SE).
row(["bunker", "silo"],          x_start=-150, z_corner=-145); row(["hangar"], x_start=30, z_corner=-145)
row(["warehouse", "factory"],    x_start=-150, z_corner=-100); row(["supermarket", "parking"], x_start=30, z_corner=-100)
row(["barn", "shed"],            x_start=-150, z_corner=-52);  row(["gas_station", "materials"], x_start=30, z_corner=-52)

# CENTER civic block, south side of Center Street (square itself kept open).
row(["townhouse", "house", "villa", "guardhouse"], x_start=-150, z_corner=12)

# NORTH residential + military (point D NW, point E NE), flanking North Street.
row(["office_tower", "office", "apartment"], x_start=-150, z_corner=72); row(["barracks"], x_start=40, z_corner=72)
row(["family_a", "family_b", "cottage"],     x_start=-150, z_corner=118); row(["lhouse", "tower", "props"], x_start=20, z_corner=118)

# ---------------------------------------------------------------- points + bases
points = [
    {"id": "A", "pos": [-80, 0, -60], "radius": 18, "start_owner": -1},  # SW depot
    {"id": "B", "pos": [70,  0, -60], "radius": 18, "start_owner": -1},  # SE market
    {"id": "C", "pos": [0,   0, 0],   "radius": 20, "start_owner": -1},  # central square
    {"id": "D", "pos": [-80, 0, 60],  "radius": 18, "start_owner": -1},  # NW residential
    {"id": "E", "pos": [80,  0, 60],  "radius": 18, "start_owner": -1},  # NE barracks
]
bases = [
    {"team": 0, "pos": [0, 0, -150], "radius": 22},  # south
    {"team": 1, "pos": [0, 0, 150],  "radius": 22},  # north
]
vehicle_spawns = [
    {"team": 0, "type": "transport", "pos": [-14, 0, -150], "heading": 0.0},
    {"team": 0, "type": "transport", "pos": [14,  0, -150], "heading": 0.0},
    {"team": 1, "type": "transport", "pos": [-14, 0, 150],  "heading": 3.14159},
    {"team": 1, "type": "transport", "pos": [14,  0, 150],  "heading": 3.14159},
]

out = {
    "name": "Town",
    "world_half": 180.0,
    "roads": roads,
    "buildings": buildings,
    "points": points,
    "bases": bases,
    "vehicle_spawns": vehicle_spawns,
}
# ---------------------------------------------------------------- validation
def aabb(b):
    nx, nz = footprint(b["prefab"])
    cx, _cy, cz = b["origin_cell"]
    return (cx * CELL, cz * CELL, (cx + nx) * CELL, (cz + nz) * CELL)  # x0,z0,x1,z1

def overlap(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]

boxes = [(b["prefab"], aabb(b)) for b in buildings]
problems = []
for i in range(len(boxes)):
    for j in range(i + 1, len(boxes)):
        if overlap(boxes[i][1], boxes[j][1]):
            problems.append("BUILDING OVERLAP: %s <-> %s" % (boxes[i][0], boxes[j][0]))
for nm, bx in boxes:
    for rd in roads:
        rbx = (rd["min"][0], rd["min"][2], rd["max"][0], rd["max"][2])
        if overlap(bx, rbx):
            problems.append("ROAD OVERLAP: %s on a street" % nm)
for p in problems:
    print("  ! " + p)

path = os.path.join(ROOT, "maps", "conquest_town.json")
json.dump(out, open(path, "w"), indent=2)
print("wrote %s: %d buildings, %d roads, %d points, %d bases, %d problems"
      % (path, len(buildings), len(roads), len(points), len(bases), len(problems)))
