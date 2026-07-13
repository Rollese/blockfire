#!/usr/bin/env python3
"""Generate conquest_caspian: a 5-flag BF4-Caspian-Border-style infantry Conquest map.

world_half=500 (1000 m across). North-south push across a fully-destructible E-W
border wall; heightmap Hilltop/forest/ridges/river. Coordinates traced from the
owner's annotated reference (docs/superpowers/specs/2026-07-13-conquest-caspian-map-design.md).

Run:  python3 tools/map_gen_caspian.py   ->  writes maps/conquest_caspian.json
      + maps/heightmaps/conquest_caspian.png + _surface.png
"""
import json, os, zlib, struct

CELL = 2.4                     # BuildGrid.CELL_SIZE
WORLD_HALF = 500.0
SPACING = 2.0                  # terrain sample spacing (m)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_FP = {}

def extent(name):
    """Cell extent (minx, maxx, minz, maxz) of a prefab."""
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
def place(name, x0, z0, yaw=0):
    """Place a prefab so its MIN world corner lands at (x0,z0)."""
    minx, _mx, minz, _mz = extent(name)
    cx = round(x0 / CELL) - minx
    cz = round(z0 / CELL) - minz
    buildings.append({"prefab": name, "origin_cell": [cx, 0, cz], "yaw": yaw})
    nx, nz = footprint(name)
    return nx * CELL, nz * CELL

def _write_gray_png(path, width, height, data):
    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(data[y * width:(y + 1) * width])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"); f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat)); f.write(chunk(b"IEND", b""))

def _write_rgb_png(path, width, height, rgb_bytes):
    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw.extend(rgb_bytes[y * stride:(y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"); f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat)); f.write(chunk(b"IEND", b""))

# ---------------------------------------------------------------- flags + bases
points = [
    {"id": "A", "pos": [170, 0, -80], "radius": 24, "start_owner": 0},   # Antenna (US)
    {"id": "B", "pos": [-97, 0, -40], "radius": 24, "start_owner": 0},   # Checkpoint (US)
    {"id": "C", "pos": [51,  0,  34], "radius": 24, "start_owner": -1},  # Forest (neutral)
    {"id": "D", "pos": [-45, 0,  74], "radius": 24, "start_owner": 1},   # Hilltop (RU)
    {"id": "E", "pos": [34,  0, 216], "radius": 24, "start_owner": 1},   # Gas Station (RU)
]
bases = [
    {"team": 0, "pos": [-34,  0, -375], "radius": 30},   # US north
    {"team": 1, "pos": [-318, 0,  375], "radius": 30},   # RU southwest
]

# ---------------------------------------------------------------- roads (AABB, y=0)
# Highway (NW->SE) approximated as overlapping axis-aligned segments; a full diagonal
# is not needed for the cosmetic splatmap. E-W service road along the border; A->E dirt
# road down the east flank; RU basin path.
ROAD_W = 6.0
roads = [
    # main highway: NW corner down to the border crossing, then on to the SE
    {"min": [-190, 0, -500], "max": [-190 + ROAD_W, 0, -40]},
    {"min": [-190, 0, -46],  "max": [-40, 0, -40]},
    {"min": [-46,  0, -40],  "max": [-40 + ROAD_W, 0, 260]},
    {"min": [-46,  0, 254],  "max": [220, 0, 260]},
    # E-W service road on the border line
    {"min": [-320, 0, -3], "max": [320, 0, 3]},
    # A->E dirt road (east flank): vertical run past Antenna to Gas Station
    {"min": [164, 0, -260], "max": [170, 0, 220]},
    # RU basin path: RU deploy up to Gas Station
    {"min": [-318, 0, 300], "max": [40, 0, 306]},
]

def gen_heightmap():
    """Compose the Caspian height field (metres) and quantize to 8-bit.
    Features: gentle long-wavelength rolling hills; a dominant central Hilltop at
    D(-45,74); low ridges near Antenna and Forest; a shallow river channel along
    the blue reference line (N-S, wrapping the Hilltop); smoothstep flats under
    bases + flags. Slopes stay < MAX_WALKABLE_SLOPE_DEG (50). Returns
    (px uint8 n*n, n, height_min, height_scale)."""
    import numpy as np
    n = int(round(2 * WORLD_HALF / SPACING)) + 1          # 501
    axis = -WORLD_HALF + np.arange(n) * SPACING
    X, Z = np.meshgrid(axis, axis)                        # X[zi,xi]=x, Z[zi,xi]=z
    hm = np.zeros((n, n), dtype=np.float64)
    # rolling hills — long wavelengths so grade stays ~6-10 deg (walkable)
    hm += 8.0 * np.sin(X / 190.0) * np.cos(Z / 210.0)
    hm += 4.0 * np.sin(X / 95.0 + 1.3) * np.cos(Z / 110.0 + 0.4)
    # dominant central Hilltop at D — a broad rise commanding the field
    dh = np.hypot(X + 45.0, Z - 74.0)
    hm += np.where(dh < 130.0, 26.0 * np.clip(1.0 - dh / 130.0, 0.0, 1.0) ** 1.4, 0.0)
    # low ridge near Antenna (east) — sniping perch
    dr = np.hypot(X - 170.0, Z + 80.0)
    hm += np.where(dr < 70.0, 9.0 * (1.0 - dr / 70.0), 0.0)
    # shallow river channel along the blue line: a poly-line of points, carve a trench
    river = [(-140, -500), (-120, -300), (-100, -60), (-70, 74),
             (-40, 160), (30, 300), (30, 500)]
    for i in range(len(river) - 1):
        ax, az = river[i]; bx, bz = river[i + 1]
        vx, vz = bx - ax, bz - az
        L2 = vx * vx + vz * vz
        tt = np.clip(((X - ax) * vx + (Z - az) * vz) / max(L2, 1e-6), 0.0, 1.0)
        px_ = ax + tt * vx; pz_ = az + tt * vz
        dseg = np.hypot(X - px_, Z - pz_)
        hm += np.where(dseg < 14.0, -5.0 * (1.0 - dseg / 14.0), 0.0)   # ~5 m channel
    # smoothstep flats under bases + flags (flatten to LOCAL grade, not absolute 0)
    R0, BLEND = 26.0, 55.0
    flats = [(-34, -375), (-318, 375),                 # bases
             (170, -80), (-97, -40), (51, 34), (34, 216)]   # flags (Hilltop D omitted -> keep its rise)
    for fx, fz in flats:
        cxi = min(max(int(round((fx + WORLD_HALF) / SPACING)), 0), n - 1)
        czi = min(max(int(round((fz + WORLD_HALF) / SPACING)), 0), n - 1)
        ch = hm[czi][cxi]
        d = np.hypot(X - fx, Z - fz)
        t = np.clip((d - R0) / BLEND, 0.0, 1.0)
        w = 1.0 - (t * t * (3.0 - 2.0 * t))
        hm = hm * (1.0 - w) + ch * w
    height_min, height_scale = -12.0, 45.0    # covers channel (~-8) up to Hilltop+hills (~+30)
    px = np.clip(np.round((hm - height_min) / height_scale * 255.0), 0, 255).astype(np.uint8)
    return px, n, height_min, height_scale

def gen_surface_map(res=1024):
    """Rasterize `roads` into an (res,res,3) uint8 splatmap: R=asphalt inside road
    AABBs, G=sidewalk in a 2 m ring, B=0. Matches the heightmap pixel contract."""
    import numpy as np
    axis = np.linspace(-WORLD_HALF, WORLD_HALF, res)
    X, Z = np.meshgrid(axis, axis)
    SIDEWALK_M = 2.0
    any_road = np.zeros((res, res), dtype=bool)
    any_ring = np.zeros((res, res), dtype=bool)
    for rd in roads:
        x0, z0, x1, z1 = rd["min"][0], rd["min"][2], rd["max"][0], rd["max"][2]
        any_road |= (X >= x0) & (X <= x1) & (Z >= z0) & (Z <= z1)
        any_ring |= (X >= x0 - SIDEWALK_M) & (X <= x1 + SIDEWALK_M) & \
                    (Z >= z0 - SIDEWALK_M) & (Z <= z1 + SIDEWALK_M)
    sidewalk = any_ring & ~any_road
    rgb = np.zeros((res, res, 3), dtype=np.uint8)
    rgb[..., 0] = np.where(any_road, 255, 0)
    rgb[..., 1] = np.where(sidewalk, 255, 0)
    return rgb, res

# ---------------------------------------------------------------- buildings per flag
# B Checkpoint — most-developed border post (west of the crossing)
place("guardhouse", -120, -60)
place("guardhouse", -120, -20)
place("barracks",   -150, -55)
place("shed",       -150, -20)
# A Antenna — guardhouse at the mast base (tower/ladders added in Task 6 + Phase 2)
place("guardhouse", 158, -92)
place("bunker",     182, -70)
# C Forest — NO emplacement (canon). One portable building near the gate crossing.
place("shed", 96, 24)
# D Hilltop — minimal; radio tower is Phase 2. A lone bunker for hard cover.
place("bunker", -58, 62)
# E Gas Station — village + fuel
place("gas_station",    18, 196)
place("house",          58, 196)
place("twostory_house", 58, 224)
place("cottage",        18, 236)
place("silo",           -6, 208)          # fuel tank (approx water tower until Phase 2)
# US deploy (north) — staging
place("shed", -60, -390)
place("shed", -20, -390)
# RU deploy (SW) — industrial fuel depot
place("warehouse", -340, 360)
place("factory",   -300, 360)
place("silo",      -348, 396)

# ---------------------------------------------------------------- validation
def aabb(b):
    minx, maxx, minz, maxz = extent(b["prefab"])
    cx, _cy, cz = b["origin_cell"]
    return ((cx + minx) * CELL, (cz + minz) * CELL,
            (cx + maxx + 1) * CELL, (cz + maxz + 1) * CELL)

def overlap(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]

def validate_and_bake():
    boxes = [(b["prefab"], aabb(b)) for b in buildings]
    problems = []
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            if overlap(boxes[i][1], boxes[j][1]):
                problems.append("BUILDING OVERLAP: %s <-> %s" % (boxes[i][0], boxes[j][0]))
    for b in buildings:
        x0, z0, x1, z1 = aabb(b)
        b["footprint"] = {"min_x": x0, "max_x": x1, "min_z": z0, "max_z": z1}
    for p in problems:
        print("  ! " + p)
    return problems

def build_map():
    out = {
        "name": "Caspian Border",
        "world_half": WORLD_HALF,
        "roads": roads,
        "buildings": buildings,
        "ladders": [],
        "scenery": [],
        "points": points,
        "bases": bases,
        "vehicle_spawns": [],
        "terrain": {
            "heightmap": "heightmaps/conquest_caspian.png",
            "sample_spacing": SPACING,
            "height_min": 0.0,       # overwritten in main() with the real values
            "height_scale": 0.0,
            "surface_map": "heightmaps/conquest_caspian_surface.png",
        },
    }
    return out

def write_map(out):
    path = os.path.join(ROOT, "maps", "conquest_caspian.json")
    json.dump(out, open(path, "w"), indent=2)
    print("wrote %s: %d buildings, %d roads, %d points, %d bases"
          % (path, len(out["buildings"]), len(out["roads"]),
             len(out["points"]), len(out["bases"])))
    return path

def main():
    hm_dir = os.path.join(ROOT, "maps", "heightmaps")
    os.makedirs(hm_dir, exist_ok=True)
    px, n, hmin, hscale = gen_heightmap()
    _write_gray_png(os.path.join(hm_dir, "conquest_caspian.png"), n, n, px.tobytes())
    rgb, res = gen_surface_map(1024)
    _write_rgb_png(os.path.join(hm_dir, "conquest_caspian_surface.png"), res, res, rgb.tobytes())
    problems = validate_and_bake()
    out = build_map()
    out["terrain"]["height_min"] = float(hmin)
    out["terrain"]["height_scale"] = float(hscale)
    write_map(out)
    print("heightmap %dx%d, height_min=%.1f height_scale=%.1f, %d overlap problems"
          % (n, n, hmin, hscale, len(problems)))

if __name__ == "__main__":
    main()
