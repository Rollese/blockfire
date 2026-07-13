# conquest_caspian Map — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a new 5-flag Conquest map `conquest_caspian` modelled on BF4 Caspian Border — infantry-only, `world_half = 500` (1000 m across), a fully-destructible E–W border wall, heightmap Hilltop/forest/ridges/river — authored by a Python generator, validated deterministically, and passed through the 128-bot fleet gate.

**Architecture:** A self-contained generator `tools/map_gen_caspian.py` emits `maps/conquest_caspian.json` + a grayscale heightmap PNG + a road surface splatmap PNG, following the exact patterns of `tools/map_gen.py` (`CELL=2.4`, `place/extent`, `_write_gray_png/_write_rgb_png`, overlap validation, baked footprints). Flags/bases/roads/wall/scenery come from coordinates traced from the owner's annotated reference image. The map is data-only — no engine/wire changes — so validation is a new `tests/map_caspian_test.gd` (TestCase) plus the existing shipping-map guards, and the real gate is the 128-bot fleet run.

**Tech Stack:** Python 3 + numpy (generator, matches the toolchain), stdlib `zlib`/`struct` (PNG writers), GDScript `TestCase` suite, Godot 4 headless.

**Canonical layout reference:** `~/Downloads/caspian_drawing.png` (owner's annotations on the real map) + the design spec `docs/superpowers/specs/2026-07-13-conquest-caspian-map-design.md`. Flag/base coordinates below were traced from it into world space; treat them as the starting placement and refine against the reference + fleet gate.

---

## Coordinate reference (world metres, N = −Z, world_half = 500)

Traced from `caspian_drawing.png`. The border line runs E–W at **z ≈ 0**.

| Entity | pos [x, 0, z] | radius | start_owner | Notes |
|---|---|---|---|---|
| Flag A — Antenna | `[170, 0, -80]` | 24 | 0 (US) | East flank, US side, rock-ringed vantage |
| Flag B — Checkpoint | `[-97, 0, -40]` | 24 | 0 (US) | West-centre, on the highway crossing |
| Flag C — Forest | `[51, 0, 34]` | 24 | -1 (neutral) | Contested centre, no emplacement |
| Flag D — Hilltop | `[-45, 0, 74]` | 24 | 1 (RU) | Central rocky rise |
| Flag E — Gas Station | `[34, 0, 216]` | 24 | 1 (RU) | Village, RU side |
| Base US (team 0) | `[-34, 0, -375]` | 30 | — | North deploy |
| Base RU (team 1) | `[-318, 0, 375]` | 30 | — | SW industrial depot |

**Border wall** runs along z ≈ 0, x ∈ [−300, 300], with gaps (crossings/breaches) at:
- B highway crossing: x ∈ [−112, −82] (≈ flag B)
- A→E gate: x ∈ [118, 148]
- pre-existing breach: x ∈ [-260, -244]

**Roads (AABB, y=0):**
- Highway (NW→SE), approximated by segments (§ generator).
- E–W service road along the border.
- A→E dirt road (US → Antenna → Gas Station).
- RU basin path (RU → Hilltop → Gas Station).

---

## File structure

- **Create `tools/map_gen_caspian.py`** — the generator (self-contained: constants, PNG writers, `extent/place`, heightmap, splatmap, flags/bases/roads/wall/scenery, validation, JSON emit). One responsibility: produce the three map artefacts deterministically.
- **Create `maps/conquest_caspian.json`** — generated output (committed).
- **Create `maps/heightmaps/conquest_caspian.png`** — generated grayscale heightmap (committed).
- **Create `maps/heightmaps/conquest_caspian_surface.png`** — generated road splatmap (committed).
- **Create `buildings/border_wall.json`** — a 1-cell-wide, 2-high concrete wall segment prefab (only if a prefab is used instead of `prebuilt[]`; this plan uses `prebuilt[]`, see Task 5 — so this file is optional and NOT created by default).
- **Create `tests/map_caspian_test.gd`** — deterministic validation (TestCase).
- **Modify `tests/map_def_test.gd:89-93`** — add `conquest_caspian` to the no-vehicle-spawns guard.
- **Modify `data/server_config.example.json:6`** — add `conquest_caspian` to the rotation.

---

## PHASE 1 — playable + gate-testable

### Task 1: Generator skeleton + PNG writers + empty run

**Files:**
- Create: `tools/map_gen_caspian.py`

- [ ] **Step 1: Write the generator skeleton**

Create `tools/map_gen_caspian.py` with the header, constants, prefab helpers, and the two stdlib PNG writers copied verbatim from `tools/map_gen.py` (they are pure; importing `map_gen` is avoided because that module writes `conquest_town.json` as an import side-effect).

```python
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

def main():
    print("map_gen_caspian: skeleton OK")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it to verify it executes**

Run: `python3 tools/map_gen_caspian.py`
Expected: prints `map_gen_caspian: skeleton OK`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add tools/map_gen_caspian.py
git commit -m "feat(map): conquest_caspian generator skeleton + PNG writers"
```

---

### Task 2: Flags, bases, roads → minimal valid map JSON + failing validation test

**Files:**
- Modify: `tools/map_gen_caspian.py`
- Create: `tests/map_caspian_test.gd`

- [ ] **Step 1: Write the failing validation test**

Create `tests/map_caspian_test.gd`:

```gdscript
extends TestCase
## Deterministic validation of the generated conquest_caspian map.
## Run: godot --headless --path . -- --test --filter=caspian

func _map() -> MapDef:
	return MapDef.load_file("res://maps/conquest_caspian.json")

func test_map_loads() -> void:
	var m := _map()
	assert_true(m != null, "conquest_caspian.json loads + validates")
	assert_eq(m.world_half, 500.0)

func test_five_flags_with_ownership() -> void:
	var m := _map()
	assert_eq(m.points.size(), 5, "five capture points")
	var by_id := {}
	for p in m.points:
		by_id[p["id"]] = p
	for id in ["A", "B", "C", "D", "E"]:
		assert_true(by_id.has(id), "flag %s present" % id)
	assert_eq(by_id["A"]["start_owner"], 0, "A owned by US")
	assert_eq(by_id["B"]["start_owner"], 0, "B owned by US")
	assert_eq(by_id["C"]["start_owner"], -1, "C neutral")
	assert_eq(by_id["D"]["start_owner"], 1, "D owned by RU")
	assert_eq(by_id["E"]["start_owner"], 1, "E owned by RU")

func test_two_team_bases() -> void:
	var m := _map()
	assert_false(m.base_for(0).is_empty(), "US base present")
	assert_false(m.base_for(1).is_empty(), "RU base present")
	# US north (−Z), RU south (+Z)
	assert_true(m.base_for(0)["pos"].z < 0.0, "US deploys north")
	assert_true(m.base_for(1)["pos"].z > 0.0, "RU deploys south")

func test_no_vehicle_spawns() -> void:
	var m := _map()
	assert_eq(m.vehicle_spawns.size(), 0, "vehicles deferred (AGENTS.md §12)")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . -- --test --filter=caspian`
Expected: FAIL — `conquest_caspian.json` doesn't exist yet (`_map()` returns null → `test_map_loads` fails; others fail on null deref/parse).

- [ ] **Step 3: Add flags/bases/roads + JSON emit to the generator**

In `tools/map_gen_caspian.py`, replace `main()` with the flags/bases/roads definitions and a JSON writer. Insert **before** `def main():`:

```python
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
    }
    return out

def write_map(out):
    path = os.path.join(ROOT, "maps", "conquest_caspian.json")
    json.dump(out, open(path, "w"), indent=2)
    print("wrote %s: %d buildings, %d roads, %d points, %d bases"
          % (path, len(out["buildings"]), len(out["roads"]),
             len(out["points"]), len(out["bases"])))
    return path
```

And replace `main()`:

```python
def main():
    out = build_map()
    write_map(out)

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Generate the map**

Run: `python3 tools/map_gen_caspian.py`
Expected: prints `wrote …/maps/conquest_caspian.json: 0 buildings, 7 roads, 5 points, 2 bases`.

- [ ] **Step 5: Import + run the test to verify it passes**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=caspian`
Expected: PASS — all four `test_*` in `map_caspian_test.gd` green.

- [ ] **Step 6: Commit**

```bash
git add tools/map_gen_caspian.py maps/conquest_caspian.json tests/map_caspian_test.gd
git commit -m "feat(map): conquest_caspian flags/bases/roads + validation test"
```

---

### Task 3: Heightmap + surface splatmap + terrain block

**Files:**
- Modify: `tools/map_gen_caspian.py`
- Modify: `tests/map_caspian_test.gd`

- [ ] **Step 1: Write the failing terrain test**

Append to `tests/map_caspian_test.gd`:

```gdscript
func test_has_terrain_block() -> void:
	var m := _map()
	assert_true(m.terrain.has("heightmap"), "map declares a heightmap")
	assert_eq(m.terrain["heightmap"], "heightmaps/conquest_caspian.png")
	assert_true(m.terrain.has("surface_map"), "map paints roads via a splatmap")
	assert_true(float(m.terrain["height_scale"]) > 0.0, "non-zero relief")

func test_terrain_grid_loads() -> void:
	var m := _map()
	var t := Terrain.load_for_map(m, "res://maps", func(_i): return {})
	assert_true(t != null, "Terrain builds from the heightmap")
	# Hilltop (D at [-45,74]) should read higher than the US base ([-34,-375]).
	var h_hill := t.height_at(-45.0, 74.0)
	var h_base := t.height_at(-34.0, -375.0)
	assert_true(h_hill > h_base, "Hilltop rises above the northern base")
```

> If `Terrain.load_for_map`'s signature differs, check `shared/sim/terrain.gd` and match it — the intent is "build the grid and query `height_at`".

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=caspian`
Expected: FAIL — `test_has_terrain_block` (no `terrain` key yet).

- [ ] **Step 3: Add the heightmap generator**

Insert into `tools/map_gen_caspian.py` before `def build_map()`:

```python
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
    hm += np.where(dh < 130.0, 26.0 * (1.0 - dh / 130.0) ** 1.4, 0.0)
    # low ridge near Antenna (east) — sniping perch
    dr = np.hypot(X - 170.0, Z + 80.0)
    hm += np.where(dr < 70.0, 9.0 * (1.0 - dr / 70.0), 0.0)
    # shallow river channel along the blue line: a poly-line of points, carve a trench
    river = [(-140, -500), (-120, -300), (-100, -60), (-70, 74),
             (-40, 160), (30, 300), (30, 500)]
    for i in range(len(river) - 1):
        ax, az = river[i]; bx, bz = river[i + 1]
        # distance from each cell to the segment (ax,az)-(bx,bz)
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
```

- [ ] **Step 4: Add the surface splatmap generator**

Insert before `def build_map()`:

```python
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
```

- [ ] **Step 5: Wire terrain artefacts into `build_map`/`main`**

Replace `build_map`'s `out` dict to add the terrain block, and extend `main` to write the PNGs. Update `build_map`:

```python
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
```

Replace `main`:

```python
def main():
    hm_dir = os.path.join(ROOT, "maps", "heightmaps")
    os.makedirs(hm_dir, exist_ok=True)
    px, n, hmin, hscale = gen_heightmap()
    _write_gray_png(os.path.join(hm_dir, "conquest_caspian.png"), n, n, px.tobytes())
    rgb, res = gen_surface_map(1024)
    _write_rgb_png(os.path.join(hm_dir, "conquest_caspian_surface.png"), res, res, rgb.tobytes())
    out = build_map()
    out["terrain"]["height_min"] = float(hmin)
    out["terrain"]["height_scale"] = float(hscale)
    write_map(out)
    print("heightmap %dx%d, height_min=%.1f height_scale=%.1f" % (n, n, hmin, hscale))

if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Regenerate + run the test**

Run: `python3 tools/map_gen_caspian.py && godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=caspian`
Expected: PASS — terrain tests green; Hilltop reads above the base.

- [ ] **Step 7: Commit**

```bash
git add tools/map_gen_caspian.py maps/conquest_caspian.json maps/heightmaps/conquest_caspian.png maps/heightmaps/conquest_caspian_surface.png tests/map_caspian_test.gd
git commit -m "feat(map): conquest_caspian heightmap + road splatmap + terrain block"
```

---

### Task 4: Per-flag buildings (existing prefabs) + overlap validation + baked footprints

**Files:**
- Modify: `tools/map_gen_caspian.py`
- Modify: `tests/map_caspian_test.gd`

- [ ] **Step 1: Write the failing buildings test**

Append to `tests/map_caspian_test.gd`:

```gdscript
func test_has_buildings_at_flags() -> void:
	var m := _map()
	assert_true(m.buildings.size() >= 8, "flags/bases have structures")
	# every building carries a baked footprint so pads flatten on the slope
	for b in m.buildings:
		assert_true(b.has("footprint"), "%s has a baked footprint" % b["prefab"])

func test_gas_station_prefab_present() -> void:
	var m := _map()
	var names := []
	for b in m.buildings:
		names.append(b["prefab"])
	assert_true(names.has("gas_station"), "Gas Station uses the gas_station prefab")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=caspian`
Expected: FAIL — `m.buildings` is empty.

- [ ] **Step 3: Add building placements + validation + footprint baking**

Insert into `tools/map_gen_caspian.py` before `def build_map()` a placement block. Place each prefab by its min world corner near the flag/base. (Prefab names verified present in `buildings/`.)

```python
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
    for b in buildings:                       # bake world-AABB footprint (pad flatten)
        x0, z0, x1, z1 = aabb(b)
        b["footprint"] = {"min_x": x0, "max_x": x1, "min_z": z0, "max_z": z1}
    for p in problems:
        print("  ! " + p)
    return problems
```

Call it from `main()` — insert `problems = validate_and_bake()` immediately **before** `out = build_map()`, and add `assert not problems, "fix building overlaps"` after `write_map(out)` is too late; instead print a clear count. Update `main()` to include:

```python
    problems = validate_and_bake()
    out = build_map()
    out["terrain"]["height_min"] = float(hmin)
    out["terrain"]["height_scale"] = float(hscale)
    write_map(out)
    print("heightmap %dx%d, height_min=%.1f height_scale=%.1f, %d overlap problems"
          % (n, n, hmin, hscale, len(problems)))
```

> If the generator prints any overlap problems, nudge the offending `place(...)` coordinates apart until it prints `0 overlap problems`. Prefab extents differ; treat the printed list as the authority.

- [ ] **Step 4: Regenerate until 0 overlaps**

Run: `python3 tools/map_gen_caspian.py`
Expected: ends with `… 0 overlap problems`. If not, adjust coordinates and re-run.

- [ ] **Step 5: Import + run the test**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=caspian`
Expected: PASS — buildings + gas_station present, all footprints baked.

- [ ] **Step 6: Commit**

```bash
git add tools/map_gen_caspian.py maps/conquest_caspian.json
git commit -m "feat(map): conquest_caspian per-flag buildings + overlap validation"
```

---

### Task 5: Destructible border wall (prebuilt blocks) with crossings, gate, breach

**Files:**
- Modify: `tools/map_gen_caspian.py`
- Modify: `tests/map_caspian_test.gd`

**Approach:** lay the wall as individual destructible `prebuilt[]` pieces (type `bwall`, structural + explosive/melee-damageable) along z≈0, stacked 2 cells high (~4.8 m) with a `brailing` cap (barbed wire) on top, skipping the crossing/gate/breach x-ranges. `prebuilt` pieces are placed straight into `StructureStore` at server start, so they ride the M11 destruction system with no new code.

- [ ] **Step 1: Write the failing wall test**

Append to `tests/map_caspian_test.gd`:

```gdscript
func test_border_wall_spans_with_openings() -> void:
	var m := _map()
	# collect wall pieces near the border line (z ~ 0), by cell z
	var border_cz := int(round(0.0 / 2.4))
	var xs := []
	for pb in m.prebuilt:
		if pb["type"] == "bwall" and int(pb["cell"].z) == border_cz:
			xs.append(int(pb["cell"].x))
	assert_true(xs.size() > 40, "wall is a long run of blocks (got %d)" % xs.size())
	xs.sort()
	# there must be gaps (openings): at least 3 breaks of >= 4 cells
	var gaps := 0
	for i in range(1, xs.size()):
		if xs[i] - xs[i - 1] >= 4:
			gaps += 1
	assert_true(gaps >= 3, "wall has >=3 openings (crossing+gate+breach), got %d" % gaps)

func test_wall_has_barbed_wire_cap() -> void:
	var m := _map()
	var has_rail := false
	for pb in m.prebuilt:
		if pb["type"] == "brailing":
			has_rail = true
			break
	assert_true(has_rail, "wall is capped with brailing (barbed wire)")
```

> `m.prebuilt` entries are `{type:String, cell:Vector3i}` (see `MapDef.from_dict`). `.cell.z` / `.cell.x` are ints.

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=caspian`
Expected: FAIL — no `prebuilt` wall yet.

- [ ] **Step 3: Add the wall generator**

Insert into `tools/map_gen_caspian.py` before `def build_map()`:

```python
# ---------------------------------------------------------------- border wall (prebuilt)
# A continuous run of destructible bwall blocks along z~0, 2 cells tall (~4.8 m) with a
# brailing cap (barbed wire), skipping openings. Cells: world x = cx*CELL, so the span
# x in [-300,300] -> cx in [-125,125]. Openings are world-x ranges.
prebuilt = []
def gen_border_wall():
    z_cell = int(round(0.0 / CELL))                      # border line at z=0
    x_lo, x_hi = -300.0, 300.0
    openings = [(-112.0, -82.0),    # B highway crossing
                (118.0, 148.0),     # A->E gate
                (-260.0, -244.0)]   # pre-existing breach
    def in_opening(xw):
        return any(lo <= xw <= hi for lo, hi in openings)
    cx = int(round(x_lo / CELL))
    cx_end = int(round(x_hi / CELL))
    while cx <= cx_end:
        xw = cx * CELL
        if not in_opening(xw):
            prebuilt.append({"type": "bwall", "cell": [cx, 0, z_cell]})   # base course
            prebuilt.append({"type": "bwall", "cell": [cx, 1, z_cell]})   # second course (~4.8 m)
            prebuilt.append({"type": "brailing", "cell": [cx, 2, z_cell]})# barbed-wire cap
        cx += 1
    return prebuilt

gen_border_wall()
```

Add `"prebuilt": prebuilt,` to the `out` dict in `build_map()`.

- [ ] **Step 4: Regenerate + run the test**

Run: `python3 tools/map_gen_caspian.py && godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=caspian`
Expected: PASS — long wall run, ≥3 openings, brailing cap present.

- [ ] **Step 5: Sanity-check the wall doesn't wall a base or bury a flag**

Run: `python3 tools/map_gen_caspian.py`
Expected: `0 overlap problems` (buildings vs buildings). The wall is `prebuilt`, not in the overlap check — visually confirm in the fleet gate (Task 10) that the crossing/gate/breach line up with the roads (B highway at x≈−97 sits inside the [−112,−82] opening; the A→E road at x≈133 sits inside [118,148]).

- [ ] **Step 6: Commit**

```bash
git add tools/map_gen_caspian.py maps/conquest_caspian.json tests/map_caspian_test.gd
git commit -m "feat(map): conquest_caspian destructible border wall + crossings/gate/breach"
```

---

### Task 6: Antenna vantage — ladder + platform (Phase-1 minimum)

**Files:**
- Modify: `tools/map_gen_caspian.py`
- Modify: `tests/map_caspian_test.gd`

Phase-1 gives the Antenna a simple climbable vantage: a `platform` deck reached by a `ladder`, so the "vertical gameplay" exists before the bespoke tower polish in Phase 2. Uses `MapDef.ladders[]` + `MapDef.platforms[]` (both validated; ladders auto-shift onto terrain by `Terrain.load_for_map`).

- [ ] **Step 1: Write the failing ladder test**

Append to `tests/map_caspian_test.gd`:

```gdscript
func test_antenna_has_climbable_vantage() -> void:
	var m := _map()
	assert_true(m.ladders.size() >= 1, "Antenna has a ladder")
	assert_true(m.platforms.size() >= 1, "Antenna has a platform deck")
	# ladder top height matches a platform top (a reachable deck)
	var lad = m.ladders[0]
	assert_true(lad["top"].y > lad["bottom"].y + 3.0, "ladder climbs >3 m")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=caspian`
Expected: FAIL — no ladders/platforms.

- [ ] **Step 3: Add an antenna platform + ladder**

Insert into `tools/map_gen_caspian.py` before `def build_map()`:

```python
# ---------------------------------------------------------------- antenna vantage
# A raised deck beside the Antenna flag (170,-80), reached by a ladder. Heights are
# relative to y=0; Terrain.load_for_map shifts ladders/platforms onto the local grade.
ladders = [
    {"bottom": [176, 0, -84], "top": [176, 6.0, -84], "radius": 0.6, "yaw": 0.0, "building": -1},
]
platforms = [
    {"min": [173, 6.0, -87], "max": [181, 6.6, -79]},
]
```

Add `"ladders": ladders,` (replace the empty one) and `"platforms": platforms,` to the `out` dict in `build_map()`.

- [ ] **Step 4: Regenerate + run the test**

Run: `python3 tools/map_gen_caspian.py && godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=caspian`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/map_gen_caspian.py maps/conquest_caspian.json tests/map_caspian_test.gd
git commit -m "feat(map): conquest_caspian antenna climbable vantage (ladder+deck)"
```

---

### Task 7: Scenery — forest trees + rock formations

**Files:**
- Modify: `tools/map_gen_caspian.py`
- Modify: `tests/map_caspian_test.gd`

- [ ] **Step 1: Confirm scenery ids**

Run: `python3 -c "import json;d=json.load(open('data/scenery_catalog.json'));print(list(d['items'].keys())[:12] if isinstance(d.get('items'),dict) else d['items'][:6])"`
Expected: prints tree/rock ids (e.g. `tree_type1_*`, `rock_type1_*`). Use the actual ids printed; the code below assumes `tree_type1` and `rock_type1` — replace with real ids if different.

- [ ] **Step 2: Write the failing scenery test**

Append to `tests/map_caspian_test.gd`:

```gdscript
func test_has_scenery() -> void:
	var m := _map()
	assert_true(m.scenery.size() >= 20, "forest + rocks placed (got %d)" % m.scenery.size())
	var kinds := {"tree": 0, "rock": 0}
	for s in m.scenery:
		if String(s["id"]).begins_with("tree"): kinds["tree"] += 1
		if String(s["id"]).begins_with("rock"): kinds["rock"] += 1
	assert_true(kinds["tree"] > 0 and kinds["rock"] > 0, "both trees and rocks present")
```

- [ ] **Step 3: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=caspian`
Expected: FAIL — `m.scenery` empty.

- [ ] **Step 4: Add scenery generation (deterministic, no RNG that breaks resume)**

Insert into `tools/map_gen_caspian.py` before `def build_map()`. Uses a fixed integer lattice + hash jitter so it's fully deterministic:

```python
# ---------------------------------------------------------------- scenery (trees + rocks)
scenery = []
def _jit(i, span):
    return ((i * 2654435761) % 1000) / 1000.0 * span - span / 2.0

def scatter_trees(cx, cz, rx, rz, count, base_id="tree_type1"):
    for i in range(count):
        x = cx + _jit(i * 3 + 1, rx * 2)
        z = cz + _jit(i * 3 + 2, rz * 2)
        yaw = (i * 40 % 360) * 3.14159 / 180.0
        scenery.append({"id": base_id, "pos": [round(x, 1), 0, round(z, 1)],
                        "yaw": round(yaw, 3), "scale": 1.0 + _jit(i * 3 + 3, 0.6)})

def scatter_rocks(cx, cz, r, count, base_id="rock_type1"):
    for i in range(count):
        x = cx + _jit(i * 5 + 1, r * 2)
        z = cz + _jit(i * 5 + 2, r * 2)
        scenery.append({"id": base_id, "pos": [round(x, 1), 0, round(z, 1)],
                        "yaw": round((i * 55 % 360) * 3.14159 / 180.0, 3),
                        "scale": 0.8 + _jit(i * 5 + 3, 0.8)})

# Forest masses (C centre + map edges), rock rings (Antenna, Hilltop, near RU/US)
scatter_trees(51, 34, 70, 55, 40)        # Forest C
scatter_trees(230, 60, 90, 160, 30)      # east treeline
scatter_trees(-260, -120, 120, 140, 25)  # west/north woods
scatter_rocks(170, -80, 34, 14)          # Antenna ring
scatter_rocks(-45, 74, 30, 12)           # Hilltop crown
scatter_rocks(-300, 360, 40, 8)          # near RU
scatter_rocks(-34, -320, 40, 6)          # near US
```

Add `"scenery": scenery,` (replace the empty one) to the `out` dict in `build_map()`.

- [ ] **Step 5: Regenerate + run the test**

Run: `python3 tools/map_gen_caspian.py && godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=caspian`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/map_gen_caspian.py maps/conquest_caspian.json tests/map_caspian_test.gd
git commit -m "feat(map): conquest_caspian forest + rock scenery"
```

---

### Task 8: Register the map + extend the shipping-map vehicle guard

**Files:**
- Modify: `data/server_config.example.json:6`
- Modify: `tests/map_def_test.gd:89-93`

- [ ] **Step 1: Add `conquest_caspian` to the no-vehicle-spawns guard**

In `tests/map_def_test.gd`, edit `test_shipping_maps_have_no_vehicle_spawns` (line ~90) to include the new map:

```gdscript
func test_shipping_maps_have_no_vehicle_spawns() -> void:
	for name in ["conquest_town", "conquest_suburb", "conquest_proving_grounds", "conquest_arena_buildings", "conquest_caspian"]:
		var m := MapDef.load_file("res://maps/%s.json" % name)
		assert_true(m != null, "%s loads" % name)
		assert_eq(m.vehicle_spawns.size(), 0, "%s ships with no vehicle spawns (vehicles deferred)" % name)
```

- [ ] **Step 2: Run the guard test to verify it passes**

Run: `godot --headless --path . -- --test --filter=map_def`
Expected: PASS — `test_shipping_maps_have_no_vehicle_spawns` includes and passes `conquest_caspian`.

- [ ] **Step 3: Add the map to the server rotation**

In `data/server_config.example.json`, line 6, add `conquest_caspian` to the `maps` array:

```json
  "maps": ["conquest_town", "conquest_proving_grounds", "conquest_arena_buildings", "conquest_caspian"],
```

- [ ] **Step 4: Commit**

```bash
git add tests/map_def_test.gd data/server_config.example.json
git commit -m "feat(map): register conquest_caspian in rotation + shipping-map guard"
```

---

### Task 9: Full deterministic suite green + generator idempotency

**Files:** (none new)

- [ ] **Step 1: Run the entire test suite**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test`
Expected: `TESTS: <N> run, 0 failed`. If anything regressed, fix before proceeding.

- [ ] **Step 2: Verify the generator is idempotent (reproducible)**

Run:
```bash
python3 tools/map_gen_caspian.py
git diff --stat maps/conquest_caspian.json maps/heightmaps/conquest_caspian.png maps/heightmaps/conquest_caspian_surface.png
```
Expected: **no diff** — re-running produces byte-identical artefacts (deterministic; no RNG/time).

- [ ] **Step 3: Commit (if the suite run touched .uid/.import metadata)**

```bash
git add -A
git commit -m "chore(map): conquest_caspian suite green + idempotent generator" || echo "nothing to commit"
```

---

### Task 10: 128-bot fleet gate on game2 (evidence-recorded)

**Files:**
- Create: `docs/gate-evidence/<timestamp>-conquest-caspian.txt` (paste the server summary line)

**This is the hard gate (AGENTS.md §6/§8). Run locally on game2, server pinned to P-cores (§8).**

- [ ] **Step 1: Local smoke first (≤48 bots)**

Run: `MAP=conquest_caspian ci/m3_conquest_test.sh` (or the nearest conquest smoke script; pass `--map=conquest_caspian` to server + bots — check the script's env plumbing).
Expected: a full conquest match reaches a winner, `script_errors=0`, no map-load error.

- [ ] **Step 2: 128-bot Docker fleet gate**

Run (game2, P-core pinned): `SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 MAP=conquest_caspian BOT_REPLICAS=16 BOT_COUNT=8 docker/run-m11-gate.sh` (use the current gate script; confirm it plumbs `MAP`).
Expected: `winner=0|1`, `peak tick < 33.3 ms`, `script_errors=0`, `cap_events > 0`, `elapsed < 900 s`. Watch `struct=<piece count>` — with the border wall this is higher than `conquest_town`; if `peak tick` approaches 33 ms, coarsen the wall (drop the second course or widen the block step to every-other cell in `gen_border_wall`) and re-run.

- [ ] **Step 3: Record evidence**

Save the server summary line + log path to `docs/gate-evidence/<YYYYMMDD-HHMMSS>-conquest-caspian.txt` and commit.

```bash
git add docs/gate-evidence/*conquest-caspian*.txt
git commit -m "gate(map): conquest_caspian 128-bot fleet gate PASS + evidence"
```

- [ ] **Step 4: Land Phase 1**

Follow AGENTS.md §11: `git fetch origin` → reconcile → merge/ff to `master` → `git push origin master`. Phase 1 is a shippable, gated map.

---

## PHASE 2 — landmark polish (after Phase 1 is gated)

> These refine visual/gameplay fidelity against the reference image. Each is a small increment; keep the map playable (regenerate + `--filter=caspian` green) after each.

### Task 11: Bespoke climbable Antenna tower

**Files:** Create `buildings/antenna_tower.json` (assembled from `bcolumn` mast + `bfloor` decks + `brailing` + `bstair`/ladder); modify `tools/map_gen_caspian.py` to `place("antenna_tower", …)` at A and add the lower/upper platform decks + ladders; extend `test_antenna_has_climbable_vantage` to assert two platform tiers.

- [ ] Author `buildings/antenna_tower.json` following the `guardhouse.json` piece format (`{type, offset:[x,y,z], yaw}`), a ~3-cell-tall mast with two `bfloor` decks (lower + upper) railed with `brailing`.
- [ ] Replace the Task-6 stopgap platform/ladder with the tower + two ladders (ground→lower, lower→upper).
- [ ] Regenerate; `--filter=caspian` green; commit.

### Task 12: Destructible water tower, radio tower, gate, cargo containers

**Files:** modify `tools/map_gen_caspian.py`.

- [ ] **Water tower (E):** replace the `silo` stopgap with a raised tank — `bfloor` deck on `bcolumn` legs, `silo`-style `bwall_metal` drum on top. Destructible (it "can be brought down").
- [ ] **Radio tower (D):** a slim `bcolumn`/`brailing` mast on the Hilltop, destructible.
- [ ] **Gate (A→E crossing):** at world x≈133, z≈0, place a short authored span using `bwall_door`/`bwall_garage` pieces (passable) flanked by `bwall` posts, inside the [118,148] wall opening.
- [ ] **Cargo containers (B):** stacks of `heavy_barricade` / `prop_crate` around the border post for cover.
- [ ] Regenerate; `--filter=caspian` green; commit each landmark separately.

### Task 13: Owner feel-gate playtest

**Files:** session log under `docs/sessions/`.

- [ ] Run the map on the desktop client (server + bots on game2, client on the home laptop — see [[blockfire-playtest-deploy-pattern]]). Verify: the border-wall funnel-then-breach arc reads right; flags feel Caspian; terrain gives cover; Hilltop commands; landmarks recognisable against `caspian_drawing.png`.
- [ ] Log findings; fold quick fixes into the generator; defer bot-AI *feel* items to M7.5 (AGENTS.md §10).

---

## Self-review notes (spec coverage)

- **Scale 500/1000 m** → Task 2/3 (`WORLD_HALF=500`, heightmap n=501). ✅
- **5 flags + ownership (US A+B / RU D+E / C neutral)** → Task 2 + `test_five_flags_with_ownership`. ✅
- **Two deployments near owned flags** → Task 2 bases. ✅
- **Heightmap Hilltop/ridges/river + splatmap roads** → Task 3. ✅
- **Fully-destructible border wall + B crossing + gate + breach** → Task 5 (wall + openings) + Task 12 (gate). ✅
- **Per-flag buildings incl. Forest-no-emplacement + gas_station** → Task 4. ✅
- **Antenna climbable vantage** → Task 6 (min) + Task 11 (bespoke). ✅
- **Scenery forest + rocks** → Task 7. ✅
- **Register + vehicle guard** → Task 8. ✅
- **Deterministic tests + 128-bot fleet gate + owner feel-gate** → Tasks 9/10/13. ✅
- **Vehicles deferred (empty spawns)** → Task 2 + Task 8 guard. ✅
- **Open questions (relief tuning / wall budget / gate)** → Tasks 3/5/10 carry explicit tune-at-the-gate steps. ✅

**Type/name consistency:** generator uses `place/extent/aabb/overlap/validate_and_bake`, `gen_heightmap/gen_surface_map/gen_border_wall`, module lists `points/bases/roads/buildings/prebuilt/ladders/platforms/scenery`; tests reference `MapDef` fields (`points/bases/buildings/prebuilt/ladders/platforms/scenery/terrain/vehicle_spawns`) exactly as defined in `shared/sim/map_def.gd`. Prebuilt cell access uses `Vector3i` `.x/.z` per `from_dict`. ✅
