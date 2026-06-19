#!/usr/bin/env python3
"""Generate a coherent, DENSE Conquest gameplay map: a town with a road grid (one N-S main
avenue, two N-S side streets, five E-W cross-streets), buildings packed into continuous
frontages along every street, 5 capture points, and 2 main bases.

Buildings are placed by their min world corner (x0,z0); they extend toward +x and +z, so a row
of them forms a clean south frontage (aligned min-z edge) facing the street to its south.
fill_row() cycles a themed prefab list to fill a frontage across the map width, skipping the
N-S street corridors so nothing blocks a road. A validator asserts no building overlaps and
none sits on a street (must print 0 problems). All yaw=0 -> footprints stay axis-aligned.

Run:  python3 tools/map_gen.py   ->  writes maps/conquest_town.json
"""
import json, os

CELL = 2.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_FP = {}

def extent(name):
    """True cell extent (minx, maxx, minz, maxz) of a prefab — offsets can be non-zero/negative."""
    if name not in _FP:
        data = json.load(open(os.path.join(ROOT, "buildings", name + ".json")))
        xs = [p["offset"][0] for p in data["pieces"]]
        zs = [p["offset"][2] for p in data["pieces"]]
        _FP[name] = (min(xs), max(xs), min(zs), max(zs))
    return _FP[name]

def footprint(name):
    minx, maxx, minz, maxz = extent(name)
    return (maxx - minx + 1, maxz - minz + 1)  # (nx, nz) in cells

buildings = []
def place(name, x0, z0):
    """Place so the building's MIN world corner lands at (x0,z0), accounting for piece offsets."""
    minx, _maxx, minz, _maxz = extent(name)
    cx = round(x0 / CELL) - minx
    cz = round(z0 / CELL) - minz
    buildings.append({"prefab": name, "origin_cell": [cx, 0, cz], "yaw": 0})
    nx, nz = footprint(name)
    return nx * CELL, nz * CELL

# N-S street corridors buildings must not cross (avenue + two side streets), as (x_lo, x_hi).
NS_STREETS = [(-81, -69), (-6, 6), (69, 81)]

def in_skip(x):
    for lo, hi in NS_STREETS:
        if lo <= x < hi:
            return hi
    return None

def crosses_skip(x, w):
    for lo, hi in NS_STREETS:
        if x < hi and x + w > lo:
            return hi
    return None

def fill_row(names, x0, x1, z_corner, gap=7.0):
    """Cycle `names` to fill a frontage from x0..x1 at min-corner z=z_corner, skipping streets.
    All arithmetic is in metres (footprint nx is in cells -> * CELL)."""
    x = x0
    i = 0
    guard = 0
    while x < x1 and guard < 400:
        guard += 1
        hi = in_skip(x)
        if hi is not None:
            x = hi + gap
            continue
        name = names[i % len(names)]
        w = footprint(name)[0] * CELL
        if x + w > x1:
            break
        hi = crosses_skip(x, w)
        if hi is not None:
            x = hi + gap
            continue
        place(name, x, z_corner)
        x += w + gap
        i += 1

# ---------------------------------------------------------------- roads
roads = [
    {"min": [-6, 0, -160], "max": [6, 0, 160]},      # Main Avenue (N-S spine)
    {"min": [-81, 0, -112], "max": [-69, 0, 112]},   # West side street
    {"min": [69, 0, -112], "max": [81, 0, 112]},     # East side street
    {"min": [-152, 0, -106], "max": [152, 0, -94]},  # Cross St -100
    {"min": [-152, 0, -56], "max": [152, 0, -44]},   # Cross St -50
    {"min": [-152, 0, -6], "max": [152, 0, 6]},      # Center St 0
    {"min": [-152, 0, 44], "max": [152, 0, 56]},     # Cross St +50
    {"min": [-152, 0, 94], "max": [152, 0, 106]},    # Cross St +100
]

# ---------------------------------------------------------------- districts
# Themed prefab pools (cycled to fill). South=industrial, center=commercial/civic, north=residential.
IND = ["warehouse", "factory", "hangar", "bunker", "silo", "parking", "supermarket"]
CIV = ["office", "office_tower", "apartment", "supermarket", "gas_station", "guardhouse", "materials"]
RES = ["house", "family_a", "family_b", "cottage", "townhouse", "villa", "lhouse", "barn", "shed", "barracks"]

# One frontage row per band, fronting the E-W street to its south (min-corner z = band bottom).
# Bands south->north: between bases (z +-150) and the five cross-streets.
fill_row(IND, -150, 150, z_corner=-124)  # B1: south outskirts (clear of team-0 base approach)
fill_row(IND, -150, 150, z_corner=-90)   # B2: industrial, north of Cross -100
fill_row(CIV, -150, 150, z_corner=-40)   # B3: commercial, north of Cross -50
fill_row(CIV, -150, 150, z_corner=12)    # B4: civic, north of Center St
fill_row(RES, -150, 150, z_corner=62)    # B5: residential, north of Cross +50
fill_row(RES, -150, 150, z_corner=108)   # B6: north outskirts (clear of team-1 base approach)

# ---------------------------------------------------------------- points + bases
points = [
    {"id": "A", "pos": [-90, 0, -70], "radius": 20, "start_owner": -1},  # SW industrial
    {"id": "B", "pos": [90, 0, -70], "radius": 20, "start_owner": -1},   # SE industrial
    {"id": "C", "pos": [0, 0, 0], "radius": 22, "start_owner": -1},      # central square
    {"id": "D", "pos": [-90, 0, 75], "radius": 20, "start_owner": -1},   # NW residential
    {"id": "E", "pos": [90, 0, 75], "radius": 20, "start_owner": -1},    # NE residential
]
bases = [
    {"team": 0, "pos": [0, 0, -150], "radius": 22},
    {"team": 1, "pos": [0, 0, 150], "radius": 22},
]
vehicle_spawns = [
    {"team": 0, "type": "transport", "pos": [-14, 0, -150], "heading": 0.0},
    {"team": 0, "type": "transport", "pos": [14, 0, -150], "heading": 0.0},
    {"team": 1, "type": "transport", "pos": [-14, 0, 150], "heading": 3.14159},
    {"team": 1, "type": "transport", "pos": [14, 0, 150], "heading": 3.14159},
]

out = {
    "name": "Town",
    "world_half": 170.0,
    "roads": roads,
    "buildings": buildings,
    "points": points,
    "bases": bases,
    "vehicle_spawns": vehicle_spawns,
}

# ---------------------------------------------------------------- validation
def aabb(b):
    minx, maxx, minz, maxz = extent(b["prefab"])
    cx, _cy, cz = b["origin_cell"]
    return ((cx + minx) * CELL, (cz + minz) * CELL, (cx + maxx + 1) * CELL, (cz + maxz + 1) * CELL)

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
    for bs in bases:
        bp = bs["pos"]; br = bs["radius"]
        bbox = (bp[0] - br, bp[2] - br, bp[0] + br, bp[2] + br)
        if overlap(bx, bbox):
            problems.append("BASE OVERLAP: %s in team-%d spawn" % (nm, bs["team"]))
for p in problems:
    print("  ! " + p)

path = os.path.join(ROOT, "maps", "conquest_town.json")
json.dump(out, open(path, "w"), indent=2)
print("wrote %s: %d buildings, %d roads, %d points, %d bases, %d problems"
      % (path, len(buildings), len(roads), len(points), len(bases), len(problems)))
