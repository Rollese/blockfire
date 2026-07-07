#!/usr/bin/env python3
"""Generate maps/conquest_suburb.json — medium-density suburban Conquest map.

A smaller, less grid-locked layout than conquest_town: main N-S avenue, E-W cross-street,
cul-de-sac side spurs, mixed residential frontages, and landmarks including twostory_house (M14).

Run:  python3 tools/map_gen_suburb.py
"""
import json
import os

CELL = 2.4   # BuildGrid.CELL_SIZE (global cube, 2026-07-07)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_FP = {}


def extent(name):
    if name not in _FP:
        data = json.load(open(os.path.join(ROOT, "buildings", name + ".json")))
        xs = [p["offset"][0] for p in data["pieces"]]
        zs = [p["offset"][2] for p in data["pieces"]]
        _FP[name] = (min(xs), max(xs), min(zs), max(zs))
    return _FP[name]


def footprint(name):
    minx, maxx, minz, maxz = extent(name)
    return (maxx - minx + 1, maxz - minz + 1)


buildings = []


def place(name, x0, z0):
    minx, _maxx, minz, _maxz = extent(name)
    cx = round(x0 / CELL) - minx
    cz = round(z0 / CELL) - minz
    buildings.append({"prefab": name, "origin_cell": [cx, 0, cz], "yaw": 0})
    return footprint(name)[0] * CELL, footprint(name)[1] * CELL


roads = [
    {"min": [-6, 0, -120], "max": [6, 0, 120]},
    {"min": [-120, 0, -6], "max": [120, 0, 6]},
    {"min": [-50, 0, -56], "max": [-38, 0, 56]},
    {"min": [38, 0, -56], "max": [50, 0, 56]},
]

NS_MAIN = (-6, 6)
W_SPUR = (-50, -38)
E_SPUR = (38, 50)
X_SKIP = [NS_MAIN, W_SPUR, E_SPUR]
GAP = 7.0


def in_x_band(x, lo, hi):
    return lo <= x < hi


def crosses_x_band(x, w, lo, hi):
    return x < hi and x + w > lo


def in_any_skip(x):
    for lo, hi in X_SKIP:
        if in_x_band(x, lo, hi):
            return hi
    return None


def crosses_any_skip(x, w):
    for lo, hi in X_SKIP:
        if crosses_x_band(x, w, lo, hi):
            return hi
    return None


def skip_past(hi):
    return hi + GAP


def fill_row(names, x0, x1, z_corner):
    x = x0
    i = 0
    guard = 0
    while x < x1 and guard < 300:
        guard += 1
        hi = in_any_skip(x)
        if hi is not None:
            x = skip_past(hi)
            continue
        name = names[i % len(names)]
        w = footprint(name)[0] * CELL
        if x + w > x1:
            break
        hi = crosses_any_skip(x, w)
        if hi is not None:
            x = skip_past(hi)
            continue
        place(name, x, z_corner)
        x += w + GAP
        i += 1


RES = ["cottage", "family_a", "family_b", "house", "townhouse", "villa", "lhouse", "shed", "barn"]
CIV = ["gas_station", "guardhouse", "office", "materials", "parking"]
IND = ["warehouse", "factory", "bunker", "silo", "hangar", "supermarket"]

# South / north residential bands (clear of the E-W cross-street at z=0). At CELL=2.4 the buildings
# are ~20% deeper, so the south row is pushed further south to keep the deep cul-de-sac industrial row
# (below) clear of both it and the cross-street.
fill_row(RES, -110, 110, z_corner=-46)
fill_row(RES, -110, 110, z_corner=16)

# West cul-de-sac frontage — starts west of the spur, marches east. z=-24 so the deepest bays
# (factory/warehouse ~17 m) still end south of the z=-6 cross-street at 2.4 m cells.
x = -108
for name in IND[:4]:
    hi = crosses_any_skip(x, footprint(name)[0] * CELL)
    if hi is not None:
        x = skip_past(hi)
    place(name, x, -24)
    x += footprint(name)[0] * CELL + GAP

# East cul-de-sac frontage (the 26 m-wide hangar no longer fits east of the spur at 2.4 m — dropped;
# it still appears on conquest_showcase/town).
x = 56
for name in CIV[:3]:
    hi = in_any_skip(x)
    if hi is not None:
        x = skip_past(hi)
    place(name, x, -24)
    x += footprint(name)[0] * CELL + GAP

# Landmarks around the central crossroads (placed in open quadrants).
place("twostory_house", 14, -30)    # SE — primary M14 walkable target
place("test_twostory", -62, 30)     # NW — clear of the west spur + residential row
place("office_tower", 60, 60)       # NE quadrant
place("apartment", -80, 60)         # NW residential edge
place("barracks", 60, -70)          # SE industrial edge

points = [
    {"id": "A", "pos": [-70, 0, -55], "radius": 18, "start_owner": -1},
    {"id": "B", "pos": [70, 0, -55], "radius": 18, "start_owner": -1},
    {"id": "C", "pos": [0, 0, 0], "radius": 20, "start_owner": -1},
    {"id": "D", "pos": [-70, 0, 55], "radius": 18, "start_owner": -1},
    {"id": "E", "pos": [70, 0, 55], "radius": 18, "start_owner": -1},
]
bases = [
    {"team": 0, "pos": [0, 0, -110], "radius": 22},
    {"team": 1, "pos": [0, 0, 110], "radius": 22},
]
# Vehicles DEFERRED (owner-directed 2026-07-05 — infantry/maps/destruction first; see
# docs/TASKS.md banner + AGENTS.md §12). No vehicle spawns emitted; coords preserved for restore.
_vehicle_spawns_deferred = [
    {"team": 0, "type": "transport", "pos": [-14, 0, -110], "heading": 0.0},
    {"team": 0, "type": "transport", "pos": [14, 0, -110], "heading": 0.0},
    {"team": 1, "type": "transport", "pos": [-14, 0, 110], "heading": 3.14159},
    {"team": 1, "type": "transport", "pos": [14, 0, 110], "heading": 3.14159},
]
vehicle_spawns = []

out = {
    "name": "Suburb",
    "world_half": 130.0,
    "roads": roads,
    "buildings": buildings,
    "points": points,
    "bases": bases,
    "vehicle_spawns": vehicle_spawns,
}


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
        bp = bs["pos"]
        br = bs["radius"]
        bbox = (bp[0] - br, bp[2] - br, bp[0] + br, bp[2] + br)
        if overlap(bx, bbox):
            problems.append("BASE OVERLAP: %s in team-%d spawn" % (nm, bs["team"]))
for p in problems:
    print("  ! " + p)

path = os.path.join(ROOT, "maps", "conquest_suburb.json")
json.dump(out, open(path, "w"), indent=2)
print("wrote %s: %d buildings, %d points, %d problems"
      % (path, len(buildings), len(points), len(problems)))
