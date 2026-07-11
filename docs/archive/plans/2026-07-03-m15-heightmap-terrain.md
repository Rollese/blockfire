# M15: Heightmap Terrain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Blockfire maps real elevation — a 2 m-spaced, bilinearly-interpolated heightmap grid that pawns/vehicles walk/drive on, that blocks bullets and LOS like real cover, that gates too-steep slopes, that composes with buildings (auto-flatten pads) and tunnels (terrain cutouts) — proven on a retrofitted `conquest_proving_grounds`.

**Architecture:** A new pure `TerrainGrid` (data) + `Terrain` (height/slope/movement queries) pair in `shared/sim/`, following the exact pattern `structure.gd`/`stairs.gd` already established for M11/M14. Terrain height becomes one more term in `SimLoop._apply_platform_floor`'s existing `maxf(...)` floor-resolution chain (the seam M14 built), a member on `StructureStore` for `march()` LOS/bullet occlusion, and a member on `SimLoop` for movement/slope-blocking. Both server and client load the same heightmap PNG locally via `MapDef` — no wire-protocol change.

**Tech Stack:** GDScript (Godot 4.6, headless server + client), pure-stdlib Python 3 for map tooling (no new deps, matches `tools/map_gen.py`).

---

## Task 1: TerrainGrid data structure

**Files:**
- Create: `shared/sim/terrain_grid.gd`
- Test: `tests/terrain_grid_test.gd`

- [ ] **Step 1: Write the failing tests**

```gdscript
extends TestCase
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

func test_dim_covers_half_extent() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	assert_eq(g.dim, 5, "8m span / 2m spacing + 1 = 5 samples per axis")

func test_sample_defaults_to_zero() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	assert_eq(g.sample(2, 2), 0.0, "unset samples default to flat (0.0)")

func test_set_and_get_sample() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	g.set_sample(2, 2, 5.5)
	assert_almost_eq(g.sample(2, 2), 5.5, 0.001)

func test_sample_clamps_out_of_range_reads() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	g.set_sample(0, 0, 3.0)
	assert_almost_eq(g.sample(-5, -5), 3.0, 0.001, "reads clamp to the grid edge, never crash")

func test_set_sample_ignores_out_of_range_writes() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	g.set_sample(-1, -1, 9.0)   # must not crash / must not alias into a valid cell
	assert_eq(g.sample(0, 0), 0.0)

func test_grid_coord_maps_origin_to_centre() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	var gc := g.grid_coord(0.0, 0.0)
	assert_almost_eq(gc.x, 2.0, 0.001, "world origin is the centre column")
	assert_almost_eq(gc.y, 2.0, 0.001, "world origin is the centre row")

func test_grid_coord_maps_positive_x_to_higher_column() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	var gc := g.grid_coord(2.0, 0.0)
	assert_almost_eq(gc.x, 3.0, 0.001)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_grid_test`
Expected: FAIL with "file failed to parse" (terrain_grid.gd doesn't exist yet).

- [ ] **Step 3: Implement TerrainGrid**

```gdscript
class_name TerrainGrid
extends RefCounted
## Heightmap sample grid: one float sample every `spacing` metres, covering
## [-half_extent, half_extent] on both axes. Height/slope queries live in the pure
## shared/sim/terrain.gd (kept separate so query math has no file-IO dependency).
## A null TerrainGrid means "flat, height 0" everywhere — every caller in this milestone
## treats null gracefully so maps without terrain behave exactly as before. See
## docs/specs/heightmap-terrain.md.

var spacing: float = 2.0
var half_extent: float = 0.0     # world_half this grid covers
var dim: int = 0                 # samples per axis (odd, centred on world x=0/z=0)
var samples: PackedFloat32Array = PackedFloat32Array()   # row-major, dim*dim; index = row*dim+col

func _init(p_spacing: float = 2.0, p_half_extent: float = 0.0) -> void:
	spacing = p_spacing
	half_extent = p_half_extent
	dim = int(round((p_half_extent * 2.0) / p_spacing)) + 1
	samples.resize(dim * dim)

## World (x,z) -> fractional grid coordinate (col,row). Not clamped (used by height_at's
## bilinear interpolation, which clamps at the sample level instead).
func grid_coord(x: float, z: float) -> Vector2:
	return Vector2((x + half_extent) / spacing, (z + half_extent) / spacing)

## Sample at integer (col,row), clamped to the grid so callers never index out of bounds.
func sample(col: int, row: int) -> float:
	var c := clampi(col, 0, dim - 1)
	var r := clampi(row, 0, dim - 1)
	return samples[r * dim + c]

## Write a sample; out-of-range writes are silently dropped (defensive — callers computing
## a footprint near the grid edge shouldn't need their own bounds checks).
func set_sample(col: int, row: int, h: float) -> void:
	if col < 0 or col >= dim or row < 0 or row >= dim:
		return
	samples[row * dim + col] = h
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_grid_test`
Expected: `TESTS: 7 run, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add shared/sim/terrain_grid.gd tests/terrain_grid_test.gd
git commit -m "feat(terrain): TerrainGrid heightmap sample storage (M15)"
```

---

## Task 2: TerrainGrid PNG heightmap loader

**Files:**
- Modify: `shared/sim/terrain_grid.gd`
- Modify: `tests/terrain_grid_test.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/terrain_grid_test.gd`:

```gdscript
func test_load_png_round_trips_height_values() -> void:
	var dim := 5
	var img := Image.create(dim, dim, false, Image.FORMAT_L8)
	for row in dim:
		for col in dim:
			img.set_pixel(col, row, Color(float(row) / float(dim - 1), 0.0, 0.0))
	var tmp := "user://terrain_grid_test_tmp.png"
	img.save_png(tmp)
	var g := TerrainGrid.load_png(tmp, 2.0, 4.0, 0.0, 20.0)
	assert_eq(g.dim, dim)
	assert_almost_eq(g.sample(0, 0), 0.0, 0.5, "row 0 (black) -> height_min")
	assert_almost_eq(g.sample(0, dim - 1), 20.0, 0.5, "last row (white) -> height_min+height_scale")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

func test_load_png_missing_file_logs_error_and_returns_flat() -> void:
	tolerate_runtime_errors()
	var g := TerrainGrid.load_png("user://does_not_exist_terrain.png", 2.0, 4.0, 0.0, 20.0)
	assert_eq(g.dim, 5, "still a valid, correctly-sized flat grid")
	assert_eq(g.sample(2, 2), 0.0)

func test_load_png_size_mismatch_logs_error_and_returns_flat() -> void:
	tolerate_runtime_errors()
	var img := Image.create(3, 3, false, Image.FORMAT_L8)   # wrong size for spacing=2.0, half_extent=4.0 (expects 5x5)
	var tmp := "user://terrain_grid_test_wrong_size.png"
	img.save_png(tmp)
	var g := TerrainGrid.load_png(tmp, 2.0, 4.0, 0.0, 20.0)
	assert_eq(g.dim, 5, "falls back to a correctly-sized flat grid rather than crashing")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_grid_test`
Expected: FAIL — `Invalid call. Nonexistent function 'load_png'`.

- [ ] **Step 3: Implement the loader**

Append to `shared/sim/terrain_grid.gd`:

```gdscript
## Build a grid from a grayscale PNG (pixel dimensions must be exactly dim x dim for the given
## spacing/half_extent — the map's heightmap generator produces the right size by construction).
## Pixel luminance 0..1 maps linearly to [height_min, height_min+height_scale]. Missing file or a
## size mismatch logs an error and returns a valid, correctly-sized flat (all-zero) grid rather
## than crashing the map load.
static func load_png(path: String, spacing: float, world_half: float, height_min: float, height_scale: float) -> TerrainGrid:
	var g := TerrainGrid.new(spacing, world_half)
	var img := Image.load_from_file(path)
	if img == null:
		push_error("[terrain] heightmap not found or unreadable: %s" % path)
		return g
	img.convert(Image.FORMAT_L8)
	if img.get_width() != g.dim or img.get_height() != g.dim:
		push_error("[terrain] heightmap %s is %dx%d, expected %dx%d (spacing=%.2f world_half=%.2f)" %
			[path, img.get_width(), img.get_height(), g.dim, g.dim, spacing, world_half])
		return g
	for row in g.dim:
		for col in g.dim:
			var lum := img.get_pixel(col, row).r   # 0..1
			g.samples[row * g.dim + col] = height_min + lum * height_scale
	return g
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_grid_test`
Expected: `TESTS: 10 run, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add shared/sim/terrain_grid.gd tests/terrain_grid_test.gd
git commit -m "feat(terrain): TerrainGrid.load_png grayscale heightmap loader (M15)"
```

---

## Task 3: Terrain.height_at (bilinear query)

**Files:**
- Create: `shared/sim/terrain.gd`
- Create: `tests/terrain_test.gd`

- [ ] **Step 1: Write the failing tests**

```gdscript
extends TestCase
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")
const Terrain := preload("res://shared/sim/terrain.gd")

func test_null_grid_is_flat() -> void:
	assert_eq(Terrain.height_at(null, 5.0, -3.0), 0.0)

func test_height_at_grid_point_matches_sample() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	g.set_sample(3, 2, 6.0)   # col 3 -> world x=2.0; row 2 -> world z=0.0
	assert_almost_eq(Terrain.height_at(g, 2.0, 0.0), 6.0, 0.01)

func test_height_at_interpolates_midpoint() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	g.set_sample(2, 2, 0.0)    # world (0,0)
	g.set_sample(3, 2, 10.0)   # world (2,0)
	assert_almost_eq(Terrain.height_at(g, 1.0, 0.0), 5.0, 0.01, "halfway between two samples")

func test_height_at_interpolates_both_axes() -> void:
	var g := TerrainGrid.new(2.0, 4.0)
	g.set_sample(2, 2, 0.0)    # (0,0)
	g.set_sample(3, 2, 10.0)   # (2,0)
	g.set_sample(2, 3, 10.0)   # (0,2)
	g.set_sample(3, 3, 20.0)   # (2,2)
	assert_almost_eq(Terrain.height_at(g, 1.0, 1.0), 10.0, 0.01, "centre of the four samples")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_test`
Expected: FAIL — file failed to parse (terrain.gd doesn't exist).

- [ ] **Step 3: Implement height_at**

```gdscript
class_name Terrain
extends Object
## Pure terrain height/slope/movement queries over a TerrainGrid. A null grid means "flat,
## height 0" — every query degrades gracefully so maps without terrain behave exactly as before
## this milestone. Side-effect-free; shared by server + client. See docs/specs/heightmap-terrain.md.

## Bilinear-interpolated height at world (x,z). 0.0 if grid is null (flat fallback).
static func height_at(grid: TerrainGrid, x: float, z: float) -> float:
	if grid == null:
		return 0.0
	var gc := grid.grid_coord(x, z)
	var c0 := int(floor(gc.x))
	var r0 := int(floor(gc.y))
	var fx := clampf(gc.x - c0, 0.0, 1.0)
	var fz := clampf(gc.y - r0, 0.0, 1.0)
	var h00 := grid.sample(c0, r0)
	var h10 := grid.sample(c0 + 1, r0)
	var h01 := grid.sample(c0, r0 + 1)
	var h11 := grid.sample(c0 + 1, r0 + 1)
	var hx0 := lerpf(h00, h10, fx)
	var hx1 := lerpf(h01, h11, fx)
	return lerpf(hx0, hx1, fz)
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_test`
Expected: `TESTS: 4 run, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add shared/sim/terrain.gd tests/terrain_test.gd
git commit -m "feat(terrain): Terrain.height_at bilinear query (M15)"
```

---

## Task 4: Terrain.slope_at + Terrain.resolve_movement (slope blocking)

**Files:**
- Modify: `shared/sim/terrain.gd`
- Modify: `tests/terrain_test.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/terrain_test.gd`:

```gdscript
func test_slope_at_flat_terrain_is_zero() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	assert_almost_eq(Terrain.slope_at(g, 0.0, 0.0), 0.0, 0.1)

func test_slope_at_null_grid_is_zero() -> void:
	assert_almost_eq(Terrain.slope_at(null, 5.0, 5.0), 0.0, 0.001)

func test_slope_at_detects_a_steep_ramp() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, wx)   # 1 m rise per 1 m run -> 45 degrees everywhere
	assert_almost_eq(Terrain.slope_at(g, 0.0, 0.0), 45.0, 2.0)

func test_resolve_movement_passes_gentle_slope() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, wx * 0.1)   # ~6 degree slope
	var to := Terrain.resolve_movement(g, Vector3(0, 0, 0), Vector3(1, 0, 0))
	assert_eq(to, Vector3(1, 0, 0), "gentle slope is not blocked")

func test_resolve_movement_blocks_a_cliff() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, wx)   # 45 degree everywhere, well above MAX_WALKABLE_SLOPE_DEG? no -- lower it
	# 45 deg is below the 50 deg default limit; make it near-vertical instead.
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, wx * 8.0)   # ~83 degrees, well above the limit
	var to := Terrain.resolve_movement(g, Vector3(0, 0, 0), Vector3(1, 0, 0))
	assert_eq(to, Vector3(0, 0, 0), "both axes blocked (uniform cliff in every direction) -> stay put")

func test_resolve_movement_slides_along_a_one_directional_cliff() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, maxf(0.0, wx * 8.0))   # steep only toward +x; flat toward +z at x<=0
	# Moving diagonally (+x,+z) from origin: the +x component is blocked, the +z slide should pass.
	var to := Terrain.resolve_movement(g, Vector3(0, 0, 0), Vector3(1, 0, 1))
	assert_eq(to, Vector3(0, 0, 1), "x component blocked by the cliff; z slide-through succeeds")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_test`
Expected: FAIL — `Nonexistent function 'slope_at'`.

- [ ] **Step 3: Implement slope_at + resolve_movement**

Append to `shared/sim/terrain.gd`:

```gdscript
const MAX_WALKABLE_SLOPE_DEG := 50.0
const _SLOPE_PROBE := 0.5   # m; half-step for the central-difference gradient sample

## Local slope angle (degrees) at (x,z) via a central-difference gradient of height_at itself —
## continuous everywhere, not a per-grid-cell/per-edge value.
static func slope_at(grid: TerrainGrid, x: float, z: float) -> float:
	if grid == null:
		return 0.0
	var dhdx := (height_at(grid, x + _SLOPE_PROBE, z) - height_at(grid, x - _SLOPE_PROBE, z)) / (2.0 * _SLOPE_PROBE)
	var dhdz := (height_at(grid, x, z + _SLOPE_PROBE) - height_at(grid, x, z - _SLOPE_PROBE)) / (2.0 * _SLOPE_PROBE)
	var grad := sqrt(dhdx * dhdx + dhdz * dhdz)
	return rad_to_deg(atan(grad))

## Horizontal movement blocker: clips the disallowed component of `to` if its column's slope
## exceeds MAX_WALKABLE_SLOPE_DEG, sliding along the slope face instead of climbing it — same
## axis-separated shape as StructureStore.resolve_movement. y is preserved; SimLoop's floor
## resolution settles it afterward. Covers walking, jumping (jump only adds vertical velocity —
## horizontal advance still runs through this), and vehicles (same call from step_vehicles).
static func resolve_movement(grid: TerrainGrid, from: Vector3, to: Vector3) -> Vector3:
	if grid == null or slope_at(grid, to.x, to.z) <= MAX_WALKABLE_SLOPE_DEG:
		return to
	var try_x := Vector3(to.x, to.y, from.z)
	if slope_at(grid, try_x.x, try_x.z) <= MAX_WALKABLE_SLOPE_DEG:
		return try_x
	var try_z := Vector3(from.x, to.y, to.z)
	if slope_at(grid, try_z.x, try_z.z) <= MAX_WALKABLE_SLOPE_DEG:
		return try_z
	return Vector3(from.x, to.y, from.z)
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_test`
Expected: `TESTS: 9 run, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add shared/sim/terrain.gd tests/terrain_test.gd
git commit -m "feat(terrain): Terrain.slope_at + resolve_movement slope blocking (M15)"
```

---

## Task 5: MapDef.terrain field + PNG loading in load_file

**Files:**
- Modify: `shared/sim/map_def.gd`
- Modify: `tests/map_def_test.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/map_def_test.gd` (adjust the exact `const MapDef := preload(...)` / helper names to match whatever this file already uses for a minimal valid map dict):

```gdscript
func test_terrain_field_is_optional() -> void:
	var res := MapDef.from_dict({
		"name": "t", "world_half": 20.0,
		"points": [{"id": "a", "pos": [0, 0, 0], "radius": 5, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
	})
	assert_true(bool(res["ok"]))
	var m: MapDef = res["map"]
	assert_eq(m.terrain_heightmap, "", "no terrain block -> empty heightmap path, terrain stays null")
	assert_eq(m.terrain, null)

func test_terrain_field_parses() -> void:
	var res := MapDef.from_dict({
		"name": "t", "world_half": 20.0,
		"points": [{"id": "a", "pos": [0, 0, 0], "radius": 5, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
		"terrain": {"heightmap": "heightmaps/t.png", "sample_spacing": 2.0, "height_min": -5.0, "height_scale": 30.0},
	})
	assert_true(bool(res["ok"]))
	var m: MapDef = res["map"]
	assert_eq(m.terrain_heightmap, "heightmaps/t.png")
	assert_almost_eq(m.terrain_height_min, -5.0, 0.001)
	assert_almost_eq(m.terrain_height_scale, 30.0, 0.001)

func test_terrain_field_requires_heightmap_path() -> void:
	var res := MapDef.from_dict({
		"name": "t", "world_half": 20.0,
		"points": [{"id": "a", "pos": [0, 0, 0], "radius": 5, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
		"terrain": {"sample_spacing": 2.0},
	})
	assert_false(bool(res["ok"]), "terrain block without a heightmap path is invalid")

func test_load_file_populates_terrain_grid() -> void:
	var dim := 21   # world_half=20, spacing=2.0 -> dim = 20*2/2+1 = 21
	var img := Image.create(dim, dim, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5))
	var map_dir := "user://m15_map_def_test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(map_dir + "/heightmaps"))
	img.save_png(map_dir + "/heightmaps/t.png")
	var json_text := JSON.stringify({
		"name": "t", "world_half": 20.0,
		"points": [{"id": "a", "pos": [0, 0, 0], "radius": 5, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
		"terrain": {"heightmap": "heightmaps/t.png", "sample_spacing": 2.0, "height_min": 0.0, "height_scale": 10.0},
	})
	var f := FileAccess.open(map_dir + "/t.json", FileAccess.WRITE)
	f.store_string(json_text)
	f.close()
	var m := MapDef.load_file(map_dir + "/t.json")
	assert_true(m != null)
	assert_true(m.terrain != null, "load_file populates the TerrainGrid from the referenced PNG")
	assert_almost_eq(m.terrain.sample(10, 10), 5.0, 0.5, "mid-gray -> mid-range height")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(map_dir + "/heightmaps/t.png"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(map_dir + "/t.json"))
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=map_def_test`
Expected: FAIL — `Invalid get index 'terrain_heightmap'`.

- [ ] **Step 3: Implement**

In `shared/sim/map_def.gd`, add fields near the top (after `var vehicle_spawns`):

```gdscript
var terrain_heightmap: String = ""     # relative path, e.g. "heightmaps/proving_grounds.png"
var terrain_sample_spacing: float = 2.0
var terrain_height_min: float = 0.0
var terrain_height_scale: float = 0.0
var terrain: TerrainGrid = null        # populated by load_file() only (needs a base directory)
```

In `from_dict`, add parsing before `return {"ok": true, ...}`:

```gdscript
	if data.has("terrain"):
		var t = data["terrain"]
		if not (t is Dictionary) or not t.has("heightmap"):
			return {"ok": false, "map": null, "error": "terrain needs a heightmap path"}
		m.terrain_heightmap = String(t["heightmap"])
		m.terrain_sample_spacing = float(t.get("sample_spacing", 2.0))
		m.terrain_height_min = float(t.get("height_min", 0.0))
		m.terrain_height_scale = float(t.get("height_scale", 0.0))
```

Replace `load_file`:

```gdscript
static func load_file(path: String) -> MapDef:
	if not FileAccess.file_exists(path):
		push_error("[map] not found: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var res := from_json_string(text)
	if not res["ok"]:
		push_error("[map] invalid %s: %s" % [path, res["error"]])
		return null
	var m: MapDef = res["map"]
	if m.terrain_heightmap != "":
		var base_dir := path.get_base_dir()
		m.terrain = TerrainGrid.load_png(base_dir.path_join(m.terrain_heightmap),
			m.terrain_sample_spacing, m.world_half, m.terrain_height_min, m.terrain_height_scale)
	return m
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=map_def_test`
Expected: all map_def_test cases pass, including the 4 new ones.

- [ ] **Step 5: Run the full suite to confirm no regression**

Run: `godot --headless --path . -- --test`
Expected: all existing tests still pass (terrain field is optional; every current map JSON is unaffected).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/map_def.gd tests/map_def_test.gd
git commit -m "feat(terrain): MapDef.terrain field + heightmap load in load_file (M15)"
```

---

## Task 6: Ladder.platform_floor ground_y baseline

**Why this task exists:** `_apply_platform_floor` composes floor sources via `maxf(...)`, but `Ladder.platform_floor`'s own internal fallback is a **hardcoded `0.0`** ("ground"), not a parameter. Folding terrain in naively via an outer `maxf(terrain_height, Ladder.platform_floor(...))` would be wrong for a valley (negative terrain height) — the hardcoded `0.0` inside `platform_floor` would always win over a legitimately lower terrain floor. `platform_floor` needs to take the true ground height as its baseline instead of assuming `0.0`.

**Files:**
- Modify: `shared/sim/ladder.gd`
- Modify: `tests/ladder_test.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/ladder_test.gd`:

```gdscript
func test_platform_floor_uses_ground_y_baseline() -> void:
	assert_almost_eq(Ladder.platform_floor([], 0.0, 0.0, 0.0, -5.0), -5.0, 0.001,
		"no platforms -> the supplied ground_y baseline, not a hardcoded 0.0")

func test_platform_floor_default_ground_y_is_zero() -> void:
	assert_almost_eq(Ladder.platform_floor([], 0.0, 0.0, 0.0), 0.0, 0.001,
		"omitted ground_y preserves today's flat-ground behaviour")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=ladder_test`
Expected: FAIL — `test_platform_floor_uses_ground_y_baseline` gets `0.0`, not `-5.0`.

- [ ] **Step 3: Implement**

In `shared/sim/ladder.gd`, replace `platform_floor`:

```gdscript
## Highest platform top at or below `y` whose footprint contains (x,z); `ground_y` (0.0 = flat
## ground, matching today's behaviour) if no platform qualifies.
static func platform_floor(platforms: Array, x: float, z: float, y: float, ground_y: float = 0.0) -> float:
	var best := ground_y
	for p in platforms:
		var mn: Vector3 = p["min"]
		var mx: Vector3 = p["max"]
		if x >= mn.x and x <= mx.x and z >= mn.z and z <= mx.z:
			if y >= mx.y - ANCHOR_EPS and mx.y > best:
				best = mx.y
	return best
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=ladder_test`
Expected: all ladder_test cases pass.

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression (default `ground_y=0.0` preserves every existing call site's behaviour — none pass a 5th argument yet).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/ladder.gd tests/ladder_test.gd
git commit -m "fix(terrain): Ladder.platform_floor takes a ground_y baseline, not a hardcoded 0.0 (M15)"
```

---

## Task 7: Pawn & Vehicle terrain-aware ground clamp

**Files:**
- Modify: `shared/sim/pawn.gd`
- Modify: `shared/sim/vehicle.gd`
- Modify: `tests/pawn_test.gd`
- Modify: `tests/vehicle_test.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/pawn_test.gd`:

```gdscript
func test_step_clamps_to_terrain_height_not_zero() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			g.set_sample(col, row, 8.0)   # a flat plateau at y=8
	var p := Pawn.new(1)
	p.pos = Vector3(0, 20.0, 0)   # start well above the plateau, falling
	for _i in 60:
		p.step(1.0 / 30.0, {}, Pawn.WORLD_HALF, g)
	assert_almost_eq(p.pos.y, 8.0, 0.05, "settles on the plateau, not on y=0")
	assert_true(p.grounded)

func test_step_terrain_valley_below_zero() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			g.set_sample(col, row, -6.0)   # a valley below the old flat datum
	var p := Pawn.new(1)
	p.pos = Vector3(0, 2.0, 0)
	for _i in 60:
		p.step(1.0 / 30.0, {}, Pawn.WORLD_HALF, g)
	assert_almost_eq(p.pos.y, -6.0, 0.05, "falls all the way into the valley, not stuck at y=0")

func test_step_null_terrain_matches_old_flat_behaviour() -> void:
	var p := Pawn.new(1)
	p.pos = Vector3(0, 2.0, 0)
	for _i in 30:
		p.step(1.0 / 30.0, {})   # no terrain arg at all
	assert_almost_eq(p.pos.y, 0.0, 0.05)
```

Append to `tests/vehicle_test.gd` (adjust to however this file constructs a `Vehicle` — mirror the existing pattern used by other tests in the same file for `Vehicle.make(...)`):

```gdscript
func test_vehicle_step_clamps_to_terrain_height() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			g.set_sample(col, row, 4.0)
	var v := Vehicle.make(1, 0, VehicleCatalog.load_file("res://vehicles/vehicles.json").def_of(0), 0, Vector3(0, 20.0, 0))
	for _i in 60:
		v.step(1.0 / 30.0, {}, Vehicle.WORLD_HALF, g)
	assert_almost_eq(v.pos.y, 4.0, 0.05, "settles on terrain, not y=0")
```

(If `vehicles.json`/`VehicleCatalog.def_of` construction doesn't match this project's actual test helper, use whatever existing helper `vehicle_test.gd` already uses to build a `Vehicle` instance — the assertion and terrain setup are what matters.)

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=pawn_test` and `--filter=vehicle_test`
Expected: FAIL — `step()` doesn't accept a 4th argument yet (Godot raises a too-many-arguments error).

- [ ] **Step 3: Implement**

In `shared/sim/pawn.gd`, change `step` and `_step_downed` signatures and their ground clamps:

```gdscript
func step(dt: float, cmd: Dictionary, world_half: float = WORLD_HALF, terrain: TerrainGrid = null) -> void:
```

...(body unchanged until the gravity/integrate block)...

```gdscript
	# gravity + integrate
	velocity.y -= GRAVITY * dt
	pos += velocity * dt
	var gy := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= gy:
		pos.y = gy
		velocity.y = 0.0
		grounded = true
```

```gdscript
func _step_downed(dt: float, cmd: Dictionary, world_half: float = WORLD_HALF, terrain: TerrainGrid = null) -> void:
	# Crawl-only: forced prone, no lean, no sprint/jump, gravity still applies.
	stance = Stance.PRONE
	lean = Stance.LEAN_NONE
	var move := Vector3(cmd.get("move_x", 0.0), 0.0, cmd.get("move_y", 0.0))
	if move.length() > 1.0:
		move = move.normalized()
	velocity.x = move.x * Revive.DOWNED_CRAWL_SPEED
	velocity.z = move.z * Revive.DOWNED_CRAWL_SPEED
	velocity.y -= GRAVITY * dt
	pos += velocity * dt
	var gy := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= gy:
		pos.y = gy
		velocity.y = 0.0
		grounded = true
	pos.x = clampf(pos.x, -world_half, world_half)
	pos.z = clampf(pos.z, -world_half, world_half)
```

And update `step()`'s call into `_step_downed`:

```gdscript
	if is_downed:
		_step_downed(dt, cmd, world_half, terrain)
		return
```

In `shared/sim/vehicle.gd`, change `step`'s signature and ground clamp:

```gdscript
func step(dt: float, cmd: Dictionary, world_half: float = WORLD_HALF, terrain: TerrainGrid = null) -> void:
	...(unchanged until)...
	var fwd := Vector3(sin(heading), 0.0, cos(heading))
	velocity = Vector3(fwd.x * speed, velocity.y - GRAVITY * dt, fwd.z * speed)
	pos += velocity * dt
	var gy := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= gy:
		pos.y = gy; velocity.y = 0.0
	pos.x = clampf(pos.x, -world_half, world_half)
	pos.z = clampf(pos.z, -world_half, world_half)
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=pawn_test` and `--filter=vehicle_test`
Expected: all pass, including new terrain cases.

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — every existing `p.step(dt, cmd)` / `v.step(dt, cmd)` call omits the new 4th arg, defaults to `null`, `Terrain.height_at(null,...)` returns `0.0`, identical to before.

- [ ] **Step 6: Commit**

```bash
git add shared/sim/pawn.gd shared/sim/vehicle.gd tests/pawn_test.gd tests/vehicle_test.gd
git commit -m "feat(terrain): Pawn/Vehicle ground clamp queries Terrain.height_at, not a literal 0.0 (M15)"
```

---

## Task 8: SimLoop wiring — floor chain, slope-blocking, vehicles

**Files:**
- Modify: `shared/sim/sim_loop.gd`
- Create: `tests/sim_loop_terrain_test.gd`

- [ ] **Step 1: Write the failing tests**

```gdscript
extends TestCase
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

func _flat_grid(half: float, h: float) -> TerrainGrid:
	var g := TerrainGrid.new(2.0, half)
	for row in g.dim:
		for col in g.dim:
			g.set_sample(col, row, h)
	return g

func test_pawn_settles_on_a_plateau_via_apply_platform_floor() -> void:
	var sim := SimLoop.new()
	sim.terrain = _flat_grid(10.0, 8.0)
	var p := sim.world.spawn(1)
	p.pos = Vector3(0, 30.0, 0)
	for _i in 90:
		sim.step({})
	assert_almost_eq(p.pos.y, 8.0, 0.05)
	assert_true(p.grounded)

func test_pawn_settles_into_a_valley_below_zero() -> void:
	var sim := SimLoop.new()
	sim.terrain = _flat_grid(10.0, -6.0)
	var p := sim.world.spawn(1)
	p.pos = Vector3(0, 2.0, 0)
	for _i in 90:
		sim.step({})
	assert_almost_eq(p.pos.y, -6.0, 0.05)

func test_walking_is_blocked_by_a_too_steep_slope() -> void:
	var sim := SimLoop.new()
	var g := TerrainGrid.new(2.0, 20.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, maxf(0.0, wx * 8.0))   # steep cliff for x>0, flat for x<=0
	sim.terrain = g
	var p := sim.world.spawn(1)
	p.pos = Vector3(-1.0, 0.0, 0.0)
	for _i in 30:
		sim.step({1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0}})
	assert_true(p.pos.x < 0.5, "the cliff at x=0 stops the pawn from climbing into it")

func test_walking_up_a_gentle_slope_is_unblocked() -> void:
	var sim := SimLoop.new()
	var g := TerrainGrid.new(2.0, 20.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, wx * 0.1)   # ~6 degrees
	sim.terrain = g
	var p := sim.world.spawn(1)
	p.pos = Vector3(-5.0, Terrain.height_at(g, -5.0, 0.0), 0.0)
	for _i in 60:
		sim.step({1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0}})
	assert_true(p.pos.x > -3.0, "a gentle slope does not block forward progress")

func test_vehicle_settles_on_terrain_and_is_blocked_by_a_cliff() -> void:
	var sim := SimLoop.new()
	var g := TerrainGrid.new(2.0, 20.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, maxf(0.0, wx * 8.0))
	sim.terrain = g
	var vcat := VehicleCatalog.load_file("res://vehicles/vehicles.json")
	var v := Vehicle.make(1, 0, vcat.def_of(0), 0, Vector3(-2.0, 10.0, 0.0))
	sim.world.spawn_vehicle(v)
	for _i in 30:
		sim.step_vehicles({1: {"move_x": 0.0, "move_y": 1.0}})
	assert_almost_eq(v.pos.y, 0.0, 0.5, "vehicle settled onto flat terrain, not floating")
	assert_true(v.pos.x < 0.5, "the cliff stops the vehicle from driving up it")
```

(If `VehicleCatalog`/`Vehicle.make` construction differs from the actual API, mirror whatever `tests/vehicle_gate_test.gd` already uses — the terrain setup and assertions are what matters.)

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=sim_loop_terrain_test`
Expected: FAIL — `Invalid assignment of property or key 'terrain'` (SimLoop has no such member yet), and pawns fall through to `y=0` instead of the plateau/valley height.

- [ ] **Step 3: Implement**

In `shared/sim/sim_loop.gd`, add a member next to `platforms`:

```gdscript
var terrain: TerrainGrid = null   # optional TerrainGrid; null = flat (pre-M15 behaviour)
```

Update `step()` to pass `terrain` into `p.step(...)`:

```gdscript
		var cmd: Dictionary = inputs.get(id, {})
		p.step(DT, cmd, world_half, terrain)
```

Replace `_apply_platform_floor`:

```gdscript
func _apply_platform_floor(p: Pawn) -> void:
	var ground_y := Terrain.height_at(terrain, p.pos.x, p.pos.z)
	var floor_y := Ladder.platform_floor(platforms, p.pos.x, p.pos.z, p.pos.y, ground_y)
	if structures != null:
		floor_y = maxf(floor_y, structures.floor_height_at(p.pos.x, p.pos.z, p.pos.y))
	if p.pos.y < floor_y:
		p.pos.y = floor_y
		p.velocity.y = 0.0
		p.grounded = true
	elif p.pos.y <= floor_y + Ladder.ANCHOR_EPS and floor_y > ground_y:
		p.grounded = true
```

Replace `_step_normal` (add the terrain slope-block after the structures resolution, before `_apply_platform_floor`):

```gdscript
func _step_normal(p: Pawn, prev: Vector3, cmd: Dictionary) -> void:
	var intended := p.pos
	if structures != null:
		var resolved: Vector3 = structures.resolve_movement(prev, intended)
		if resolved != intended:
			# Blocked. Vault it if it is a low blocker and we are standing + moving.
			var top: float = structures.ground_blocker_top(intended)
			var flat := Vector3(intended.x - prev.x, 0.0, intended.z - prev.z)
			var moving := flat.length() > MIN_MOVE_LEN
			if Vault.can_vault(top, p.stance, moving):
				Vault.begin(p, prev, flat.normalized())
				p.pos = prev
				return
			p.pos = resolved
		else:
			p.pos = resolved
	if terrain != null:
		p.pos = Terrain.resolve_movement(terrain, prev, p.pos)
	_apply_platform_floor(p)
	# Ladder engage (after movement, so a pawn that walked into the volume this tick climbs next tick).
	if not p.climbing:
		var ladder := Ladder.capture(ladders, p.pos)
		if Ladder.should_engage(ladder, p.pos, cmd.get("move_y", 0.0)):
			p.climbing = true
```

Replace `step_vehicles`:

```gdscript
func step_vehicles(vinputs: Dictionary, world_half: float = Vehicle.WORLD_HALF) -> void:
	for vid in world.vehicles:
		var v: Vehicle = world.vehicles[vid]
		if not v.alive:
			continue
		var prev := v.pos
		v.step(DT, vinputs.get(vid, {}), world_half, terrain)
		if structures != null:
			var seg := v.pos - prev
			var seg_len := seg.length()
			if seg_len > 0.0001:
				var m: Dictionary = structures.march(prev, seg / seg_len, seg_len)
				if bool(m["hit"]):
					v.pos = prev; v.speed = 0.0; v.velocity = Vector3.ZERO
		if terrain != null:
			var resolved := Terrain.resolve_movement(terrain, prev, v.pos)
			if resolved != v.pos:
				v.pos = prev; v.speed = 0.0; v.velocity = Vector3.ZERO
		var ground_y := Terrain.height_at(terrain, v.pos.x, v.pos.z)
		var floor_y := Ladder.platform_floor(platforms, v.pos.x, v.pos.z, v.pos.y, ground_y)
		if v.pos.y < floor_y:
			v.pos.y = floor_y; v.velocity.y = 0.0
		for seat in v.seats.size():
			var occ: int = int(v.seats[seat])
			if occ == 0:
				continue
			var p: Pawn = world.get_pawn(occ)
			if p == null:
				continue
			p.pos = v.seat_world(seat)
			if int(v.seat_roles[seat]) == Vehicle.ROLE_GUNNER:
				v.turret_yaw = p.yaw
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=sim_loop_terrain_test`
Expected: `TESTS: 5 run, 0 failed`

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — `terrain == null` everywhere else, `_apply_platform_floor`'s `ground_y` is `0.0`, `floor_y > ground_y` reduces to the old `floor_y > 0.0` check exactly.

- [ ] **Step 6: Commit**

```bash
git add shared/sim/sim_loop.gd tests/sim_loop_terrain_test.gd
git commit -m "feat(terrain): SimLoop folds terrain into the floor chain + slope-blocks movement/vehicles (M15)"
```

---

## Task 9: StructureStore.terrain + march() LOS/bullet occlusion + server wiring

**Files:**
- Modify: `shared/sim/structure.gd`
- Modify: `tests/structure_march_test.gd`
- Modify: `server/server_main.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/structure_march_test.gd`:

```gdscript
func test_march_blocked_by_a_terrain_ridge() -> void:
	var catalog := PieceCatalog.new()
	var s := StructureStore.new(catalog)
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, 6.0 if wx >= 4.0 and wx <= 6.0 else 0.0)
	s.terrain = g
	var r := s.march(Vector3(0.0, 1.0, 0.0), Vector3(1, 0, 0), 20.0)
	assert_eq(r["hit"], true, "the ridge blocks the ray")
	assert_eq(r["terrain"], true, "blocked by terrain, not a structure piece")
	assert_true(float(r["dist"]) < 5.0, "hit registers before the ray clears the ridge")

func test_march_clear_over_flat_terrain() -> void:
	var catalog := PieceCatalog.new()
	var s := StructureStore.new(catalog)
	var g := TerrainGrid.new(2.0, 10.0)   # all-zero, flat
	s.terrain = g
	var r := s.march(Vector3(0.0, 1.0, 0.0), Vector3(1, 0, 0), 20.0)
	assert_eq(r["hit"], false, "flat terrain never blocks a ray at eye height")

func test_march_null_terrain_matches_old_behaviour() -> void:
	var catalog := PieceCatalog.new()
	var s := StructureStore.new(catalog)   # s.terrain stays null
	var r := s.march(Vector3(0.0, 1.0, 0.0), Vector3(1, 0, 0), 20.0)
	assert_eq(r["hit"], false)
	assert_eq(r["terrain"], false)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_march_test`
Expected: FAIL — `Invalid assignment of property or key 'terrain'` (StructureStore has no such member).

- [ ] **Step 3: Implement**

In `shared/sim/structure.gd`, add a member near `_catalog`:

```gdscript
var terrain: TerrainGrid = null   # optional; set once by the server (or a test) after construction
```

Replace `march`:

```gdscript
func march(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var d := dir.normalized()
	if d == Vector3.ZERO:
		return {"hit": false, "dist": INF, "id": 0, "terrain": false}
	var cell := BuildGrid.cell_of(origin)
	var step := Vector3i(int(signf(d.x)), int(signf(d.y)), int(signf(d.z)))
	var t_max := Vector3.INF
	var t_delta := Vector3.INF
	for a in 3:
		if step[a] != 0:
			var edge := float(cell[a] + (1 if step[a] > 0 else 0)) * BuildGrid.CELL_SIZE
			t_max[a] = (edge - origin[a]) / d[a]
			t_delta[a] = BuildGrid.CELL_SIZE / absf(d[a])
	var t := 0.0
	while t <= max_dist:
		if terrain != null:
			var wp := origin + d * t
			if wp.y < Terrain.height_at(terrain, wp.x, wp.z):
				return {"hit": true, "dist": t, "id": 0, "terrain": true}
		var id: int = _occupancy.get(cell, 0)
		if id != 0:
			var hit_t := _ray_piece(origin, d, _by_id[id])
			if hit_t >= 0.0 and hit_t <= max_dist:
				return {"hit": true, "dist": hit_t, "id": id, "terrain": false}
		var axis := 0
		if t_max.y < t_max.x: axis = 1
		if t_max.z < t_max[axis]: axis = 2
		t = t_max[axis]
		cell[axis] += step[axis]
		t_max[axis] += t_delta[axis]
	return {"hit": false, "dist": INF, "id": 0, "terrain": false}
```

In `server/server_main.gd`, right after `_store = StructureStore.new(_catalog)` (the line already followed by `_sim.structures = _store`, `_sim.ladders = _map.ladders`, `_sim.platforms = _map.platforms`):

```gdscript
	_store = StructureStore.new(_catalog)
	_store.terrain = _map.terrain
	_sim.structures = _store
	_sim.ladders = _map.ladders
	_sim.platforms = _map.platforms
	_sim.terrain = _map.terrain
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_march_test`
Expected: `TESTS: 3 run, 0 failed` (plus every pre-existing case in that file).

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — every existing `march()` caller only reads `["hit"]`/`["dist"]`/`["id"]`; the new `"terrain"` key is additive.

- [ ] **Step 6: Commit**

```bash
git add shared/sim/structure.gd tests/structure_march_test.gd server/server_main.gd
git commit -m "feat(terrain): StructureStore.march() occludes on terrain height; wire terrain into server_main (M15)"
```

---

## Task 10: fire.gd terrain-aware ballistics

**Why this task exists:** `march()` (Task 9) covers single-ray LOS checks (bot perception, melee, shovel, rockets — all already just check `["hit"]`, so they get terrain occlusion for free with zero changes). But **fired bullets are stepped tick-by-tick**, not via one long `march()` call — `fire.gd`'s per-tick ground check (`if nxt.y <= 0.0`) is a **separate, literal flat-plane special case** that must become terrain-aware too, or a bullet flying toward a hillside will fly straight through it.

**Files:**
- Modify: `server/fire.gd`
- Modify: `tests/projectile_gate_test.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/projectile_gate_test.gd`:

```gdscript
func test_terrain_hill_blocks_a_bullet_before_it_reaches_the_target() -> void:
	var srv := _make_server()
	var shooter := _add_pawn(srv, 1, Vector3(0, 1.0, 0), 0)
	var target := _add_pawn(srv, 2, Vector3(0, 1.0, 40), 1)
	_rebuild_grid(srv)
	var g := TerrainGrid.new(2.0, 60.0)
	for row in g.dim:
		for col in g.dim:
			var wz := row * g.spacing - g.half_extent
			g.set_sample(col, row, 5.0 if wz > 15.0 and wz < 20.0 else 0.0)
	srv._sim.terrain = g
	var dir: Vector3 = (target.pos - shooter.pos).normalized()
	srv._fire.spawn_projectile_for_test(1, Weapon.AR, shooter.pos, dir)
	var hp0: int = target.health
	for _i in 20:
		srv._fire.step_projectiles()
	assert_eq(target.health, hp0, "the ridge between shooter and target blocks the bullet")
	srv.free()

func test_flat_terrain_still_hits_the_target() -> void:
	var srv := _make_server()
	var shooter := _add_pawn(srv, 1, Vector3(0, 0, 0), 0)
	var target := _add_pawn(srv, 2, Vector3(0, 0, 40), 1)
	_rebuild_grid(srv)
	srv._sim.terrain = TerrainGrid.new(2.0, 60.0)   # flat, all-zero
	var aim: Vector3 = target.pos + Vector3(0.0, Stance.body_height(target.stance) * 0.5, 0.0)
	var dir: Vector3 = (aim - shooter.eye_position()).normalized()
	srv._fire.spawn_projectile_for_test(1, Weapon.AR, shooter.eye_position(), dir)
	var hp0: int = target.health
	for _i in 20:
		srv._fire.step_projectiles()
	assert_true(target.health < hp0, "flat terrain (all-zero grid) behaves exactly like no terrain")
	srv.free()
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_hill_blocks_a_bullet`
Expected: FAIL — the bullet still travels through the ridge and damages the target (`assert_eq` fails).

- [ ] **Step 3: Implement**

In `server/fire.gd`, widen the cover-check guard and branch on `blocked["terrain"]` (around the existing `if srv._store.count() > 0 and seg_len > 0.0001:` block):

```gdscript
		# Cover / penetration: a structure OR terrain strictly nearer than the enemy along THIS segment.
		if (srv._store.count() > 0 or srv._sim.terrain != null) and seg_len > 0.0001:
			var march_max: float = best_t if best_victim != 0 else seg_len
			var blocked: Dictionary = srv._store.march(old_pos, seg_dir, march_max)
			if blocked["hit"] and float(blocked["dist"]) < best_t:
				var hit_pt: Vector3 = old_pos + seg_dir * float(blocked["dist"])
				if bool(blocked.get("terrain", false)):
					srv._stats.shots_blocked += 1
					srv._broadcast_impact_fx(hit_pt, Protocol.IMPACT_DIRT)
					continue   # stopped by terrain — consume the bullet
				var block_id := int(blocked["id"])
				var rec: Dictionary = srv._store.get_record(block_id)
				if rec.is_empty():
					continue   # piece gone (defensive)
				var mat: int = srv._catalog.material_of(int(rec["type"]))
				srv._stats.shots_blocked += 1
				if not PieceCatalog.is_penetrable(mat):
					srv._damage_structure(block_id, PieceCatalog.SRC_BULLET, hit_pt, srv.BULLET_CARVE_RADIUS)
					srv._broadcast_impact_fx(hit_pt, Protocol.IMPACT_WALL)   # cosmetic: bullet chips the wall
					continue   # stopped by cover — consume the bullet
				# Penetrable: bullet exits at *transmit. Piece is carved geometrically (M11).
				var split := Combat.apply_penetration(body_dmg, enemy_dmg,
					PieceCatalog.absorption_of(mat), PieceCatalog.transmit_of(mat))
				srv._damage_structure(block_id, PieceCatalog.SRC_BULLET, hit_pt, srv.BULLET_CARVE_RADIUS)
				srv._broadcast_impact_fx(hit_pt, Protocol.IMPACT_WALL)   # cosmetic: dust where it punches through
				if srv._store.get_record(block_id).is_empty():
					continue   # 1-pen: piece destroyed by this bullet consumes it
				if best_victim == 0:
					continue   # nothing beyond to hit; bullet passed through but found no pawn
				srv._stats.pen += 1
				enemy_dmg = int(split["exit_damage"])
```

And generalize the direct ground-impact check further down (was `if nxt.y <= 0.0:`):

```gdscript
		# Miss this tick: advance state and decide whether the bullet lives on.
		pr["pos"] = nxt
		pr["vel"] = s["vel"]
		pr["dist"] = float(pr["dist"]) + seg_len
		srv._stats.dbg_last_min_y = minf(srv._stats.dbg_last_min_y, nxt.y)
		var gy := Terrain.height_at(srv._sim.terrain, nxt.x, nxt.z)
		if nxt.y <= gy:
			# Cosmetic dirt puff at the ground-impact point (lerp the segment to the terrain height).
			var gt: float = (old_pos.y - gy) / (old_pos.y - nxt.y) if old_pos.y > nxt.y else 1.0
			srv._broadcast_impact_fx(old_pos + (nxt - old_pos) * gt, Protocol.IMPACT_DIRT)
			continue   # hit the ground/terrain
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=projectile_gate_test`
Expected: all cases pass, including the 2 new ones.

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — `srv._sim.terrain` is `null` everywhere else, `Terrain.height_at(null,...)` returns `0.0`, exactly matching the old literal check.

- [ ] **Step 6: Commit**

```bash
git add server/fire.gd tests/projectile_gate_test.gd
git commit -m "feat(terrain): bullets are blocked/grounded by terrain height, not just y<=0 (M15)"
```

---

## Task 11: BuildGrid.rotate_xz + BuildingCatalog.footprint_of

**Why this task exists:** the building auto-flatten pad (Task 12) needs to know a placed building's footprint size in cells, rotation-aware. The rotation math already exists as a private `server_main.gd::_rotate_offset` — this task promotes it to `BuildGrid` (the project's documented "single source of truth for cell<->world math," per its own docstring) so both the existing placement loop and the new footprint sizing share one implementation.

**Files:**
- Modify: `shared/sim/build_grid.gd`
- Modify: `shared/sim/building_catalog.gd`
- Modify: `server/server_main.gd`
- Modify: `tests/build_grid_test.gd`
- Modify: `tests/building_catalog_test.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/build_grid_test.gd`:

```gdscript
func test_rotate_xz_identity_at_yaw_zero() -> void:
	assert_eq(BuildGrid.rotate_xz(Vector3i(2, 1, 3), 0), Vector3i(2, 1, 3))

func test_rotate_xz_quarter_turn_preserves_y() -> void:
	var r := BuildGrid.rotate_xz(Vector3i(2, 5, 0), 2)   # 2 steps = 90 degrees (YAW_STEPS=8)
	assert_eq(r.y, 5, "y passes through unchanged")
	assert_eq(r, Vector3i(0, 5, 2))
```

Append to `tests/building_catalog_test.gd`:

```gdscript
func test_footprint_of_axis_aligned_box() -> void:
	var pieces := [
		{"type": 0, "offset": Vector3i(0, 0, 0), "yaw": 0, "structural": false},
		{"type": 0, "offset": Vector3i(2, 0, 0), "yaw": 0, "structural": false},
		{"type": 0, "offset": Vector3i(0, 0, 1), "yaw": 0, "structural": false},
	]
	var fp := BuildingCatalog.footprint_of(pieces, 0)
	assert_eq(int(fp["min_x"]), 0)
	assert_eq(int(fp["min_z"]), 0)
	assert_eq(int(fp["size_x"]), 3, "spans offset x=0..2 inclusive")
	assert_eq(int(fp["size_z"]), 2, "spans offset z=0..1 inclusive")

func test_footprint_of_rotates_with_yaw() -> void:
	var pieces := [
		{"type": 0, "offset": Vector3i(0, 0, 0), "yaw": 0, "structural": false},
		{"type": 0, "offset": Vector3i(3, 0, 0), "yaw": 0, "structural": false},
	]
	var fp := BuildingCatalog.footprint_of(pieces, 2)   # 90 degrees: x-extent becomes z-extent
	assert_eq(int(fp["size_x"]), 1)
	assert_eq(int(fp["size_z"]), 4)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=build_grid_test` and `--filter=building_catalog_test`
Expected: FAIL — `Nonexistent function 'rotate_xz'` / `'footprint_of'`.

- [ ] **Step 3: Implement**

In `shared/sim/build_grid.gd`, add:

```gdscript
## Rotate a cell offset by yaw_step quarter-turns around the vertical (Y) axis; Y passes through
## unchanged. Shared by building placement (server_main) and footprint sizing (BuildingCatalog).
static func rotate_xz(off: Vector3i, yaw_step: int) -> Vector3i:
	var quarters := (yaw_step % YAW_STEPS) / (YAW_STEPS / 4)
	var x := off.x
	var z := off.z
	for _i in range(quarters):
		var nx := -z
		var nz := x
		x = nx
		z = nz
	return Vector3i(x, off.y, z)
```

In `shared/sim/building_catalog.gd`, add:

```gdscript
## Cell-offset AABB (min corner + inclusive size) of a prefab's pieces after rotating each
## offset by `yaw_step` — sizes a terrain auto-flatten pad under a building at load time (M15).
static func footprint_of(pieces: Array, yaw_step: int) -> Dictionary:
	var min_x := 0; var max_x := 0; var min_z := 0; var max_z := 0
	var first := true
	for p in pieces:
		var r := BuildGrid.rotate_xz(p["offset"], yaw_step)
		if first:
			min_x = r.x; max_x = r.x; min_z = r.z; max_z = r.z
			first = false
		else:
			min_x = mini(min_x, r.x); max_x = maxi(max_x, r.x)
			min_z = mini(min_z, r.z); max_z = maxi(max_z, r.z)
	return {"min_x": min_x, "min_z": min_z, "size_x": max_x - min_x + 1, "size_z": max_z - min_z + 1}
```

In `server/server_main.gd`, replace the call site and delete the now-redundant private method:

```gdscript
			var cell := origin + BuildGrid.rotate_xz(piece["offset"], inst_yaw)
```

Delete the `_rotate_offset` function (lines ~481-490 — the one this plan read earlier: `func _rotate_offset(off: Vector3i, yaw_step: int) -> Vector3i: ...`).

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=build_grid_test` and `--filter=building_catalog_test`
Expected: all pass.

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — `BuildGrid.rotate_xz` is byte-for-byte the same math `_rotate_offset` did; every existing building placement (all yaw=0 in current maps) is unaffected either way.

- [ ] **Step 6: Commit**

```bash
git add shared/sim/build_grid.gd shared/sim/building_catalog.gd server/server_main.gd tests/build_grid_test.gd tests/building_catalog_test.gd
git commit -m "refactor(build): promote rotate_offset to BuildGrid.rotate_xz; add BuildingCatalog.footprint_of (M15)"
```

---

## Task 12: TerrainGrid.flatten_for_building / cutout_for_building + server wiring

**Files:**
- Modify: `shared/sim/terrain_grid.gd`
- Modify: `shared/sim/map_def.gd`
- Modify: `tests/terrain_grid_test.gd`
- Modify: `tests/map_def_test.gd`
- Modify: `server/server_main.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/terrain_grid_test.gd`:

```gdscript
func test_flatten_footprint_writes_a_uniform_pad() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			g.set_sample(col, row, float(col))   # a ramp
	g.flatten_footprint(3, 3, 2, 2, 9.0)   # 3x3 block starting at (col=3,row=3)
	for dr in 3:
		for dc in 3:
			assert_almost_eq(g.sample(3 + dc, 3 + dr), 9.0, 0.001)
	assert_true(g.sample(0, 0) != 9.0, "outside the footprint is untouched")

func test_flatten_for_building_pads_a_sloped_footprint_to_the_origin_height() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, wx)   # 1m rise per 2m column (a ramp along +x)
	var pad_y := g.flatten_for_building(4.0, 0.0, 0, 0, 3, 3)
	assert_eq(pad_y, int(round(Terrain.height_at(g, 4.0, 0.0) / BuildGrid.CELL_SIZE)))
	var gc := g.grid_coord(4.0, 0.0)
	var base_col := int(round(gc.x)); var base_row := int(round(gc.y))
	var expect := float(pad_y) * BuildGrid.CELL_SIZE
	for dr in 3:
		for dc in 3:
			assert_almost_eq(g.sample(base_col + dc, base_row + dr), expect, 0.01, "footprint is flat")

func test_cutout_for_building_drops_terrain_well_below_the_building_cell() -> void:
	var g := TerrainGrid.new(2.0, 10.0)
	for row in g.dim:
		for col in g.dim:
			g.set_sample(col, row, 4.0)   # a flat 4m plateau
	g.cutout_for_building(0.0, 0.0, -2, 0, 0, 3, 5)
	var gc := g.grid_coord(0.0, 0.0)
	var base_col := int(round(gc.x)); var base_row := int(round(gc.y))
	assert_true(g.sample(base_col, base_row) < -2.0 * BuildGrid.CELL_SIZE,
		"terrain inside the cutout drops well below the tunnel's own cell.y")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_grid_test`
Expected: FAIL — `Nonexistent function 'flatten_footprint'`.

- [ ] **Step 3: Implement**

Append to `shared/sim/terrain_grid.gd`:

```gdscript
## Flattens a rectangular footprint (grid samples, not BuildGrid cells — v1 keeps spacing==
## BuildGrid.CELL_SIZE so the two line up 1:1) to a single height. size_cols/size_rows are the
## inclusive extra span beyond (min_col,min_row) — a size_cols=2 call touches 3 columns.
func flatten_footprint(min_col: int, min_row: int, size_cols: int, size_rows: int, height: float) -> void:
	for row in range(min_row, min_row + size_rows + 1):
		for col in range(min_col, min_col + size_cols + 1):
			set_sample(col, row, height)

## Terrain-follow a building footprint: samples height at (origin_x,origin_z), flattens the
## footprint (in cells, matching this grid's spacing) to that height, and returns the cell-Y
## offset to add to the building's origin so its piece stack sits on the flattened pad.
## footprint_min_x/z + footprint_size_x/z come from BuildingCatalog.footprint_of.
func flatten_for_building(origin_x: float, origin_z: float, footprint_min_x: int, footprint_min_z: int,
		footprint_size_x: int, footprint_size_z: int) -> int:
	var pad_height := Terrain.height_at(self, origin_x, origin_z)
	var pad_cell_y := int(round(pad_height / BuildGrid.CELL_SIZE))
	var gc := grid_coord(origin_x, origin_z)
	var min_col := int(round(gc.x)) + footprint_min_x
	var min_row := int(round(gc.y)) + footprint_min_z
	flatten_footprint(min_col, min_row, footprint_size_x - 1, footprint_size_z - 1,
		float(pad_cell_y) * BuildGrid.CELL_SIZE)
	return pad_cell_y

const _CUTOUT_DEPTH := 50.0   # m below the tunnel's own authored cell.y — always beaten by its structure floor

## Terrain cutout for a below-grade building (e.g. a tunnel): suppresses terrain under the
## footprint to well below the building's own cell.y, so StructureStore's floor/wall pieces
## fully own that column instead of the (now-irrelevant) natural terrain surface.
func cutout_for_building(origin_x: float, origin_z: float, origin_cell_y: int,
		footprint_min_x: int, footprint_min_z: int, footprint_size_x: int, footprint_size_z: int) -> void:
	var gc := grid_coord(origin_x, origin_z)
	var min_col := int(round(gc.x)) + footprint_min_x
	var min_row := int(round(gc.y)) + footprint_min_z
	flatten_footprint(min_col, min_row, footprint_size_x - 1, footprint_size_z - 1,
		float(origin_cell_y) * BuildGrid.CELL_SIZE - _CUTOUT_DEPTH)
```

In `shared/sim/map_def.gd`, extend the `buildings` parsing loop in `from_dict` to accept the optional flag (find the existing `for b in data.get("buildings", []):` block and add one line to the appended dictionary):

```gdscript
		m.buildings.append({
			"prefab": String(b["prefab"]),
			"origin_cell": Vector3i(int(oc[0]), int(oc[1]), int(oc[2])),
			"yaw": byaw,
			"terrain_cutout": bool(b.get("terrain_cutout", false)),
		})
```

In `server/server_main.gd`, in the buildings-stamping loop (right after the `inst_yaw` range check, before the `for piece in pres["prefab"]["pieces"]:` loop):

```gdscript
		if _map.terrain != null:
			var footprint := BuildingCatalog.footprint_of(pres["prefab"]["pieces"], inst_yaw)
			var origin_world := BuildGrid.world_of(origin)
			if bool(b.get("terrain_cutout", false)):
				_map.terrain.cutout_for_building(origin_world.x, origin_world.z, origin.y,
					int(footprint["min_x"]), int(footprint["min_z"]), int(footprint["size_x"]), int(footprint["size_z"]))
			else:
				origin.y += _map.terrain.flatten_for_building(origin_world.x, origin_world.z,
					int(footprint["min_x"]), int(footprint["min_z"]), int(footprint["size_x"]), int(footprint["size_z"]))
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_grid_test`
Expected: all pass, including the 3 new cases.

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — `_map.terrain == null` for every existing map, so the new `if _map.terrain != null:` block never runs; `terrain_cutout` defaults to `false` for every existing building entry.

- [ ] **Step 6: Commit**

```bash
git add shared/sim/terrain_grid.gd shared/sim/map_def.gd tests/terrain_grid_test.gd tests/map_def_test.gd server/server_main.gd
git commit -m "feat(terrain): building auto-flatten pads + terrain cutouts for tunnels (M15)"
```

---

## Task 13: Bot slope-avoidance heuristic

**Files:**
- Create: `bots/ai/behaviors/terrain_avoid.gd`
- Create: `tests/ai_terrain_avoid_test.gd`
- Modify: `bots/bot_driver.gd`

- [ ] **Step 1: Write the failing tests**

```gdscript
extends TestCase
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

func test_is_stuck_requires_commanded_movement() -> void:
	assert_false(AiTerrainAvoid.is_stuck(0.05, 0.0), "no movement commanded -> not 'stuck', just idle")
	assert_true(AiTerrainAvoid.is_stuck(0.05, 1.0), "moving commanded but barely displaced -> stuck")
	assert_false(AiTerrainAvoid.is_stuck(2.0, 1.0), "displaced normally -> not stuck")

func test_choose_sidestep_prefers_the_shallower_slope() -> void:
	var g := TerrainGrid.new(2.0, 20.0)
	for row in g.dim:
		for col in g.dim:
			var wx := col * g.spacing - g.half_extent
			g.set_sample(col, row, maxf(0.0, wx))   # steep toward +x, flat toward -x/0
	var dir := AiTerrainAvoid.choose_sidestep(g, Vector3(0, 0, 0), Vector2(0, 1))   # facing +z
	# perpendiculars to (0,1) are (-1,0) and (1,0); (-1,0) probes the flatter side
	assert_almost_eq(dir.x, -1.0, 0.01, "picks the shallower (-x) side")

func test_choose_sidestep_null_terrain_keeps_desired_direction() -> void:
	var dir := AiTerrainAvoid.choose_sidestep(null, Vector3.ZERO, Vector2(1, 0))
	assert_eq(dir, Vector2(1, 0))
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=ai_terrain_avoid_test`
Expected: FAIL — file failed to parse (terrain_avoid.gd doesn't exist).

- [ ] **Step 3: Implement**

```gdscript
class_name AiTerrainAvoid
extends RefCounted
## Reactive slope-stuck detection + sidestep heading choice for bots. Bots already get terrain-
## following for free via the shared sim (Pawn.step/SimLoop); this only stops a bot from pushing
## forever into a too-steep slope that Terrain.resolve_movement blocks. Pure/testable;
## bot_driver.gd holds the per-bot timing state. Narrow scope: slope-specific stuck-avoidance
## only, NOT general obstacle/building pathfinding (unchanged from today — no NavMesh/AStar
## anywhere in this codebase). See docs/specs/heightmap-terrain.md §6.

const STUCK_DISPLACEMENT_EPS := 0.3   # m over the check window; below this while moving = stuck
const AVOID_PROBE := 3.0              # m ahead to sample the two candidate sidestep directions
const AVOID_HOLD_TICKS := 45          # ~1.5s @ 30Hz between stuck re-checks

## True if the bot commanded movement but travelled less than STUCK_DISPLACEMENT_EPS since the
## last check — i.e. Terrain.resolve_movement is clipping it.
static func is_stuck(displacement: float, commanded_move_len: float) -> bool:
	return commanded_move_len > 0.01 and displacement < STUCK_DISPLACEMENT_EPS

## Pick the shallower-slope sidestep direction (perpendicular to `desired_dir`).
static func choose_sidestep(terrain: TerrainGrid, pos: Vector3, desired_dir: Vector2) -> Vector2:
	if terrain == null or desired_dir.length() < 0.001:
		return desired_dir
	var d := desired_dir.normalized()
	var perp_a := Vector2(-d.y, d.x)
	var perp_b := -perp_a
	var pa := Vector2(pos.x, pos.z) + perp_a * AVOID_PROBE
	var pb := Vector2(pos.x, pos.z) + perp_b * AVOID_PROBE
	var slope_a := Terrain.slope_at(terrain, pa.x, pa.y)
	var slope_b := Terrain.slope_at(terrain, pb.x, pb.y)
	return perp_a if slope_a <= slope_b else perp_b
```

Wire it into `bots/bot_driver.gd`'s normal-AI movement branch — immediately after the existing lines (inside the `else:` block that starts with `# AI brain drives normal infantry combat + movement`):

```gdscript
			move_x = float(intent["move_x"]); move_y = float(intent["move_y"])
			bot["yaw"] = float(intent["yaw"]); bot["pitch"] = float(intent["pitch"])
```

add directly after those two lines:

```gdscript
			# M15: reactive slope-stuck avoidance — Terrain.resolve_movement blocks a too-steep
			# climb; without this a bot just pushes into the slope forever.
			var terrain: TerrainGrid = _map.terrain if _map != null else null
			if terrain != null:
				var check_tick: int = int(bot.get("terrain_check_tick", -1))
				var now_tick: int = int(bot["server_tick"])
				if now_tick - check_tick >= AiTerrainAvoid.AVOID_HOLD_TICKS:
					var last_pos: Vector3 = bot.get("terrain_check_pos", me.pos)
					var displacement := me.pos.distance_to(last_pos)
					var commanded := Vector2(move_x, move_y).length()
					if AiTerrainAvoid.is_stuck(displacement, commanded):
						bot["terrain_avoid_dir"] = AiTerrainAvoid.choose_sidestep(terrain, me.pos, Vector2(move_x, move_y))
					else:
						bot["terrain_avoid_dir"] = Vector2.ZERO
					bot["terrain_check_tick"] = now_tick
					bot["terrain_check_pos"] = me.pos
				var avoid: Vector2 = bot.get("terrain_avoid_dir", Vector2.ZERO)
				if avoid.length() > 0.01:
					move_x = avoid.x; move_y = avoid.y
					bot["yaw"] = atan2(move_x, move_y)
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=ai_terrain_avoid_test`
Expected: `TESTS: 3 run, 0 failed`

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — `_map.terrain` is `null` for every non-terrain map, so the new block never fires (identical to today's bot movement).

- [ ] **Step 6: Commit**

```bash
git add bots/ai/behaviors/terrain_avoid.gd tests/ai_terrain_avoid_test.gd bots/bot_driver.gd
git commit -m "feat(terrain): bots sidestep too-steep slopes instead of pushing into them forever (M15)"
```

---

## Task 14: Client chunked terrain mesh

**Files:**
- Modify: `client/world_renderer.gd`
- Create: `tests/world_renderer_terrain_test.gd`

- [ ] **Step 1: Write the failing tests**

```gdscript
extends TestCase
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

func _flat_map() -> MapDef:
	var res := MapDef.from_dict({
		"name": "t", "world_half": 20.0,
		"points": [{"id": "a", "pos": [0, 0, 0], "radius": 5, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
	})
	return res["map"]

func test_setup_builds_flat_ground_when_map_has_no_terrain() -> void:
	var map := _flat_map()
	var r := WorldRenderer.new()
	var cam := autofree(Camera3D.new())
	r.setup(map, cam)
	assert_eq(r._terrain_chunks.size(), 0, "no terrain -> no chunk meshes (flat PlaneMesh path)")
	r.free()

func test_setup_builds_terrain_chunks_when_map_has_terrain() -> void:
	var map := _flat_map()
	map.terrain = TerrainGrid.new(2.0, 20.0)
	var r := WorldRenderer.new()
	var cam := autofree(Camera3D.new())
	r.setup(map, cam)
	assert_true(r._terrain_chunks.size() > 0, "terrain present -> at least one chunk mesh built")
	for mi in r._terrain_chunks:
		assert_true((mi.mesh as ArrayMesh).get_surface_count() > 0, "each chunk has real geometry")
	r.free()
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=world_renderer_terrain_test`
Expected: FAIL — `Invalid get index '_terrain_chunks'` (member doesn't exist yet).

- [ ] **Step 3: Implement**

In `client/world_renderer.gd`, add a member near the top of the class (alongside other tracked-node arrays):

```gdscript
var _terrain_chunks: Array[MeshInstance3D] = []
const TERRAIN_CHUNK_SAMPLES := 64   # ~128m tiles at 2m spacing; one MeshInstance3D per chunk gets frustum culling for free
```

In `setup()`, wrap the existing ground-plane block so it only runs when there's no terrain, and add the terrain-chunk path:

```gdscript
	# Ground plane
	if map.terrain != null:
		_build_terrain_chunks(map.terrain)
	else:
		var ground := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		var side := map.world_half * 2.0
		plane.size = Vector2(side, side)
		ground.mesh = plane
		# ...(rest of the existing flat-ground procedural-noise material code, unchanged)...
		add_child(ground)
```

Add the new methods (near the other private `_build_*` helpers):

```gdscript
func _build_terrain_chunks(grid: TerrainGrid) -> void:
	_terrain_chunks.clear()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.29, 0.39, 0.22)
	mat.roughness = 1.0
	var chunk_cells := TERRAIN_CHUNK_SAMPLES
	var chunks_per_axis := int(ceil(float(grid.dim - 1) / float(chunk_cells)))
	for cz in chunks_per_axis:
		for cx in chunks_per_axis:
			var col0 := cx * chunk_cells
			var row0 := cz * chunk_cells
			var col1 := mini(col0 + chunk_cells, grid.dim - 1)
			var row1 := mini(row0 + chunk_cells, grid.dim - 1)
			if col1 <= col0 or row1 <= row0:
				continue
			var mi := MeshInstance3D.new()
			mi.mesh = _build_terrain_chunk_mesh(grid, col0, row0, col1, row1)
			mi.material_override = mat
			add_child(mi)
			_terrain_chunks.append(mi)

func _build_terrain_chunk_mesh(grid: TerrainGrid, col0: int, row0: int, col1: int, row1: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := col1 - col0 + 1
	for row in range(row0, row1 + 1):
		for col in range(col0, col1 + 1):
			var wx := col * grid.spacing - grid.half_extent
			var wz := row * grid.spacing - grid.half_extent
			st.add_vertex(Vector3(wx, grid.sample(col, row), wz))
	for row in range(row1 - row0):
		for col in range(col1 - col0):
			var i00 := row * w + col
			var i10 := row * w + col + 1
			var i01 := (row + 1) * w + col
			var i11 := (row + 1) * w + col + 1
			st.add_index(i00); st.add_index(i10); st.add_index(i11)
			st.add_index(i00); st.add_index(i11); st.add_index(i01)
	st.generate_normals()
	return st.commit()
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=world_renderer_terrain_test`
Expected: `TESTS: 2 run, 0 failed`

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression — every existing map has `map.terrain == null`, so `setup()` takes the unchanged flat-`PlaneMesh` branch exactly as before.

- [ ] **Step 6: Commit**

```bash
git add client/world_renderer.gd tests/world_renderer_terrain_test.gd
git commit -m "feat(terrain): client renders a chunked terrain mesh from the heightmap (M15)"
```

---

## Task 15: Demo heightmap generator tool

**Files:**
- Create: `tools/heightmap_gen.py`

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Generate a demo grayscale heightmap PNG for conquest_proving_grounds, exercising every
terrain mechanic in one map: rolling hills, a valley (LOS-block + fall-damage test), a
too-steep cliff band (slope-blocking test), flat plateaus around the map's existing
bases/points/buildings (auto-flatten-pad test), and a tunnel-entrance dip (cutout test). See
docs/specs/heightmap-terrain.md.

No external deps (matches tools/map_gen.py) — writes an 8-bit grayscale PNG by hand via
zlib/struct rather than requiring Pillow.

Run:  python3 tools/heightmap_gen.py   ->  writes maps/heightmaps/conquest_proving_grounds.png
"""
import json, math, os, struct, zlib

CELL = 2.0
HEIGHT_MIN = -8.0
HEIGHT_SCALE = 28.0   # samples span [HEIGHT_MIN, HEIGHT_MIN+HEIGHT_SCALE] = [-8, 20] m
TUNNEL_ENTRANCE = (350.0, 100.0)   # world (x,z); must match the tunnel building placement in the map JSON
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def write_grayscale_png(path, width, height, pixels):
    """pixels: bytes/bytearray, length width*height, row-major, one byte (0-255) per pixel."""
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)   # 8-bit grayscale, no interlace
    raw = bytearray()
    for row in range(height):
        raw.append(0)   # PNG scanline filter type 0 (none)
        raw.extend(pixels[row * width:(row + 1) * width])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


def load_map(name):
    return json.load(open(os.path.join(ROOT, "maps", name + ".json")))


def raw_height(wx, wz):
    # Rolling hills: two low-frequency sine layers.
    h = 6.0 * math.sin(wx / 220.0) * math.cos(wz / 260.0)
    h += 3.0 * math.sin(wx / 90.0 + wz / 130.0)
    # A valley trench crossing the map's east side (LOS-block + fall-damage test).
    valley_d = abs(wx - 300.0)
    if valley_d < 60.0:
        h -= (1.0 - valley_d / 60.0) * 14.0
    # A deliberately too-steep cliff band (slope-blocking test): a hard step, not a ramp.
    if wx > 500.0:
        h += 18.0
    # Tunnel entrance: a funnel-shaped depression leading down to the cutout mouth.
    td = math.hypot(wx - TUNNEL_ENTRANCE[0], wz - TUNNEL_ENTRANCE[1])
    if td < 12.0:
        h -= (1.0 - td / 12.0) * 6.0
    return h


def height_field(world_half, spacing, feature_points):
    """feature_points: list of (x, z, radius) world-space flat pads (bases/points/buildings)."""
    dim = round((world_half * 2.0) / spacing) + 1
    samples = bytearray(dim * dim)
    for row in range(dim):
        wz = row * spacing - world_half
        for col in range(dim):
            wx = col * spacing - world_half
            h = raw_height(wx, wz)
            for (fx, fz, fr) in feature_points:
                if (wx - fx) ** 2 + (wz - fz) ** 2 <= fr * fr:
                    h = raw_height(fx, fz)   # flatten the pad to the feature centre's natural height
                    break
            h = max(HEIGHT_MIN, min(HEIGHT_MIN + HEIGHT_SCALE, h))
            lum = round((h - HEIGHT_MIN) / HEIGHT_SCALE * 255.0)
            samples[row * dim + col] = lum
    return dim, samples


def main():
    m = load_map("conquest_proving_grounds")
    world_half = float(m["world_half"])
    feature_points = []
    for p in m["points"]:
        feature_points.append((p["pos"][0], p["pos"][2], p["radius"] + 6.0))
    for b in m["bases"]:
        feature_points.append((b["pos"][0], b["pos"][2], b.get("radius", 8.0) + 10.0))
    for b in m.get("buildings", []):
        oc = b["origin_cell"]
        feature_points.append((oc[0] * CELL, oc[2] * CELL, 14.0))
    dim, samples = height_field(world_half, CELL, feature_points)
    out_dir = os.path.join(ROOT, "maps", "heightmaps")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "conquest_proving_grounds.png")
    write_grayscale_png(out_path, dim, dim, samples)
    print("wrote %s (%dx%d)" % (out_path, dim, dim))


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it and verify the output**

Run: `python3 tools/heightmap_gen.py`
Expected: `wrote .../maps/heightmaps/conquest_proving_grounds.png (1001x1001)` (world_half=1000, CELL=2.0 → dim=1001) and the file exists.

Run: `python3 -c "import struct; f=open('maps/heightmaps/conquest_proving_grounds.png','rb'); assert f.read(8)==b'\x89PNG\r\n\x1a\n'; print('valid PNG signature')"`
Expected: `valid PNG signature` (sanity-checks the hand-rolled encoder before Godot ever touches it).

- [ ] **Step 3: Commit**

```bash
git add tools/heightmap_gen.py
git commit -m "feat(terrain): tools/heightmap_gen.py — demo heightmap exercising every M15 mechanic"
```

---

## Task 16: Retrofit conquest_proving_grounds + tunnel prefab

**Files:**
- Create: `buildings/tunnel_segment.json`
- Modify: `maps/conquest_proving_grounds.json`
- Generate: `maps/heightmaps/conquest_proving_grounds.png` (Task 15's tool)

- [ ] **Step 1: Create the tunnel prefab**

A straight 4-cell corridor (1 cell wide interior), walls both sides, an end-cap, and a roof one cell up — an enclosed subterranean space. Uses only existing piece ids from `pieces/pieces.json` (`bfloor`, `bwall`).

```json
{
  "name": "tunnel_segment",
  "pieces": [
    {"type": "bfloor", "offset": [0, 0, 0], "yaw": 0},
    {"type": "bfloor", "offset": [0, 0, 1], "yaw": 0},
    {"type": "bfloor", "offset": [0, 0, 2], "yaw": 0},
    {"type": "bfloor", "offset": [0, 0, 3], "yaw": 0},
    {"type": "bwall", "offset": [-1, 0, 0], "yaw": 0},
    {"type": "bwall", "offset": [-1, 0, 1], "yaw": 0},
    {"type": "bwall", "offset": [-1, 0, 2], "yaw": 0},
    {"type": "bwall", "offset": [-1, 0, 3], "yaw": 0},
    {"type": "bwall", "offset": [1, 0, 0], "yaw": 0},
    {"type": "bwall", "offset": [1, 0, 1], "yaw": 0},
    {"type": "bwall", "offset": [1, 0, 2], "yaw": 0},
    {"type": "bwall", "offset": [1, 0, 3], "yaw": 0},
    {"type": "bwall", "offset": [-1, 0, 4], "yaw": 0},
    {"type": "bwall", "offset": [0, 0, 4], "yaw": 0},
    {"type": "bwall", "offset": [1, 0, 4], "yaw": 0},
    {"type": "bfloor", "offset": [-1, 1, 0], "yaw": 0},
    {"type": "bfloor", "offset": [0, 1, 0], "yaw": 0},
    {"type": "bfloor", "offset": [1, 1, 0], "yaw": 0},
    {"type": "bfloor", "offset": [-1, 1, 1], "yaw": 0},
    {"type": "bfloor", "offset": [0, 1, 1], "yaw": 0},
    {"type": "bfloor", "offset": [1, 1, 1], "yaw": 0},
    {"type": "bfloor", "offset": [-1, 1, 2], "yaw": 0},
    {"type": "bfloor", "offset": [0, 1, 2], "yaw": 0},
    {"type": "bfloor", "offset": [1, 1, 2], "yaw": 0},
    {"type": "bfloor", "offset": [-1, 1, 3], "yaw": 0},
    {"type": "bfloor", "offset": [0, 1, 3], "yaw": 0},
    {"type": "bfloor", "offset": [1, 1, 3], "yaw": 0}
  ]
}
```

The `z=0` end (offset z=0) is left open — that's the entrance, aligned under the heightmap's sculpted entrance dip. The `z=4` wall row is a dead end.

- [ ] **Step 2: Verify the prefab loads**

Run: `python3 -c "import json; json.load(open('buildings/tunnel_segment.json'))" && echo "valid JSON"`
Expected: `valid JSON`

- [ ] **Step 3: Add the terrain field + tunnel placement to the map**

In `maps/conquest_proving_grounds.json`, add a top-level `"terrain"` key (values must match `HEIGHT_MIN`/`HEIGHT_SCALE` from `tools/heightmap_gen.py`):

```json
  "terrain": {
    "heightmap": "heightmaps/conquest_proving_grounds.png",
    "sample_spacing": 2.0,
    "height_min": -8.0,
    "height_scale": 28.0
  },
```

And add to the `"buildings"` array (world (350,100) / CELL 2.0 = cell (175,?,50), matching `TUNNEL_ENTRANCE` in the heightmap tool; `origin_cell.y = -4` places it well below the surrounding grade, `terrain_cutout: true` suppresses terrain over its footprint):

```json
    {"prefab": "tunnel_segment", "origin_cell": [175, -4, 50], "yaw": 0, "terrain_cutout": true}
```

- [ ] **Step 4: Generate the heightmap and verify the map loads**

Run: `python3 tools/heightmap_gen.py`
Expected: writes `maps/heightmaps/conquest_proving_grounds.png`.

Run: `godot --headless --path . -- --test --filter=map_def_test` (confirms `MapDef.load_file` parses the modified JSON without error — this doesn't load `conquest_proving_grounds.json` directly, so also spot-check with a one-off headless script):

Run:
```bash
godot --headless --path . --script res://tools/qa/verify_map_loads.gd -- --map=conquest_proving_grounds 2>&1 | tail -5
```

If no such QA script exists yet, verify instead with a tiny inline check — run the server pointed at the map and confirm it boots clean:

```bash
timeout 15 godot --headless --path . -- --server --map=conquest_proving_grounds --port=27260 --time-limit=5 2>&1 | grep -iE "error|\[map\]" | head -20
```

Expected: no `SCRIPT ERROR` / `[map] invalid` lines; the server boots and exits cleanly at the 5s time limit.

- [ ] **Step 5: Run the full suite**

Run: `godot --headless --path . -- --test`
Expected: no regression (this task only adds new files + edits one existing map's JSON; every other map is untouched).

- [ ] **Step 6: Commit**

```bash
git add buildings/tunnel_segment.json maps/conquest_proving_grounds.json maps/heightmaps/conquest_proving_grounds.png
git commit -m "feat(terrain): retrofit conquest_proving_grounds with hills, a valley, a cliff, and a tunnel (M15)"
```

---

## Task 17: Full verification + 128-bot fleet gate

**Files:**
- Modify: `docs/TASKS.md`
- Modify: `docs/milestones/M15-heightmap-terrain.md` (create if it doesn't exist yet)

- [ ] **Step 1: Run the full unit suite**

Run: `godot --headless --path . -- --import && godot --headless --path . -- --test`
Expected: full suite green, 0 failures, 0 script errors (record the exact `TESTS: N run, 0 failed` line as gate evidence).

- [ ] **Step 2: Run the ≤48-bot smoke on the retrofitted map**

Run whatever this project's existing smoke pattern is for a new map (mirror `ci/m11_buildings_test.sh`'s structure, pointed at `conquest_proving_grounds` with the new terrain):

```bash
MAP=conquest_proving_grounds ./ci/run_smoke.sh   # or the project's equivalent entrypoint for a ≤48-bot smoke — check ci/ for the exact script name/args pattern used by the most recent milestone (M8-P3) and mirror it
```

Expected: match completes, no script errors, tick mean well under budget.

- [ ] **Step 3: Run the 128-bot fleet gate**

Run (mirroring `docker/run-m7.5-gate.sh` / `docker/stress.sh`'s pattern, per `docs/runbooks/running-a-stress-test.md`):

```bash
MAP=conquest_proving_grounds SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./docker/stress.sh
```

Expected: `STRESS GATE: PASS`, peak tick < 33.3 ms, match reaches a winner, no script errors. Save the log to `docs/gate-evidence/` per this project's existing convention (see `docs/gate-evidence/README.md`).

- [ ] **Step 4: Manual/visual verification checklist**

Since terrain feel (does a hill actually read as cover, does the tunnel feel subterranean, does slope-blocking feel like a wall or a cliff) is explicitly a human-playtest gate item (not unit-testable), record against `docs/runbooks/playtest-checklist.md`'s pattern:
- Walk onto a hill; confirm no clipping/floating.
- Stand behind a hill from a squadmate on the other side; confirm no LOS/hitmarker across it.
- Drive a vehicle up a gentle slope (succeeds) and into the cliff band (blocked).
- Walk into the tunnel via the sculpted entrance; confirm it reads as an enclosed space, not a floating box.
- Watch a bot approach the cliff band; confirm it reroutes rather than visibly stalling.

- [ ] **Step 5: Update the milestone doc**

Create/update `docs/milestones/M15-heightmap-terrain.md` following the exact structure of `docs/milestones/M14-walkable-multifloor.md` (Objective / What landed / Gate / Out of scope), citing the spec, this plan, the test counts from Step 1, and the fleet-gate evidence path from Step 3.

- [ ] **Step 6: Update docs/TASKS.md**

Add an `M15` row to the milestone index table (mirroring the existing `M14` row's format) and a detail section below it, linking the spec/plan/milestone doc and recording gate evidence.

- [ ] **Step 7: Commit**

```bash
git add docs/TASKS.md docs/milestones/M15-heightmap-terrain.md docs/gate-evidence/
git commit -m "docs(terrain): M15 gate evidence + milestone doc (M15 CLOSED pending human playtest sign-off)"
```

---

## Notes for the implementing engineer

- **Master has moved.** This worktree branched from `origin/master` before the concurrent `m7.5-p3-support-ai` session merged and pushed (`ae1c725`). Before opening a PR / merging this branch, `git fetch origin && git rebase origin/master` (or merge) and re-run the full suite — do not blind-push over the other session's work.
- **2 m spacing is load-bearing**, not incidental: `flatten_for_building`/`cutout_for_building` (Task 12) assume `TerrainGrid.spacing == BuildGrid.CELL_SIZE` so cell-index and grid-sample-index line up 1:1 without a resampling step. If a future map ever wants finer spacing, that assumption needs revisiting first.
- Several test snippets above reference helper patterns (`_make_server`, `VehicleCatalog.load_file(...).def_of(...)`, exact `vehicle_test.gd` construction) inferred from sibling test files read during planning — if the exact helper signature differs slightly in the live file, adapt the test to that file's existing convention; the terrain setup and assertions are what must be preserved.
