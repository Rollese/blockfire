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

# A compact VILLAGE CENTRE: dense frontages clustered around the central square and main avenue.
# The old outskirts rows (south B1 z=-124 / north B6 z=108) are REMOVED and the flanks trimmed to
# ~ +/-100 m — those edge buildings went unvisited (owner feedback). The cleared perimeter becomes
# walkable COUNTRYSIDE: rolling hills (gen_town_heightmap edge band) + fields (decorations/grass).
# Bands south->north front the E-W cross-street to their south; the 5 capture points ring the core.
fill_row(IND, -95, 95, z_corner=-90)    # south edge: workshops/light industrial (points A/B just south)
fill_row(CIV, -100, 100, z_corner=-40)  # commercial row, north of Cross -50
fill_row(CIV, -100, 100, z_corner=12)   # civic row at the central square (point C)
fill_row(RES, -95, 95, z_corner=62)     # residential row, north edge of the village (points D/E)

# Landmark: walkable two-story house at the central square (point C) for M14 playtest.
# Source prefab: `tools/twostory_gen.py` -> `buildings/twostory_house.json`.
place("twostory_house", 10, -22)

# ---------------------------------------------------------------- roof-access ladders
# Every multi-storey building here has a walkable `bfloor` roof deck but (except the
# two-story house) NO interior stairs, so those roofs are unreachable. Give the tall
# landmarks (roof >= 8 m) a red roof ladder so players can take the high ground and test
# fall damage. The ladder is a vertical climb VOLUME (Ladder.capture) whose top must land
# ON the deck; we place it at the street-facing (min-z) perimeter deck cell nearest the
# x-centre — interior access (enter via a door, climb to the roof), which guarantees the
# top is supported by the deck (an exterior vertical ladder would drop the player off the
# lip). All buildings are yaw=0, so placement is axis-aligned. Source of the render mesh:
# WorldRenderer._make_ladder (client-side, driven by these same entries).
LADDER_MIN_ROOF_M = 8.0

_ROOF = {}
def roof_deck(name):
    """(roof_cell_y, [(dx,dz)…]) of the TOP bfloor deck of a prefab, or None if single-storey."""
    if name not in _ROOF:
        data = json.load(open(os.path.join(ROOT, "buildings", name + ".json")))
        floors = [p["offset"] for p in data["pieces"] if p["type"] == "bfloor"]
        ymax = max((f[1] for f in floors), default=0)
        deck = [(f[0], f[2]) for f in floors if f[1] == ymax] if ymax > 0 else []
        _ROOF[name] = (ymax, deck) if deck else None
    return _ROOF[name]

ladders = []
for bi, b in enumerate(buildings):
    info = roof_deck(b["prefab"])
    if info is None:
        continue
    roof_cy, deck = info
    if roof_cy * CELL < LADDER_MIN_ROOF_M:
        continue
    cx, _cy, cz = b["origin_cell"]
    minz = min(dz for _dx, dz in deck)              # street-facing (min-z) edge row
    xc = sum(dx for dx, _dz in deck) / len(deck)    # deck x-centre
    dx, dz = min([(x, z) for x, z in deck if z == minz], key=lambda c: abs(c[0] - xc))
    wx = (cx + dx + 0.5) * CELL
    # Push the ladder to the OUTER (−z, street) face of its deck cell so it reads as an exterior
    # roof ladder standing clear of the wall — while staying INSIDE the cell (offset < CELL/2) so
    # its top still lands on the deck (floor_height_at maps the same cell). 0.75 m out from centre
    # clears the wall slab; a climber on the street engages it from outside (radius 0.6).
    wz = (cz + dz + 0.5) * CELL - 0.75
    ry = roof_cy * CELL
    # `building` = this ladder's index into the buildings list, so a building's collapse can remove
    # its ladder (climb volume server-side + red render node client-side). See server _build_map /
    # _resolve_cascades and world_renderer collapse drain.
    ladders.append({"bottom": [wx, 0.0, wz], "top": [wx, ry, wz], "radius": 0.6, "yaw": 0.0, "building": bi})

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
# Vehicles are DEFERRED to a post-core milestone (owner-directed 2026-07-05 — infantry/maps/
# destruction first; see docs/TASKS.md banner + AGENTS.md §12). No vehicle spawns are emitted so
# no vehicles appear in-match. The coordinates are preserved below for trivial restore when the
# dedicated Vehicles milestone is reopened.
_vehicle_spawns_deferred = [
    {"team": 0, "type": "transport", "pos": [-14, 0, -150], "heading": 0.0},
    {"team": 0, "type": "transport", "pos": [14, 0, -150], "heading": 0.0},
    {"team": 1, "type": "transport", "pos": [-14, 0, 150], "heading": 3.14159},
    {"team": 1, "type": "transport", "pos": [14, 0, 150], "heading": 3.14159},
]
vehicle_spawns = []

out = {
    "name": "Town",
    "world_half": 170.0,
    "roads": roads,
    "buildings": buildings,
    "ladders": ladders,
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

# Bake each building's world-AABB footprint so Terrain.load_for_map can flatten the FULL pad (not
# just the origin cell) — buildings then sit flush on the village's sloped ground. aabb() -> world m.
for b in buildings:
    x0, z0, x1, z1 = aabb(b)
    b["footprint"] = {"min_x": x0, "max_x": x1, "min_z": z0, "max_z": z1}

path = os.path.join(ROOT, "maps", "conquest_town.json")
json.dump(out, open(path, "w"), indent=2)
print("wrote %s: %d buildings, %d ladders, %d roads, %d points, %d bases, %d problems"
      % (path, len(buildings), len(ladders), len(roads), len(points), len(bases), len(problems)))


# ============================================================ M15 heightmap terrain
# proving_grounds is a HAND-AUTHORED map (this tool does not emit its points/bases/ladders).
# For M15 we procedurally (a) render a grayscale heightmap PNG that exercises every terrain
# mechanic and (b) inject the `terrain` block (+ one terrain_cutout building) into the existing
# JSON, preserving all its other keys. Re-running this tool is idempotent and reproducible.
#
# Encoding contract (must match shared/sim/terrain.gd::build_grid): a pixel value v in 0..255
# decodes to height = height_min + (v/255) * height_scale metres. n = 2*world_half/spacing + 1
# samples per axis; image row 0 == world z = -world_half (row-major, z increasing downward).

def _write_gray_png(path, width, height, data):
    """Write a valid 8-bit grayscale PNG (stdlib only: zlib + struct). `data` is row-major bytes
    of length width*height. Godot's Image.load() opens this straight into FORMAT_L8 -> RGBF."""
    import zlib, struct
    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)  # bit depth 8, colour type 0 (gray)
    raw = bytearray()
    stride = width
    for y in range(height):
        raw.append(0)                                   # filter type 0 (none) per scanline
        raw.extend(data[y * stride:(y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


def _write_rgb_png(path, width, height, rgb_bytes):
    """Write a valid 8-bit truecolour (RGB) PNG (stdlib only: zlib + struct). `rgb_bytes` is
    row-major, 3 bytes/pixel (R,G,B), length width*height*3. Used for the terrain SURFACE splatmap
    (R=asphalt strength, G=sidewalk strength, B=0) the client samples in the terrain shader so roads
    conform to the heightmap surface — no meshes, no z-fighting."""
    import zlib, struct
    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # bit depth 8, colour type 2 (RGB)
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)                                   # filter type 0 (none) per scanline
        raw.extend(rgb_bytes[y * stride:(y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


def gen_town_surface_map(world_half=170.0, res=684):
    """Rasterize the road network into an (res,res,3) uint8 splatmap. R=asphalt strength (255 inside
    each road AABB), G=sidewalk strength (255 in a ~2.5 m border ring just OUTSIDE each road AABB,
    minus any road), B=0 (grass default). World (x,z) in [-world_half, world_half] maps to pixel
    (col=x, row=z); row 0 == world z=-world_half (matches the heightmap contract and the shader's
    suv = (world.xz - map_origin) / map_extent sampling). Reads the module-level `roads` list.
    Deterministic: pure geometry, no RNG."""
    import numpy as np
    axis = np.linspace(-world_half, world_half, res)
    X, Z = np.meshgrid(axis, axis)                        # X[row,col]=x (per col), Z[row,col]=z (per row)
    SIDEWALK_M = 2.0
    any_road = np.zeros((res, res), dtype=bool)
    any_ring = np.zeros((res, res), dtype=bool)
    for rd in roads:
        x0, z0, x1, z1 = rd["min"][0], rd["min"][2], rd["max"][0], rd["max"][2]
        inside = (X >= x0) & (X <= x1) & (Z >= z0) & (Z <= z1)
        outer = (X >= x0 - SIDEWALK_M) & (X <= x1 + SIDEWALK_M) & (Z >= z0 - SIDEWALK_M) & (Z <= z1 + SIDEWALK_M)
        any_road |= inside
        any_ring |= outer
    sidewalk = any_ring & ~any_road
    rgb = np.zeros((res, res, 3), dtype=np.uint8)
    rgb[..., 0] = np.where(any_road, 255, 0)              # R: asphalt
    rgb[..., 1] = np.where(sidewalk, 255, 0)              # G: sidewalk
    return rgb, res


def gen_proving_grounds_heightmap(world_half=1000.0, spacing=2.0):
    """Compose the proving_grounds height field (metres) and quantize to 8-bit given
    height_min=-16, height_scale=64. Exercises: rolling hills, a valley basin at point B, a
    deliberately too-steep cliff wall, tunnel-portal ramps, and flat lots under bases/points.
    Returns (px uint8 n*n array, n, height_min, height_scale). Uses numpy (available on the
    toolchain) for a fast vectorized field; the PNG itself is written with stdlib only."""
    import numpy as np
    n = int(round(2 * world_half / spacing)) + 1          # 1001 for the defaults
    axis = -world_half + np.arange(n) * spacing
    X, Z = np.meshgrid(axis, axis)                        # X[zi,xi]=world x, Z[zi,xi]=world z
    hm = np.zeros((n, n), dtype=np.float64)
    # Rolling hills. On a 2000 m map, 6 m hills are a ~0.3% grade -> read as dead flat. Use BIG amplitude
    # (24 m primary + 9 m secondary octave) over long wavelengths so the terrain reads as real hills yet
    # the slopes stay walkable: max grade ~ 24/240 + 9/120 = 0.175 -> ~10 deg (< MAX_WALKABLE_SLOPE_DEG=50).
    hm += 24.0 * np.sin(X / 240.0) * np.cos(Z / 280.0)
    hm += 9.0 * np.sin(X / 120.0 + 1.7) * np.cos(Z / 140.0 + 0.4)
    # a deep valley basin at point B (-300, 300), ~ -34 m over a 200 m radius (grade ~0.17 -> ~10 deg,
    # walkable). Point B deliberately sits IN the valley -> a capture point on dramatic low ground; B is
    # excluded from the flats below so the basin survives.
    dvb = np.hypot(X + 300.0, Z - 300.0)
    hm += np.where(dvb < 200.0, -34.0 * (1.0 - dvb / 200.0), 0.0)
    # a deliberately too-steep RIDGE wall centred at x=415, z in +/-80: a localized triangular ridge
    # rising ~20 m over a 10 m run (gradient 2.0 -> ~63 deg, well past MAX_WALKABLE_SLOPE_DEG=50) then
    # back down — a wall to test slope-blocking (walk/jump/drive rejected), NOT a mesa. Deliberately
    # localized (z flanks are open) so bots route AROUND it: it must not partition the map or wall a
    # base. (An earlier version made x>430 a 40 m mesa over the whole east half, trapping team-1's base
    # behind a 40 m cliff — the bot fleet froze at spawn. This ridge keeps the too-steep test feature
    # without that partition.)
    in_z = (Z >= -80.0) & (Z <= 80.0)
    ridge = np.clip(1.0 - np.abs(X - 415.0) / 9.0, 0.0, 1.0)   # triangular 0->1->0 over x=406..424
    hm += np.where(in_z, 28.0 * ridge, 0.0)   # ~28 m over a 9 m face -> grade ~3.1 -> ~72 deg (unwalkable)
    # tunnel-entrance ramps sculpted down to portals at (0,-120) and (0,120)
    for pz in (-120.0, 120.0):
        dp = np.hypot(X, Z - pz)
        hm += np.where(dp < 45.0, -14.0 * (1.0 - dp / 45.0), 0.0)
    # SMOOTHLY blend flat lots under bases/points into the surrounding grade. A HARD radius-45 pad set
    # to 0 created a 0->~5 m step at the pad edge whose central-difference slope sat right at/above the
    # 50 deg walk limit, ringing every spawn with an unwalkable wall (the fleet froze at base). Instead:
    # flat within R0, then a smoothstep blend to natural terrain over BLEND m (max edge slope ~5-7 deg).
    # Point B (-300,300) is OMITTED so its valley basin survives; buildings get their own runtime pad in
    # Terrain.load_for_map, snapped to local grade.
    R0, BLEND = 30.0, 65.0   # wider blend: with ~24 m hills the pad edge must ramp gently (stay < 50 deg)
    flats = [(-900, 0), (900, 0), (-600, -400), (0, 0), (300, -300), (600, 400)]
    for fx, fz in flats:
        # Flatten to the LOCAL grade (the natural height at the pad centre), NOT absolute 0 — else a base
        # sitting where the terrain is naturally +18 m becomes an 18 m PIT ("underground"). Sampling the
        # centre height first makes each pad a flat clearing at the surrounding elevation.
        cxi = min(max(int(round((fx + world_half) / spacing)), 0), n - 1)
        czi = min(max(int(round((fz + world_half) / spacing)), 0), n - 1)
        ch = hm[czi][cxi]
        d = np.hypot(X - fx, Z - fz)
        t = np.clip((d - R0) / BLEND, 0.0, 1.0)
        w = 1.0 - (t * t * (3.0 - 2.0 * t))     # smoothstep: w=1 (flat) inside R0 -> 0 (natural) at R0+BLEND
        hm = hm * (1.0 - w) + ch * w            # inside: hm->ch (flat at local grade); outside: unchanged
    height_min, height_scale = -45.0, 105.0   # covers the deep valley (~-40) up to hills+ridge (~+55)
    px = np.clip(np.round((hm - height_min) / height_scale * 255.0), 0, 255).astype(np.uint8)
    return px, n, height_min, height_scale


def add_terrain_to_proving_grounds():
    """Render the heightmap PNG and inject the terrain block + a terrain_cutout building into the
    hand-authored conquest_proving_grounds.json, preserving every existing key. Idempotent."""
    px, n, height_min, height_scale = gen_proving_grounds_heightmap(1000.0, 2.0)
    hm_dir = os.path.join(ROOT, "maps", "heightmaps")
    os.makedirs(hm_dir, exist_ok=True)
    png_path = os.path.join(hm_dir, "proving_grounds.png")
    _write_gray_png(png_path, n, n, px.tobytes())

    map_path = os.path.join(ROOT, "maps", "conquest_proving_grounds.json")
    md = json.load(open(map_path))
    md["terrain"] = {
        "heightmap": "heightmaps/proving_grounds.png",
        "sample_spacing": float(2.0),
        "height_min": float(height_min),
        "height_scale": float(height_scale),
    }
    # A terrain_cutout building in the sculpted depression at the (0,-120) tunnel portal, to
    # exercise the cutout mechanism end-to-end in a real map. `guardhouse` is an existing small
    # prefab (26 pieces) already shipped in conquest_town. Idempotent: strip any prior cutout
    # building first so re-runs don't stack duplicates.
    bl = [b for b in md.get("buildings", []) if not b.get("terrain_cutout", False)]
    bl.append({
        "prefab": "guardhouse",
        "origin_cell": [0, -2, -60],   # world (0,-4,-120): below grade at the tunnel portal
        "yaw": 0,
        "terrain_cutout": True,
    })
    md["buildings"] = bl
    json.dump(md, open(map_path, "w"), indent=2)
    print("wrote %s (%dx%d, %d bytes) + terrain block + cutout guardhouse -> %s"
          % (png_path, n, n, os.path.getsize(png_path), map_path))


def gen_town_heightmap(world_half=170.0, spacing=2.0):
    """GENTLE rolling hills for the infantry town. Unlike proving_grounds (4 spread-out buildings,
    dramatic relief), conquest_town packs buildings ~7 m apart, and EACH gets a HARD flat pad at
    load (Terrain.flatten_pad — no blend). If the natural grade under a footprint is steep, the pad
    edge becomes a cliff and rings spawns/rows with an unwalkable wall (the M15 fleet-freeze bug).
    So the CORE (where buildings stand) keeps a low grade (~11 deg): long wavelengths + modest
    amplitude. The cleared PERIMETER (edge rows were thinned — nobody visited them) gets taller
    ROLLING HILLS as a scenic, walkable backdrop. Base spawns are flattened to their local grade."""
    import numpy as np
    n = int(round(2 * world_half / spacing)) + 1            # 171 for the defaults
    axis = -world_half + np.arange(n) * spacing
    X, Z = np.meshgrid(axis, axis)
    hm = np.zeros((n, n), dtype=np.float64)
    # A SINGLE gentle long-wavelength swell across the core (grade ~4 deg). The old stacked medium/short
    # octaves made the built-up core read as BUMPY, so leveled roads rode up-and-down over it and their
    # edges waved against the lower grass. One smooth swell -> roads (and the whole village) sit on a
    # near-flat grade; the dramatic relief lives in the perimeter countryside hills below.
    hm += 5.0 * np.sin(X / 88.0) * np.cos(Z / 98.0)
    # Perimeter hills: ramp in taller relief only OUTSIDE the built-up core (|x|>115 or |z|>120), where
    # edge buildings were removed. `edge` is 0 in the core and eases to 1 toward the map rim, so the
    # extra amplitude never touches a building pad. Wavelengths stay long -> the hills read big but the
    # slope stays walkable (~14 deg peak on the rim).
    ex = np.clip((np.abs(X) - 115.0) / 40.0, 0.0, 1.0)
    ez = np.clip((np.abs(Z) - 120.0) / 40.0, 0.0, 1.0)
    edge = np.maximum(ex, ez)
    edge = edge * edge * (3.0 - 2.0 * edge)                 # smoothstep for a seamless core->rim blend
    hm += edge * 14.0 * np.sin(X / 90.0 + 0.4) * np.cos(Z / 100.0 + 1.9)
    hm += edge * 6.0 * np.cos(X / 55.0 + 2.6) * np.sin(Z / 60.0 + 0.8)
    # Flatten each team base spawn (z = +/-150) to the LOCAL grade with a smoothstep blend (flat within
    # R0, ramping to natural over BLEND) so deploy areas are level without a hard pad-edge step.
    R0, BLEND = 24.0, 28.0
    for bx, bz in [(0.0, -150.0), (0.0, 150.0)]:
        cxi = min(max(int(round((bx + world_half) / spacing)), 0), n - 1)
        czi = min(max(int(round((bz + world_half) / spacing)), 0), n - 1)
        ch = hm[czi][cxi]
        d = np.hypot(X - bx, Z - bz)
        t = np.clip((d - R0) / BLEND, 0.0, 1.0)
        w = 1.0 - (t * t * (3.0 - 2.0 * t))
        hm = hm * (1.0 - w) + ch * w
    # Level each ROAD to a FLAT cross-section (no side-tilt) with a smoothly-graded centreline (no
    # bumpy oscillation): sample the terrain along the road's centreline, smooth it 1D, then assign that
    # ONE height across the whole road WIDTH at each point along its length, with a short perpendicular
    # ramp into the grass. Roads are axis-aligned (long axis = the wider dimension). Intersections: a
    # later road overwrites the crossing cells (tiny mismatch, invisible on the gentle core). Buildings
    # never overlap roads (validated), so no pad/road conflict.
    def _ix(w):
        return min(max(int(round((w + world_half) / spacing)), 0), n - 1)
    def _smooth1d(a, k=24):
        for _ in range(k):
            a = 0.5 * a + 0.25 * (np.roll(a, 1) + np.roll(a, -1))
        return a
    SHOULDER = 5   # cells of perpendicular road->grass ramp beyond the flat bed (gentle, walkable)
    PAD = 2        # cells of FLAT bed kept BEYOND the road edge to cover the painted 2 m sidewalk, so the
                   # sidewalk sits on LEVEL ground (not the sloped shoulder) -> its edge reads straight,
                   # not wavy. The ramp to grass starts only AFTER the sidewalk.
    for rd in roads:
        xi0, xi1, zi0, zi1 = _ix(rd["min"][0]), _ix(rd["max"][0]), _ix(rd["min"][2]), _ix(rd["max"][2])
        if (xi1 - xi0) >= (zi1 - zi0):                          # E-W road -> level across Z
            prof = _smooth1d(hm[(zi0 + zi1) // 2, :].copy())
            lo, hi = zi0 - PAD, zi1 + PAD                       # flat bed = road + sidewalk
            for zi in range(max(lo - SHOULDER, 0), min(hi + SHOULDER + 1, n)):
                d = (lo - zi) if zi < lo else ((zi - hi) if zi > hi else 0)
                w = max(1.0 - d / (SHOULDER + 1.0), 0.0)
                hm[zi, xi0:xi1 + 1] = w * prof[xi0:xi1 + 1] + (1.0 - w) * hm[zi, xi0:xi1 + 1]
        else:                                                   # N-S road -> level across X
            prof = _smooth1d(hm[:, (xi0 + xi1) // 2].copy())
            lo, hi = xi0 - PAD, xi1 + PAD
            for xi in range(max(lo - SHOULDER, 0), min(hi + SHOULDER + 1, n)):
                d = (lo - xi) if xi < lo else ((xi - hi) if xi > hi else 0)
                w = max(1.0 - d / (SHOULDER + 1.0), 0.0)
                hm[zi0:zi1 + 1, xi] = w * prof[zi0:zi1 + 1] + (1.0 - w) * hm[zi0:zi1 + 1, xi]
    # TIGHT dynamic 8-bit range (just cover the actual relief + a small margin) so the quantization step
    # is as fine as possible — a wide fixed range wasted levels and micro-stairstepped flat roads.
    import math
    lo, hi = float(hm.min()), float(hm.max())
    height_min = math.floor(lo) - 2.0
    height_scale = math.ceil(hi - lo) + 4.0
    px = np.clip(np.round((hm - height_min) / height_scale * 255.0), 0, 255).astype(np.uint8)
    return px, n, height_min, height_scale


def add_terrain_to_town():
    """Render the town heightmap PNG and inject the terrain block into conquest_town.json, preserving
    every existing key (buildings/ladders/points/bases/roads). Idempotent."""
    px, n, height_min, height_scale = gen_town_heightmap(170.0, 2.0)
    hm_dir = os.path.join(ROOT, "maps", "heightmaps")
    os.makedirs(hm_dir, exist_ok=True)
    png_path = os.path.join(hm_dir, "conquest_town.png")
    _write_gray_png(png_path, n, n, px.tobytes())

    # Road/sidewalk SURFACE splatmap: roads are painted onto the terrain surface in the client shader
    # (world_renderer._terrain_material) so they conform to the hills — no flat road meshes to bury/hover.
    rgb, res = gen_town_surface_map(170.0, 1024)   # higher res -> crisper road/sidewalk edges
    surf_path = os.path.join(hm_dir, "conquest_town_surface.png")
    _write_rgb_png(surf_path, res, res, rgb.tobytes())

    map_path = os.path.join(ROOT, "maps", "conquest_town.json")
    md = json.load(open(map_path))
    md["terrain"] = {
        "heightmap": "heightmaps/conquest_town.png",
        "sample_spacing": float(2.0),
        "height_min": float(height_min),
        "height_scale": float(height_scale),
        "surface_map": "heightmaps/conquest_town_surface.png",
    }
    json.dump(md, open(map_path, "w"), indent=2)
    print("wrote %s (%dx%d) + %s (%dx%d) + terrain/surface block -> %s"
          % (png_path, n, n, surf_path, res, res, map_path))


def add_scenery_to_town():
    """Scatter countryside decorations — trees (copses in the fields) + rocks — onto the GRASS of
    conquest_town, avoiding building footprints, roads, and the capture/base zones. Deterministic
    (fixed seed -> reproducible). Emitted as `scenery` (id/pos/yaw/scale/palette); the client seats
    each on the terrain (WorldRenderer._terrain_y) and renders the GLB (cosmetic, no collision). Denser
    in the cleared perimeter (countryside/fields) than in the village core. Idempotent."""
    import random
    rng = random.Random(0xB10CF19E)
    map_path = os.path.join(ROOT, "maps", "conquest_town.json")
    md = json.load(open(map_path))
    world_half = float(md.get("world_half", 170.0))

    # Exclusion AABBs/circles: keep decorations off buildings, roads, and objectives.
    boxes = []  # (x0, z0, x1, z1) with margin
    for b in md.get("buildings", []):
        f = b.get("footprint")
        if f:
            boxes.append((f["min_x"] - 2.0, f["min_z"] - 2.0, f["max_x"] + 2.0, f["max_z"] + 2.0))
    for rd in md.get("roads", []):
        boxes.append((rd["min"][0] - 1.5, rd["min"][2] - 1.5, rd["max"][0] + 1.5, rd["max"][2] + 1.5))
    circles = []  # (cx, cz, r) — capture points + bases kept clear so nothing blocks the zone read
    for pt in md.get("points", []):
        circles.append((pt["pos"][0], pt["pos"][2], float(pt.get("radius", 20)) + 2.0))
    for bs in md.get("bases", []):
        circles.append((bs["pos"][0], bs["pos"][2], float(bs.get("radius", 22)) + 4.0))

    def blocked(x, z):
        for x0, z0, x1, z1 in boxes:
            if x0 <= x <= x1 and z0 <= z <= z1:
                return True
        for cx, cz, r in circles:
            if (x - cx) ** 2 + (z - cz) ** 2 <= r * r:
                return True
        return False

    def is_countryside(x, z):
        return abs(x) > 108.0 or z < -92.0 or z > 80.0

    TREES = ["tree_type0_01", "tree_type0_03", "tree_type1_02", "tree_type2_01", "tree_type2_04",
             "tree_type3_02", "tree_type4_01", "tree_type5_03", "tree_type6_02", "tree_type7_01"]
    ROCKS = ["rock_type1_02", "rock_type2_01", "rock_type3_03", "rock_type4_02", "rock_type5_01", "rock_type6_04"]
    TREE_PAL = ["normal", "normal", "normal", "normal", "dry"]   # green countryside, an occasional dry tree

    scenery = []
    lim = world_half - 4.0

    def try_place(x, z, kind):
        if abs(x) > lim or abs(z) > lim or blocked(x, z):
            return False
        if kind == "tree":
            scenery.append({"id": rng.choice(TREES), "pos": [round(x, 1), 0.0, round(z, 1)],
                            "yaw": round(rng.uniform(0.0, 6.283), 3), "scale": round(rng.uniform(0.85, 1.5), 2),
                            "palette": rng.choice(TREE_PAL)})
        else:
            scenery.append({"id": rng.choice(ROCKS), "pos": [round(x, 1), 0.0, round(z, 1)],
                            "yaw": round(rng.uniform(0.0, 6.283), 3), "scale": round(rng.uniform(0.7, 1.8), 2),
                            "palette": rng.choice(["grey", "grey", "green"])})
        return True

    # Tree copses: seed cluster centres, denser in the countryside; drop a few trees around each.
    copses = 0
    attempts = 0
    while copses < 34 and attempts < 4000:
        attempts += 1
        cx = rng.uniform(-lim, lim)
        cz = rng.uniform(-lim, lim)
        if blocked(cx, cz):
            continue
        if not is_countryside(cx, cz) and rng.random() > 0.28:
            continue   # keep the village interior sparse (only ~28% of copses land in-town)
        n = rng.randint(2, 6)
        placed_any = False
        for _ in range(n):
            x = cx + rng.uniform(-8.0, 8.0)
            z = cz + rng.uniform(-8.0, 8.0)
            placed_any |= try_place(x, z, "tree")
        if placed_any:
            copses += 1

    # Scattered lone rocks/boulders across the whole grass surface.
    rocks = 0
    attempts = 0
    while rocks < 55 and attempts < 6000:
        attempts += 1
        x = rng.uniform(-lim, lim)
        z = rng.uniform(-lim, lim)
        if not is_countryside(x, z) and rng.random() > 0.35:
            continue
        if try_place(x, z, "rock"):
            rocks += 1

    md["scenery"] = scenery
    md["scenery_palette"] = {"tree": "normal", "rock": "grey"}
    json.dump(md, open(map_path, "w"), indent=2)
    n_tree = sum(1 for s in scenery if s["id"].startswith("tree"))
    print("wrote %d scenery (%d trees / %d rocks) -> %s" % (len(scenery), n_tree, len(scenery) - n_tree, map_path))


add_terrain_to_proving_grounds()
add_terrain_to_town()
add_scenery_to_town()
