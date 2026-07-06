# M15 Heightmap Terrain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add heightmap-based terrain elevation (hills, valleys, cliffs, tunnels-via-cutout) to Blockfire — walkable, real bullet/LOS cover, driveable, composing with buildings — server-authoritative, client-mirrored, deterministic, with **no wire-protocol change**.

**Architecture:** A pure stateless `Terrain` query module (mirroring `structure.gd`/`stairs.gd`) operating on a `TerrainGrid` data holder loaded from a per-map grayscale PNG. Both server (`SimLoop`/`server_main`) and client (`Prediction`/`world_renderer`) load the *same* PNG locally and derive the *identical* grid (same "both sides load the same JSON" pattern already used for maps/buildings). Terrain height folds into M14's existing floor-resolution chain (`_apply_platform_floor`), the pawn/vehicle ground clamps, `StructureStore.march` occlusion, and a client chunked mesh. All movement-hot-path lookups are O(1) bilinear samples. The module exposes the three primitives a future nav milestone needs — `height_at`, `slope_at`, and a too-steep test (`resolve_movement` / `MAX_WALKABLE_SLOPE_DEG`) — but builds **no** pathfinding (that is a separate later milestone).

**Tech Stack:** GDScript (Godot 4.x), headless `TestCase` unit runner (`godot --headless --path . -- --test [--filter=…]`), Python `tools/map_gen.py` for map/heightmap authoring, Docker fleet-gate harness on game2 (run server in tmux).

**Design of record:** `docs/specs/heightmap-terrain.md` (ratified 2026-07-03). Gate map: retrofit `maps/conquest_proving_grounds.json` (`world_half=1000`, 3 buildings).

**Key drift reconciled before planning (see task notes):** two pawn clamp sites (`pawn.gd:107` + `_step_downed:145`); a third clamp in `vehicle.gd:131` + vehicle floor at `sim_loop.gd:194`; `march` is the single occlusion chokepoint (fold terrain there once); `Pawn`/`Vehicle` are pure (thread terrain as a `step()` param); PNG→grid build lives in a `Terrain.load_for_map` helper, not in pure `MapDef`.

**Invariants to preserve (do not regress):**
- Maps without a `terrain` field stay perfectly flat: `Terrain.height_at(null, x, z) == 0.0` everywhere. `conquest_town`, `conquest_arena_buildings`, `conquest_dev_arena`, `conquest_showcase`, `conquest_suburb` must need **zero** changes and their tests stay green.
- Server and client derive a **bit-identical** grid from the same PNG + building list → no prediction divergence.
- No new wire message, no `Msg` id, no `VERSION` bump. Pawn/vehicle `y` already replicated at full precision (`POS_SCALE=1000.0`).
- Terrain lookups are O(1) (one bilinear sample); no per-tick allocation; protect the 128-bot fleet gate (mean tick < 33.3 ms) and snapshot cost (M11 lesson: profile `move`/`snap`/`march`, don't guess).

---

## File structure

**New files:**
- `shared/sim/terrain_grid.gd` — `class_name TerrainGrid`: the height-sample data holder (row-major `PackedFloat32Array` + params + cutout AABBs). Pure data; one responsibility.
- `shared/sim/terrain.gd` — `class_name Terrain`: stateless queries (`height_at`, `slope_at`, `resolve_movement`, `MAX_WALKABLE_SLOPE_DEG`) + grid-construction helpers (`build_grid`, `flatten_pad`, `carve_cutout`, `load_for_map`).
- `maps/heightmaps/proving_grounds.png` — generated demo/gate heightmap asset (never hand-edited; produced by `map_gen.py`).
- `tests/terrain_test.gd` — height/slope/resolve_movement.
- `tests/terrain_grid_build_test.gd` — build_grid / flatten_pad / carve_cutout from a synthetic `Image`.
- `tests/terrain_march_test.gd` — LOS/bullet occlusion by a hill.
- `tests/terrain_integration_test.gd` — pawn clamp, `_apply_platform_floor` chain, vehicle clamp, fall-off-ledge, client/server parity.

**Modified files:**
- `shared/sim/map_def.gd` — parse `terrain` config dict + optional `terrain_cutout` bool on buildings.
- `shared/sim/pawn.gd` — `step`/`_step_downed` ground clamp uses `Terrain.height_at` via a threaded terrain handle.
- `shared/sim/sim_loop.gd` — `var terrain`; pass to `p.step`/`v.step`; fold terrain into `_apply_platform_floor` maxf chain and into horizontal resolution; vehicle floor + slope block.
- `shared/sim/vehicle.gd` — `step` ground clamp uses terrain handle.
- `shared/sim/structure.gd` — `var terrain`; `march()` samples terrain per DDA step (occlusion).
- `server/server_main.gd` — build the grid via `Terrain.load_for_map` after `MapDef.load_file`; set `_sim.terrain` + `_store.terrain`.
- `client/prediction.gd` — forward a `terrain` handle to the loop (mirror the `structures` setter).
- `client/client_main.gd` — build the same grid client-side; pass to `Prediction`, `StructureStore` mirror, and `world_renderer`.
- `client/world_renderer.gd` — replace the flat `PlaneMesh` with a chunked terrain mesh from the grid.
- `bots/bot_driver.gd` — slope stuck-detection + directional sidestep (bot-only, not sim-authoritative).
- `tools/map_gen.py` — heightmap generator + write `terrain` field + tunnel building placement; regenerate `conquest_proving_grounds.json`.
- `docs/TASKS.md` — add the missing M15 milestone-index row.
- `docs/specs/heightmap-terrain.md` — flip status to in-progress/done at the end.

---

## Task 0: Housekeeping — add the M15 row to the TASKS.md milestone index

**Files:**
- Modify: `docs/TASKS.md` (milestone index table, after the M14 row ~line 28)

- [ ] **Step 1: Locate the index row for M14**

Run: `grep -n "^| M14 \|^| M12 \|^| M11 " docs/TASKS.md`
Expected: the three milestone-index rows (table starting at line 11, header `| # | Milestone | Status | Gate …`).

- [ ] **Step 2: Insert the M15 row directly after the M14 row**

Add this table row immediately after the `| M14 | … |` line (same 4-column format):

```markdown
| M15 | [Heightmap terrain](specs/heightmap-terrain.md) | **in-progress** | Heightmap-based terrain (hills/valleys/cliffs + tunnels-via-cutout): walkable, real bullet/LOS cover, driveable, composes with buildings; server-authoritative, client-mirrored, deterministic, **no wire change**. Gate = deterministic terrain-query unit tests + 128-bot fleet gate on retrofitted `conquest_proving_grounds` (mean tick < 33.3 ms, no new `[perf]` bottleneck) + human feel playtest (hills block sightlines, no floating/clipping buildings or vehicles, tunnel reads as subterranean). Plan: `docs/superpowers/plans/2026-07-06-m15-heightmap-terrain.md`. |
```

- [ ] **Step 3: Commit**

```bash
git add docs/TASKS.md
git commit -m "docs(m15): add heightmap-terrain row to the TASKS.md milestone index"
```

---

## Task 1: `TerrainGrid` data holder + `Terrain.height_at` (bilinear + cutout suppression)

**Files:**
- Create: `shared/sim/terrain_grid.gd`
- Create: `shared/sim/terrain.gd`
- Create/Test: `tests/terrain_test.gd`

**Design:** `TerrainGrid` holds a row-major `PackedFloat32Array` of `cols*rows` height samples on a regular grid with `spacing` metres, origin at `(origin_x, origin_z)` (= `-world_half`). `cutouts` is an array of `{min_x,max_x,min_z,max_z,floor_y}` AABBs where terrain is *suppressed* (tunnels): inside a cutout, `height_at` returns the cutout's low `floor_y` so structure pieces own the column and `march` doesn't treat it as solid ground. A `null` grid means "flat map" → height 0 everywhere (backward compat).

- [ ] **Step 1: Write the failing test**

`tests/terrain_test.gd`:

```gdscript
extends TestCase
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# A 3x3 grid, spacing 2 m, origin (-2,-2) -> covers world [-2..2] on both axes.
# Heights (row-major, z outer / x inner):
#   z=-2: 0 0 0
#   z= 0: 0 4 0
#   z= 2: 0 0 0
func _grid() -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 3; g.rows = 3; g.spacing = 2.0
	g.origin_x = -2.0; g.origin_z = -2.0
	g.samples = PackedFloat32Array([0,0,0, 0,4,0, 0,0,0])
	return g

func test_null_grid_is_flat() -> void:
	assert_eq(Terrain.height_at(null, 0.0, 0.0), 0.0, "null grid = flat")
	assert_eq(Terrain.height_at(null, 123.0, -77.0), 0.0, "null grid flat anywhere")

func test_height_at_grid_points() -> void:
	assert_almost_eq(Terrain.height_at(_grid(), 0.0, 0.0), 4.0, 0.001, "peak sample")
	assert_almost_eq(Terrain.height_at(_grid(), -2.0, -2.0), 0.0, 0.001, "corner sample")
	assert_almost_eq(Terrain.height_at(_grid(), 2.0, 2.0), 0.0, 0.001, "far corner")

func test_height_at_midpoints_bilinear() -> void:
	# midway between peak (4) and edge (0) along +x -> 2.0
	assert_almost_eq(Terrain.height_at(_grid(), 1.0, 0.0), 2.0, 0.001, "x-midpoint")
	assert_almost_eq(Terrain.height_at(_grid(), 0.0, 1.0), 2.0, 0.001, "z-midpoint")
	# diagonal quarter cell from peak toward (2,2) corner: bilinear of {4,0,0,0}
	assert_almost_eq(Terrain.height_at(_grid(), 1.0, 1.0), 1.0, 0.001, "diagonal midpoint")

func test_height_at_clamps_out_of_bounds() -> void:
	assert_almost_eq(Terrain.height_at(_grid(), -50.0, -50.0), 0.0, 0.001, "clamp to nearest edge, no crash")
	assert_almost_eq(Terrain.height_at(_grid(), 50.0, 0.0), 0.0, 0.001, "clamp +x edge")

func test_cutout_suppresses_terrain() -> void:
	var g := _grid()
	g.cutouts = [{"min_x": -0.5, "max_x": 0.5, "min_z": -0.5, "max_z": 0.5, "floor_y": -100.0}]
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), -100.0, 0.001, "inside cutout: terrain suppressed to low floor")
	assert_almost_eq(Terrain.height_at(g, 2.0, 0.0), 0.0, 0.001, "outside cutout: normal terrain")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . --import 2>/dev/null; godot --headless --path . -- --test --filter=terrain_test`
Expected: FAIL — `terrain.gd`/`terrain_grid.gd` do not exist (parse error / class not found).

- [ ] **Step 3: Write `shared/sim/terrain_grid.gd`**

```gdscript
class_name TerrainGrid
extends RefCounted
## Regular grid of terrain height samples (row-major, z-outer / x-inner). Pure data holder;
## all queries live in the stateless Terrain module (mirrors StructureStore-vs-structure split
## is inverted here: here the DATA is the class and the QUERY is static). A null TerrainGrid
## means "flat map" (height 0 everywhere) — backward compatible with every pre-M15 map.

var cols: int = 0            # samples along X
var rows: int = 0            # samples along Z
var spacing: float = 2.0     # metres between samples (matches BuildGrid.CELL_SIZE)
var origin_x: float = 0.0    # world X of sample column 0 (== -world_half)
var origin_z: float = 0.0    # world Z of sample row 0    (== -world_half)
var samples: PackedFloat32Array = PackedFloat32Array()   # size cols*rows, height in metres
## Terrain-suppression footprints (tunnels): each {min_x,max_x,min_z,max_z,floor_y}. Inside one,
## height_at returns floor_y (a low value) so structure pieces own the column and march() does not
## treat the column as solid ground.
var cutouts: Array = []

func sample(cx: int, cz: int) -> float:
	return samples[cz * cols + cx]

## floor_y of the cutout containing (x,z), or NAN if none. NAN chosen so callers branch with is_nan().
func cutout_floor(x: float, z: float) -> float:
	for c in cutouts:
		if x >= c["min_x"] and x <= c["max_x"] and z >= c["min_z"] and z <= c["max_z"]:
			return float(c["floor_y"])
	return NAN
```

- [ ] **Step 4: Write `shared/sim/terrain.gd` (height_at only for this task)**

```gdscript
class_name Terrain
extends RefCounted
## Stateless heightmap-terrain queries over a TerrainGrid handle. Pure, like structure.gd/stairs.gd
## — the grid IS the state. A null grid = flat map (height 0). O(1) bilinear sampling: safe in the
## movement hot path. See docs/specs/heightmap-terrain.md.

## Slope beyond this (degrees) is unwalkable/undriveable (walk, jump, drive all rejected). ~50° per
## BattleBit/typical-FPS feel; tune against the demo map's cliff during the gate.
const MAX_WALKABLE_SLOPE_DEG := 50.0

## Bilinearly-interpolated terrain height at world (x,z). null grid or inside a cutout handled first.
static func height_at(grid: TerrainGrid, x: float, z: float) -> float:
	if grid == null:
		return 0.0
	var cf := grid.cutout_floor(x, z)
	if not is_nan(cf):
		return cf
	var gx := (x - grid.origin_x) / grid.spacing
	var gz := (z - grid.origin_z) / grid.spacing
	var x0 := clampi(int(floor(gx)), 0, grid.cols - 1)
	var z0 := clampi(int(floor(gz)), 0, grid.rows - 1)
	var x1 := mini(x0 + 1, grid.cols - 1)
	var z1 := mini(z0 + 1, grid.rows - 1)
	var fx := clampf(gx - float(x0), 0.0, 1.0)
	var fz := clampf(gz - float(z0), 0.0, 1.0)
	var h00 := grid.sample(x0, z0)
	var h10 := grid.sample(x1, z0)
	var h01 := grid.sample(x0, z1)
	var h11 := grid.sample(x1, z1)
	var h0 := lerpf(h00, h10, fx)
	var h1 := lerpf(h01, h11, fx)
	return lerpf(h0, h1, fz)
```

- [ ] **Step 5: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_test`
Expected: PASS (all 6 `test_*`).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/terrain_grid.gd shared/sim/terrain.gd tests/terrain_test.gd
git commit -m "feat(m15): TerrainGrid + Terrain.height_at bilinear sampling with cutout suppression"
```

---

## Task 2: `Terrain.slope_at`, `resolve_movement`, `MAX_WALKABLE_SLOPE_DEG`

**Files:**
- Modify: `shared/sim/terrain.gd`
- Modify/Test: `tests/terrain_test.gd`

- [ ] **Step 1: Add failing tests to `tests/terrain_test.gd`**

Reuse the `_grid()` helper. Append:

```gdscript
func test_slope_flat_is_zero() -> void:
	assert_almost_eq(Terrain.slope_at(null, 0.0, 0.0), 0.0, 0.001, "null = flat, 0 deg")
	# a flat corner region of _grid() (away from the peak) is ~flat
	assert_almost_eq(Terrain.slope_at(_grid(), -2.0, -2.0), 0.0, 0.001, "flat corner ~0 deg")

func test_slope_on_incline_is_positive() -> void:
	# halfway up the peak the gradient is 4 m over 2 m run -> atan(2) ~= 63.4 deg
	var s := Terrain.slope_at(_grid(), 1.0, 0.0)
	assert_true(s > 45.0, "steep flank reads steep (got %f)" % s)

func test_resolve_movement_null_grid_passes() -> void:
	var to := Vector3(5, 0, 5)
	assert_eq(Terrain.resolve_movement(null, Vector3(0,0,0), to), to, "null grid never blocks")

func test_resolve_movement_gentle_slope_passes() -> void:
	# Build a gentle grid: 0..2 m over 20 m (~5.7 deg), spacing 2, 11 cols/rows.
	var g := TerrainGrid.new()
	g.cols = 11; g.rows = 11; g.spacing = 2.0; g.origin_x = -10.0; g.origin_z = -10.0
	var s := PackedFloat32Array()
	s.resize(121)
	for zi in 11:
		for xi in 11:
			s[zi*11 + xi] = float(xi) * 0.2   # 0.1 m per m of x -> ~5.7 deg
	g.samples = s
	var to := Vector3(2, 0, 0)
	assert_eq(Terrain.resolve_movement(g, Vector3(0,0,0), to), to, "gentle slope walkable")

func test_resolve_movement_too_steep_is_clipped() -> void:
	# destination is on the sharp peak flank of _grid() (slope > MAX) -> movement into it is clipped.
	var from := Vector3(-2, 0, 0)
	var to := Vector3(0, 0, 0)   # the 4 m peak column, flanks steeper than MAX_WALKABLE_SLOPE_DEG
	var out := Terrain.resolve_movement(_grid(), from, to)
	assert_ne(out, to, "too-steep destination is not reached (clipped/slid)")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_test`
Expected: FAIL — `slope_at`/`resolve_movement` not defined.

- [ ] **Step 3: Implement in `shared/sim/terrain.gd`**

Append:

```gdscript
## Local slope angle (degrees) via a central-difference gradient of height_at. Continuous
## everywhere (not a per-cell/per-edge facet). The primitive a future nav milestone consumes as
## its walkability/steepness test.
static func slope_at(grid: TerrainGrid, x: float, z: float) -> float:
	if grid == null:
		return 0.0
	var e := grid.spacing   # cell-scale central difference
	var dhx := (height_at(grid, x + e, z) - height_at(grid, x - e, z)) / (2.0 * e)
	var dhz := (height_at(grid, x, z + e) - height_at(grid, x, z - e)) / (2.0 * e)
	var grad := sqrt(dhx * dhx + dhz * dhz)
	return rad_to_deg(atan(grad))

## Horizontal blocker mirroring structure.gd::resolve_movement: if the destination column is too
## steep, try axis-separated slides so the mover slides along the slope face instead of advancing
## into it; if both blocked, stay. y is preserved (caller re-clamps y via _apply_platform_floor).
## One function covers walking, jumping (horizontal advance still runs through here), and vehicles.
static func resolve_movement(grid: TerrainGrid, from: Vector3, to: Vector3) -> Vector3:
	if grid == null:
		return to
	if slope_at(grid, to.x, to.z) <= MAX_WALKABLE_SLOPE_DEG:
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
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/terrain.gd tests/terrain_test.gd
git commit -m "feat(m15): Terrain.slope_at (central-difference gradient) + resolve_movement slope-blocker"
```

---

## Task 3: Grid construction from an `Image` + `flatten_pad` + `carve_cutout` primitives

**Files:**
- Modify: `shared/sim/terrain.gd`
- Create/Test: `tests/terrain_grid_build_test.gd`

**Design:** `build_grid(img, spacing, world_half, height_min, height_scale)` reads a grayscale `Image` where the red channel `0..1` maps linearly to `[height_min, height_min+height_scale]`. Image is `cols×rows` with `cols = rows = int(round(2*world_half/spacing)) + 1`. `flatten_pad` levels a footprint AABB to a fixed height (building pads); `carve_cutout` appends a suppression AABB (tunnels). These are the deterministic primitives; the file-loading `load_for_map` wrapper is Task 5.

- [ ] **Step 1: Write the failing test**

`tests/terrain_grid_build_test.gd`:

```gdscript
extends TestCase
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# Build a 5x5 image (world_half=4, spacing=2 -> 5 samples per axis) with a linear x-ramp:
# red 0.0 at x-col 0 .. 1.0 at x-col 4.
func _ramp_img() -> Image:
	var img := Image.create(5, 5, false, Image.FORMAT_RGBF)
	for zi in 5:
		for xi in 5:
			var v := float(xi) / 4.0
			img.set_pixel(xi, zi, Color(v, v, v))
	return img

func test_build_grid_maps_brightness_to_height() -> void:
	# height_min=0, height_scale=10 -> col0=0 m, col4=10 m.
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, 0.0, 10.0)
	assert_eq(g.cols, 5, "cols")
	assert_eq(g.rows, 5, "rows")
	assert_almost_eq(g.origin_x, -4.0, 0.001, "origin = -world_half")
	assert_almost_eq(Terrain.height_at(g, -4.0, 0.0), 0.0, 0.01, "min brightness -> height_min")
	assert_almost_eq(Terrain.height_at(g, 4.0, 0.0), 10.0, 0.01, "max brightness -> height_min+scale")
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), 5.0, 0.01, "mid brightness -> mid height")

func test_build_grid_height_min_offset() -> void:
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, -3.0, 6.0)
	assert_almost_eq(Terrain.height_at(g, -4.0, 0.0), -3.0, 0.01, "height_min applied")
	assert_almost_eq(Terrain.height_at(g, 4.0, 0.0), 3.0, 0.01, "height_min + scale")

func test_flatten_pad_levels_a_footprint() -> void:
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, 0.0, 10.0)
	# Flatten the whole map to 2.0 m.
	Terrain.flatten_pad(g, -4.0, 4.0, -4.0, 4.0, 2.0)
	assert_almost_eq(Terrain.height_at(g, -4.0, 0.0), 2.0, 0.01, "flattened min corner")
	assert_almost_eq(Terrain.height_at(g, 4.0, 0.0), 2.0, 0.01, "flattened max corner")
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), 2.0, 0.01, "flattened centre")

func test_carve_cutout_records_suppression() -> void:
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, 0.0, 10.0)
	Terrain.carve_cutout(g, -1.0, 1.0, -1.0, 1.0, -100.0)
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), -100.0, 0.01, "inside cutout suppressed")
	assert_true(Terrain.height_at(g, 4.0, 0.0) > 5.0, "outside cutout untouched")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_grid_build`
Expected: FAIL — `build_grid`/`flatten_pad`/`carve_cutout` not defined.

- [ ] **Step 3: Implement in `shared/sim/terrain.gd`**

Append:

```gdscript
## Build a TerrainGrid from a grayscale Image. Red channel 0..1 -> [height_min, height_min+scale].
## Image must be square, cols=rows=int(round(2*world_half/spacing))+1. Samples are read row-major
## with z increasing downward (image row 0 = z = -world_half), matching TerrainGrid.sample layout.
static func build_grid(img: Image, spacing: float, world_half: float, height_min: float, height_scale: float) -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = img.get_width()
	g.rows = img.get_height()
	g.spacing = spacing
	g.origin_x = -world_half
	g.origin_z = -world_half
	var s := PackedFloat32Array()
	s.resize(g.cols * g.rows)
	for zi in g.rows:
		for xi in g.cols:
			var v := img.get_pixel(xi, zi).r   # grayscale: r==g==b
			s[zi * g.cols + xi] = height_min + v * height_scale
	g.samples = s
	return g

## Level every sample whose world column falls in the AABB [min_x..max_x]x[min_z..max_z] to `height`.
## Used for building auto-flatten pads (a flat lot under a flat-footprint building on sloped terrain).
static func flatten_pad(grid: TerrainGrid, min_x: float, max_x: float, min_z: float, max_z: float, height: float) -> void:
	if grid == null:
		return
	for zi in grid.rows:
		var wz := grid.origin_z + float(zi) * grid.spacing
		if wz < min_z - grid.spacing or wz > max_z + grid.spacing:
			continue
		for xi in grid.cols:
			var wx := grid.origin_x + float(xi) * grid.spacing
			if wx < min_x - grid.spacing or wx > max_x + grid.spacing:
				continue
			grid.samples[zi * grid.cols + xi] = height

## Record a terrain-suppression AABB (tunnel). Inside it, height_at returns `floor_y` (a low value)
## so structure pieces own the column and march() does not treat the column as solid ground.
static func carve_cutout(grid: TerrainGrid, min_x: float, max_x: float, min_z: float, max_z: float, floor_y: float) -> void:
	if grid == null:
		return
	grid.cutouts.append({"min_x": min_x, "max_x": max_x, "min_z": min_z, "max_z": max_z, "floor_y": floor_y})
```

Note on the `± grid.spacing` slack in `flatten_pad`: it guarantees the pad covers the samples straddling the footprint edge so a building foundation never floats over a half-flattened boundary cell.

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_grid_build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/terrain.gd tests/terrain_grid_build_test.gd
git commit -m "feat(m15): Terrain.build_grid from Image + flatten_pad + carve_cutout primitives"
```

---

## Task 4: `MapDef.terrain` config field + `terrain_cutout` building flag

**Files:**
- Modify: `shared/sim/map_def.gd` (add `var terrain`; parse in `from_dict`; add `terrain_cutout` to building entries at map_def.gd:93-97)
- Create/Test: `tests/map_terrain_field_test.gd`

**Design:** `MapDef.terrain` is a plain config `Dictionary` (`{heightmap, sample_spacing, height_min, height_scale}`) or `{}` when absent — MapDef stays a pure JSON-data class (no `Image` load). Building entries gain optional `terrain_cutout: bool` (default `false`).

- [ ] **Step 1: Write the failing test**

`tests/map_terrain_field_test.gd`:

```gdscript
extends TestCase
const MapDef := preload("res://shared/sim/map_def.gd")

const _BASE := '"points":[{"id":"A","pos":[0,0,0],"radius":10}],"bases":[{"team":0,"pos":[-5,0,0],"radius":5},{"team":1,"pos":[5,0,0],"radius":5}]'

func test_map_without_terrain_is_empty_dict() -> void:
	var res := MapDef.from_json_string('{"name":"flat","world_half":100,%s}' % _BASE)
	assert_true(res["ok"], "parses")
	assert_true((res["map"].terrain as Dictionary).is_empty(), "no terrain field -> {}")

func test_terrain_field_parsed() -> void:
	var j := '{"name":"t","world_half":100,"terrain":{"heightmap":"heightmaps/t.png","sample_spacing":2.0,"height_min":-3.0,"height_scale":40.0},%s}' % _BASE
	var res := MapDef.from_json_string(j)
	assert_true(res["ok"], "parses")
	var t: Dictionary = res["map"].terrain
	assert_eq(String(t["heightmap"]), "heightmaps/t.png", "heightmap path")
	assert_almost_eq(float(t["sample_spacing"]), 2.0, 0.001, "spacing")
	assert_almost_eq(float(t["height_min"]), -3.0, 0.001, "height_min")
	assert_almost_eq(float(t["height_scale"]), 40.0, 0.001, "height_scale")

func test_building_terrain_cutout_flag() -> void:
	var j := '{"name":"t","world_half":100,"buildings":[{"prefab":"tunnel","origin_cell":[0,0,0],"terrain_cutout":true},{"prefab":"house","origin_cell":[5,0,5]}],%s}' % _BASE
	var res := MapDef.from_json_string(j)
	assert_true(res["ok"], "parses")
	assert_true(bool(res["map"].buildings[0]["terrain_cutout"]), "tunnel is a cutout")
	assert_false(bool(res["map"].buildings[1].get("terrain_cutout", false)), "house is not")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=map_terrain_field`
Expected: FAIL — `terrain` field / cutout flag absent.

- [ ] **Step 3: Add the field declaration**

In `shared/sim/map_def.gd`, after the `var vehicle_spawns` line (~line 18):

```gdscript
var terrain: Dictionary = {}   # {heightmap:String, sample_spacing:float, height_min:float, height_scale:float} or {} (flat)
```

- [ ] **Step 4: Parse `terrain` in `from_dict`**

In `shared/sim/map_def.gd`, just before `return {"ok": true, "map": m, "error": ""}` (~line 127):

```gdscript
	var raw_terrain: Variant = data.get("terrain", {})
	if typeof(raw_terrain) == TYPE_DICTIONARY and not raw_terrain.is_empty():
		if not raw_terrain.has("heightmap"):
			return {"ok": false, "map": null, "error": "terrain needs a heightmap path"}
		m.terrain = {
			"heightmap": String(raw_terrain["heightmap"]),
			"sample_spacing": float(raw_terrain.get("sample_spacing", 2.0)),
			"height_min": float(raw_terrain.get("height_min", 0.0)),
			"height_scale": float(raw_terrain.get("height_scale", 0.0)),
		}
```

- [ ] **Step 5: Add `terrain_cutout` to building parsing**

In `shared/sim/map_def.gd`, the building append at map_def.gd:93-97, add the flag:

```gdscript
		m.buildings.append({
			"prefab": String(b["prefab"]),
			"origin_cell": Vector3i(int(oc[0]), int(oc[1]), int(oc[2])),
			"yaw": byaw,
			"terrain_cutout": bool(b.get("terrain_cutout", false)),
		})
```

- [ ] **Step 6: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=map_terrain_field`
Expected: PASS. Then run the existing map tests to confirm no regression: `godot --headless --path . -- --test --filter=map_`
Expected: existing `map_*` tests still PASS.

- [ ] **Step 7: Commit**

```bash
git add shared/sim/map_def.gd tests/map_terrain_field_test.gd
git commit -m "feat(m15): MapDef.terrain config field + optional terrain_cutout building flag"
```

---

## Task 5: `Terrain.load_for_map` — PNG load + building auto-flatten pads + cutouts + `origin_cell.y` writeback

**Files:**
- Modify: `shared/sim/terrain.gd`
- Modify/Test: `tests/terrain_grid_build_test.gd`

**Design:** `load_for_map(map, base_dir, footprint_fn)` returns the `TerrainGrid` (or `null` when `map.terrain` is empty) *and* mutates `map.buildings` `origin_cell.y` so buildings sit on their flattened pads — computed identically on server and client from the same PNG + building list. For each building it derives a world footprint AABB (via `footprint_fn`, defaulting to a single origin cell when the caller has no catalog), samples terrain at the footprint centre, snaps that height to a `BuildGrid.CELL_SIZE` multiple (integer cells — buildings are cell-aligned), then `flatten_pad`s to the snapped height (or `carve_cutout`s when `terrain_cutout`). The snap keeps foundations flush with the pad and keeps `origin_cell` an integer `Vector3i`.

- [ ] **Step 1: Write the failing test (primitive-level, no file I/O)**

Append to `tests/terrain_grid_build_test.gd`:

```gdscript
const MapDef := preload("res://shared/sim/map_def.gd")
const BuildGrid := preload("res://shared/sim/build_grid.gd")

func test_load_for_map_flat_when_no_terrain() -> void:
	var res := MapDef.from_json_string('{"name":"f","world_half":10,"points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-3,0,0],"radius":2},{"team":1,"pos":[3,0,0],"radius":2}]}')
	var m: MapDef = res["map"]
	assert_eq(Terrain.load_for_map(m, "res://tests/fixtures", Callable()), null, "no terrain -> null grid (flat)")

func test_snap_to_cell_height() -> void:
	# 7.3 m snaps to the nearest 2 m cell base (6 or 8). Terrain.snap_pad_height rounds to CELL_SIZE.
	assert_almost_eq(Terrain.snap_pad_height(7.3), 8.0, 0.001, "7.3 -> 8")
	assert_almost_eq(Terrain.snap_pad_height(6.9), 6.0, 0.001, "6.9 -> 6")
	assert_almost_eq(Terrain.snap_pad_height(0.4), 0.0, 0.001, "0.4 -> 0")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_grid_build`
Expected: FAIL — `load_for_map` / `snap_pad_height` not defined.

- [ ] **Step 3: Implement in `shared/sim/terrain.gd`**

Append (add `const BuildGrid := preload("res://shared/sim/build_grid.gd")` at the top of `terrain.gd` if not present — check `grep -n "class_name BuildGrid" shared/sim/build_grid.gd`; `class_name BuildGrid` means it can be referenced directly without preload):

```gdscript
## Cutout floor sentinel: well below any real terrain so the maxf(structure, terrain) chain always
## lets a structure floor win inside a tunnel, and march never treats the column as solid ground.
const CUTOUT_FLOOR := -1000.0

## Round a sampled terrain height to a BuildGrid cell base (buildings are cell-aligned; a fractional
## foundation would need sub-cell offsets, out of scope per spec §5).
static func snap_pad_height(h: float) -> float:
	return roundf(h / BuildGrid.CELL_SIZE) * BuildGrid.CELL_SIZE

## Load the map's heightmap PNG (relative to base_dir), build the grid, and apply the load-time
## footprint pass: flatten a flat pad under each building (or carve a cutout when terrain_cutout),
## snapping origin_cell.y to the pad. Returns null when the map has no terrain (flat). Deterministic:
## server and client call this with the same map + PNG and get an identical grid + identical
## origin_cell.y writeback (no wire cost, no divergence). `footprint_fn` (Callable) maps a building
## entry -> {min_x,max_x,min_z,max_z}; pass an invalid Callable to default to the origin cell only.
static func load_for_map(map: MapDef, base_dir: String, footprint_fn: Callable) -> TerrainGrid:
	if map == null or map.terrain.is_empty():
		return null
	var t: Dictionary = map.terrain
	var path: String = base_dir.path_join(String(t["heightmap"]))
	var img := Image.new()
	var err := img.load(path)
	if err != OK:
		push_error("[terrain] failed to load heightmap %s (err %d)" % [path, err])
		return null
	if img.get_format() != Image.FORMAT_RGBF:
		img.convert(Image.FORMAT_RGBF)
	var grid := build_grid(img, float(t["sample_spacing"]), map.world_half, float(t["height_min"]), float(t["height_scale"]))
	for b in map.buildings:
		var oc: Vector3i = b["origin_cell"]
		var fp: Dictionary
		if footprint_fn.is_valid():
			fp = footprint_fn.call(b)
		else:
			var mn := BuildGrid.cell_min(oc)
			fp = {"min_x": mn.x, "max_x": mn.x + BuildGrid.CELL_SIZE, "min_z": mn.z, "max_z": mn.z + BuildGrid.CELL_SIZE}
		var cx := (float(fp["min_x"]) + float(fp["max_x"])) * 0.5
		var cz := (float(fp["min_z"]) + float(fp["max_z"])) * 0.5
		if bool(b.get("terrain_cutout", false)):
			carve_cutout(grid, fp["min_x"], fp["max_x"], fp["min_z"], fp["max_z"], CUTOUT_FLOOR)
			# a cutout building keeps its authored origin_cell.y (it sits below grade by design)
		else:
			var h := snap_pad_height(height_at(grid, cx, cz))
			flatten_pad(grid, fp["min_x"], fp["max_x"], fp["min_z"], fp["max_z"], h)
			b["origin_cell"] = Vector3i(oc.x, int(round(h / BuildGrid.CELL_SIZE)), oc.z)
	return grid
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_grid_build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/terrain.gd tests/terrain_grid_build_test.gd
git commit -m "feat(m15): Terrain.load_for_map — PNG load + building flatten-pad/cutout + origin_cell.y writeback"
```

---

## Task 6: Pawn ground clamp uses terrain (both `step` and `_step_downed`)

**Files:**
- Modify: `shared/sim/pawn.gd` (add `var terrain`; clamps at pawn.gd:107 and pawn.gd:145)
- Create/Test: `tests/terrain_integration_test.gd`

**Design:** `Pawn` is pure with no grid ref. Give it an optional `var terrain: TerrainGrid = null` (flat when null → identical to today). `SimLoop` sets it before stepping (Task 7). Both clamp sites become `pos.y <= ground` where `ground = Terrain.height_at(terrain, pos.x, pos.z)`.

- [ ] **Step 1: Write the failing test**

`tests/terrain_integration_test.gd`:

```gdscript
extends TestCase
const Pawn := preload("res://shared/sim/pawn.gd")
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# Flat grid at a raised height of 5 m across a 40x40 m area.
func _plateau(h: float) -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 21; g.rows = 21; g.spacing = 2.0; g.origin_x = -20.0; g.origin_z = -20.0
	var s := PackedFloat32Array(); s.resize(441); s.fill(h)
	g.samples = s
	return g

func test_pawn_rests_on_raised_terrain() -> void:
	var p := Pawn.new(1)
	p.terrain = _plateau(5.0)
	p.pos = Vector3(0, 8, 0)   # dropped in above the plateau
	# fall a few ticks with no input
	for i in 60:
		p.step(1.0/30.0, {}, 100.0)
	assert_almost_eq(p.pos.y, 5.0, 0.05, "pawn settles on the 5 m plateau, not y=0")
	assert_true(p.grounded, "grounded on terrain")

func test_pawn_flat_when_no_terrain() -> void:
	var p := Pawn.new(1)   # terrain null
	p.pos = Vector3(0, 8, 0)
	for i in 60:
		p.step(1.0/30.0, {}, 100.0)
	assert_almost_eq(p.pos.y, 0.0, 0.01, "no terrain -> flat y=0 (unchanged behaviour)")

func test_downed_pawn_rests_on_terrain() -> void:
	var p := Pawn.new(1)
	p.terrain = _plateau(3.0)
	p.is_downed = true
	p.pos = Vector3(0, 6, 0)
	for i in 60:
		p.step(1.0/30.0, {}, 100.0)
	assert_almost_eq(p.pos.y, 3.0, 0.05, "downed pawn crawls on terrain surface")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_integration`
Expected: FAIL — `Pawn` has no `terrain` property; y clamps to 0.

- [ ] **Step 3: Add the terrain field + preload to `pawn.gd`**

At the top of `shared/sim/pawn.gd` (with the other consts) add — `class_name Terrain` means it can be called directly, but preload guards import order in the headless runner:

```gdscript
const Terrain := preload("res://shared/sim/terrain.gd")
```

With the member vars (near `var grounded` at pawn.gd:28):

```gdscript
var terrain: TerrainGrid = null   # optional heightmap; null = flat (y ground plane at 0)
```

- [ ] **Step 4: Update the two clamp sites**

`shared/sim/pawn.gd:107-110` (in `step`), replace:

```gdscript
	if pos.y <= 0.0:
		pos.y = 0.0
		velocity.y = 0.0
		grounded = true
```

with:

```gdscript
	var ground := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= ground:
		pos.y = ground
		velocity.y = 0.0
		grounded = true
```

`shared/sim/pawn.gd:145-148` (in `_step_downed`), replace the identical block with:

```gdscript
	var ground := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= ground:
		pos.y = ground
		velocity.y = 0.0
		grounded = true
```

- [ ] **Step 5: Run to verify it passes + no regression**

Run: `godot --headless --path . -- --test --filter=terrain_integration`
Expected: PASS.
Run: `godot --headless --path . -- --test --filter=pawn`
Expected: existing pawn tests PASS (flat behaviour unchanged when `terrain == null`).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/pawn.gd tests/terrain_integration_test.gd
git commit -m "feat(m15): pawn ground clamp (step + _step_downed) resolves against terrain height"
```

---

## Task 7: `SimLoop` terrain wiring — fold into `_apply_platform_floor`, horizontal resolution, and thread to pawns; server + client injection

**Files:**
- Modify: `shared/sim/sim_loop.gd` (`var terrain`; set `p.terrain`; `_apply_platform_floor` at 147; `_step_normal` resolution at 76)
- Modify: `server/server_main.gd` (build grid at `_start_match`, set `_sim.terrain`)
- Modify: `client/prediction.gd` (forward a `terrain` handle, mirror the `structures` setter at prediction.gd:14-19)
- Modify/Test: `tests/terrain_integration_test.gd`

- [ ] **Step 1: Write the failing test (drive the full loop)**

Append to `tests/terrain_integration_test.gd`:

```gdscript
const SimLoop := preload("res://shared/sim/sim_loop.gd")

func test_sim_loop_folds_terrain_into_floor() -> void:
	var loop := SimLoop.new()
	loop.terrain = _plateau(4.0)
	var p := Pawn.new(1)
	p.pos = Vector3(0, 7, 0)
	loop.world.pawns[1] = p
	for i in 90:
		loop.step({1: {}}, 100.0)
	assert_almost_eq(p.pos.y, 4.0, 0.05, "SimLoop rests the pawn on the plateau via the floor chain")

func test_sim_loop_slope_blocks_horizontal_advance() -> void:
	# A wall-steep ramp: 0 m at x=-20 rising to 40 m at x=0 (way past MAX_WALKABLE_SLOPE_DEG).
	var g := TerrainGrid.new()
	g.cols = 21; g.rows = 21; g.spacing = 2.0; g.origin_x = -20.0; g.origin_z = -20.0
	var s := PackedFloat32Array(); s.resize(441)
	for zi in 21:
		for xi in 21:
			s[zi*21 + xi] = maxf(0.0, float(xi) * 4.0)   # 4 m per 2 m cell = ~63 deg
	g.samples = s
	var loop := SimLoop.new()
	loop.terrain = g
	var p := Pawn.new(1)
	p.pos = Vector3(-10, 0, 0)
	loop.world.pawns[1] = p
	var start_x := p.pos.x
	for i in 30:
		loop.step({1: {"move_x": 1.0, "move_y": 0.0}}, 100.0)   # drive +x into the cliff
	assert_true(p.pos.x < start_x + 8.0, "slope clips the advance up the cliff (did not run up it freely)")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_integration`
Expected: FAIL — `SimLoop` has no `terrain`; pawn either falls to 0 or runs up the cliff.

- [ ] **Step 3: Add `terrain` to `SimLoop` and thread it into pawn stepping**

In `shared/sim/sim_loop.gd`, after `var structures` (sim_loop.gd:13):

```gdscript
var terrain: TerrainGrid = null   # optional heightmap; folded into floor + horizontal resolution
```

In `SimLoop.step`, before `p.step(...)` (sim_loop.gd:26), set the handle each tick (cheap, and pawns spawn dynamically):

```gdscript
		p.terrain = terrain
		p.step(DT, cmd, world_half)
```

- [ ] **Step 4: Fold terrain into `_apply_platform_floor`**

In `shared/sim/sim_loop.gd`, `_apply_platform_floor` (sim_loop.gd:147-150), add terrain as the new baseline of the maxf chain (replacing the implicit 0.0):

```gdscript
func _apply_platform_floor(p: Pawn) -> void:
	var floor_y := Ladder.platform_floor(platforms, p.pos.x, p.pos.z, p.pos.y)
	floor_y = maxf(floor_y, Terrain.height_at(terrain, p.pos.x, p.pos.z))
	if structures != null:
		floor_y = maxf(floor_y, structures.floor_height_at(p.pos.x, p.pos.z, p.pos.y))
```

(Add `const Terrain := preload("res://shared/sim/terrain.gd")` at the top of `sim_loop.gd` if not already referenceable.) The three `elif`/grounded branches below (sim_loop.gd:155-161) already compare against `floor_y` and `maxf(floor_y, 0.0)` — leave them; with terrain in `floor_y` they now read the terrain surface. Change the `floor_y > 0.0` guard on line 155 to `floor_y > Terrain.height_at(terrain, p.pos.x, p.pos.z) - Ladder.ANCHOR_EPS`? No — simpler and correct: that branch's intent is "grounded when resting on a raised floor." Leave the two grounded branches referencing `floor_y` as-is; they already fire correctly because `floor_y` now includes terrain. Verify with `test_sim_loop_folds_terrain_into_floor`.

- [ ] **Step 5: Add terrain to horizontal resolution in `_step_normal`**

In `shared/sim/sim_loop.gd`, `_step_normal` (sim_loop.gd:74-108), apply `Terrain.resolve_movement` to the intended destination before/alongside the structure resolution. Replace the opening of `_step_normal`:

```gdscript
func _step_normal(p: Pawn, prev: Vector3, cmd: Dictionary, prev_grounded: bool) -> void:
	var intended := p.pos
	intended = Terrain.resolve_movement(terrain, prev, intended)
	if structures != null:
		var resolved: Vector3 = structures.resolve_movement(prev, intended)
```

The rest of `_step_normal` is unchanged. When `structures == null` (client prediction with no mirror, or a structureless map), add an `else: p.pos = intended` — check the existing tail: currently if `structures == null` the function falls through to `_apply_platform_floor(p)` without assigning `p.pos`. Since `intended` starts as `p.pos` and terrain resolution may change it, ensure `p.pos = intended` when structures is null. Add, right before `_apply_platform_floor(p)` at sim_loop.gd:108:

```gdscript
	elif structures == null:
		p.pos = intended
	_apply_platform_floor(p)
```

Re-read sim_loop.gd:76-108 during implementation and place the `p.pos = intended` assignment so the `structures == null` path applies the terrain-resolved position (today that path leaves `p.pos` as pawn.step left it).

- [ ] **Step 6: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=terrain_integration`
Expected: PASS.
Run full suite: `godot --headless --path . -- --test`
Expected: no regressions vs. master count (flat maps unaffected).

- [ ] **Step 7: Wire the server (`server/server_main.gd`)**

In `_start_match` (server_main.gd:228+), after `_map = MapDef.load_file(_map_path)` and after `_sim.structures = _store` (server_main.gd:238), build + inject the grid. Buildings are stamped from `_map.buildings` below this point, so the `load_for_map` origin_cell.y writeback (Task 5) must run **before** the building-stamp loop. Add right after `_map` is validated (before `_store`/stamp):

```gdscript
	# M15: build the heightmap grid (flat maps -> null) and flatten building pads BEFORE stamping.
	_terrain = Terrain.load_for_map(_map, "res://maps", _building_footprint_fn())
	_sim.terrain = _terrain
```

Add a `var _terrain: TerrainGrid = null` near `var _map` (server_main.gd:90), set `_store.terrain = _terrain` right after `_store = StructureStore.new(_catalog)` (Task 9 uses it), and add a helper `_building_footprint_fn()` returning a `Callable` that maps a building entry to its world AABB using the `BuildingCatalog` prefab extent. Locate the prefab-dimension source: `grep -n "prefab\|cells\|extent\|footprint\|size" shared/sim/building_catalog.gd` and build the AABB from the prefab's min/max cells rotated by yaw. If the catalog exposes no extent helper, add one (`BuildingCatalog.footprint_cells(prefab) -> {min:Vector3i,max:Vector3i}`) and unit-test it. For the demo map, buildings sit on flat plateaus (Task 12) so a conservative single-origin-cell footprint is acceptable if the extent helper proves large; prefer the true extent.

- [ ] **Step 8: Wire the client prediction (`client/prediction.gd`)**

Mirror the `structures` setter (prediction.gd:14-19). Add:

```gdscript
var terrain:
	set(v):
		_loop.terrain = v
	get:
		return _loop.terrain
```

Client build of the grid + assignment to `Prediction.terrain` happens in Task 11 (client_main), alongside the render mesh, so the same grid drives prediction and rendering.

- [ ] **Step 9: Run the server boot smoke on a flat map (no regression)**

Run: `godot --headless --path . -- --server --map=conquest_town --bots=0 --smoke-ticks=60 2>&1 | tail -5`
(Adjust flags to this repo's server smoke; `grep -n "smoke\|--server\|cmdline" server/server_main.gd` for the actual flags.)
Expected: boots clean, no script errors, exits.

- [ ] **Step 10: Commit**

```bash
git add shared/sim/sim_loop.gd server/server_main.gd client/prediction.gd tests/terrain_integration_test.gd
git commit -m "feat(m15): SimLoop terrain floor+resolution wiring; server/client injection"
```

---

## Task 8: Land vehicles ride terrain + slope-block

**Files:**
- Modify: `shared/sim/vehicle.gd` (add `var terrain`; clamp at vehicle.gd:131)
- Modify: `shared/sim/sim_loop.gd` (`step_vehicles` at 180-196: set `v.terrain`, fold terrain into floor, slope-block)
- Modify/Test: `tests/terrain_integration_test.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/terrain_integration_test.gd`:

```gdscript
const Vehicle := preload("res://shared/sim/vehicle.gd")

func _transport(pos: Vector3) -> Vehicle:
	var def := {"max_hp":600,"max_speed":20.0,"reverse_speed":6.0,"accel":10.0,"drag":8.0,
		"turn_rate":1.5,"respawn_ticks":450,"turret_offset":[0,1,0],"exit_offset":[2,0,0],
		"seats":[{"role":"driver","offset":[0,0,0]}]}
	return Vehicle.make(Vehicle.id_for(0), 0, def, 0, pos)

func test_vehicle_rests_on_terrain() -> void:
	var loop := SimLoop.new()
	loop.terrain = _plateau(3.0)
	var v := _transport(Vector3(0, 6, 0))
	loop.world.vehicles[v.id] = v
	for i in 90:
		loop.step_vehicles({v.id: {}}, 100.0)
	assert_almost_eq(v.pos.y, 3.0, 0.1, "vehicle settles on the plateau, not y=0")

func test_vehicle_cannot_climb_cliff() -> void:
	var g := TerrainGrid.new()
	g.cols = 21; g.rows = 21; g.spacing = 2.0; g.origin_x = -20.0; g.origin_z = -20.0
	var s := PackedFloat32Array(); s.resize(441)
	for zi in 21:
		for xi in 21:
			s[zi*21 + xi] = maxf(0.0, float(xi) * 4.0)
	g.samples = s
	var loop := SimLoop.new()
	loop.terrain = g
	var v := _transport(Vector3(-10, 0, 0))
	v.heading = PI / 2.0   # face +x (forward = sin,cos -> +x at heading pi/2)
	loop.world.vehicles[v.id] = v
	var start_x := v.pos.x
	for i in 60:
		loop.step_vehicles({v.id: {"move_y": 1.0, "move_x": 0.0}}, 100.0)
	assert_true(v.pos.x < start_x + 10.0, "cliff blocks the drive-up")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_integration`
Expected: FAIL — vehicle falls to 0 / climbs the cliff.

- [ ] **Step 3: Add terrain to `Vehicle`**

In `shared/sim/vehicle.gd`, add near the other vars (vehicle.gd:29):

```gdscript
var terrain: TerrainGrid = null
```

Add `const Terrain := preload("res://shared/sim/terrain.gd")` at the top. Replace the clamp at vehicle.gd:131-132:

```gdscript
	var ground := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= ground:
		pos.y = ground; velocity.y = 0.0
```

- [ ] **Step 4: Fold terrain into `step_vehicles`**

In `shared/sim/sim_loop.gd`, `step_vehicles` (sim_loop.gd:180-196): set `v.terrain`, add terrain slope-block on the horizontal move, and add terrain to the floor. Replace the body from `v.step(...)` through the floor clamp:

```gdscript
		var prev := v.pos
		v.terrain = terrain
		v.step(DT, vinputs.get(vid, {}), world_half)
		# Terrain slope-block: revert an advance that climbed a too-steep face.
		var t_res := Terrain.resolve_movement(terrain, prev, v.pos)
		if t_res != v.pos:
			v.pos = prev; v.speed = 0.0; v.velocity = Vector3.ZERO
		if structures != null:
			var seg := v.pos - prev
			var seg_len := seg.length()
			if seg_len > 0.0001:
				var m: Dictionary = structures.march(prev, seg / seg_len, seg_len)
				if bool(m["hit"]):
					v.pos = prev; v.speed = 0.0; v.velocity = Vector3.ZERO
		var floor_y := Ladder.platform_floor(platforms, v.pos.x, v.pos.z, v.pos.y)
		floor_y = maxf(floor_y, Terrain.height_at(terrain, v.pos.x, v.pos.z))
		if v.pos.y < floor_y:
			v.pos.y = floor_y; v.velocity.y = 0.0
```

- [ ] **Step 5: Run to verify it passes + no regression**

Run: `godot --headless --path . -- --test --filter=terrain_integration`
Expected: PASS.
Run: `godot --headless --path . -- --test --filter=vehicle`
Expected: existing vehicle tests PASS (flat behaviour unchanged).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/vehicle.gd shared/sim/sim_loop.gd tests/terrain_integration_test.gd
git commit -m "feat(m15): land vehicles ride terrain height + slope-block on too-steep faces"
```

---

## Task 9: Terrain occlusion in `StructureStore.march` (LOS + bullets + grenades + RPG + melee)

**Files:**
- Modify: `shared/sim/structure.gd` (`var terrain`; sample inside `march` DDA at structure.gd:221-249)
- Modify: `server/server_main.gd` (relax the `_store.count() > 0` LOS guard at server_main.gd:1766 to also fire when terrain is present)
- Create/Test: `tests/terrain_march_test.gd`

**Design:** Folding terrain into `march()` gives every LOS/bullet/grenade/RPG/melee caller (fire.gd:66,268; server_main.gd:1247,1588,1678,1766) terrain occlusion with one change. Each DDA iteration samples terrain at the current ray point; if the ray dips to/below terrain height there (within `max_dist`), return a terrain hit (`id: 0`, so callers that key on a struck piece id treat it as "blocked by world, no piece"). Inside a cutout, terrain returns `CUTOUT_FLOOR` (very low) so the ray never blocks — tunnels stay open.

- [ ] **Step 1: Write the failing test**

`tests/terrain_march_test.gd`:

```gdscript
extends TestCase
const StructureStore := preload("res://shared/sim/structure.gd")
const PieceCatalog := preload("res://shared/sim/piece_catalog.gd")
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# A hill ridge: flat 0 except a 10 m ridge along x=0.
func _ridge() -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 41; g.rows = 41; g.spacing = 2.0; g.origin_x = -40.0; g.origin_z = -40.0
	var s := PackedFloat32Array(); s.resize(1681)
	for zi in 41:
		for xi in 41:
			var wx := -40.0 + float(xi) * 2.0
			s[zi*41 + xi] = 10.0 if absf(wx) < 3.0 else 0.0
	g.samples = s
	return g

func _empty_store() -> StructureStore:
	var pc := PieceCatalog.new()   # empty catalog OK for a store with no pieces
	return StructureStore.new(pc)

func test_flat_terrain_does_not_block() -> void:
	var st := _empty_store()
	st.terrain = null
	# eye at 1.6 m looking flat across 30 m -> nothing blocks on a null (flat) grid
	var m := st.march(Vector3(-15, 1.6, 0), Vector3(1,0,0), 30.0)
	assert_false(bool(m["hit"]), "flat terrain, no structures -> clear")

func test_hill_blocks_low_sightline() -> void:
	var st := _empty_store()
	st.terrain = _ridge()
	# shooter and target both at ground eye height on opposite sides of the 10 m ridge
	var m := st.march(Vector3(-15, 1.6, 0), Vector3(1,0,0), 30.0)
	assert_true(bool(m["hit"]), "the 10 m ridge blocks a 1.6 m sightline across it")
	assert_true(float(m["dist"]) < 20.0, "blocked before reaching the far side")

func test_high_shot_clears_the_hill() -> void:
	var st := _empty_store()
	st.terrain = _ridge()
	# a shot from 15 m up, angled slightly down, clears the 10 m ridge
	var m := st.march(Vector3(-15, 15, 0), Vector3(1,0,0), 30.0)
	assert_false(bool(m["hit"]), "a sightline above the ridge is clear")

func test_cutout_does_not_block() -> void:
	var st := _empty_store()
	var g := _ridge()
	Terrain.carve_cutout(g, -3.0, 3.0, -3.0, 3.0, Terrain.CUTOUT_FLOOR)
	st.terrain = g
	var m := st.march(Vector3(-15, 1.6, 0), Vector3(1,0,0), 30.0)
	assert_false(bool(m["hit"]), "a cutout through the ridge opens the sightline (tunnel)")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=terrain_march`
Expected: FAIL — `StructureStore` has no `terrain`; ridge doesn't block.

- [ ] **Step 3: Add `terrain` to `StructureStore` and sample it in `march`**

In `shared/sim/structure.gd`, add near the other fields (structure.gd:19-23):

```gdscript
var terrain: TerrainGrid = null   # M15: heightmap occlusion sampled per DDA step in march()
```

Add `const Terrain := preload("res://shared/sim/terrain.gd")` at the top. In `march` (structure.gd:221-249), inside the `while t <= max_dist:` loop, after the structure-piece hit check and before advancing, sample terrain at the current ray point:

```gdscript
	while t <= max_dist:
		var id: int = _occupancy.get(cell, 0)
		if id != 0:
			var hit_t := _ray_piece(origin, d, _by_id[id])
			if hit_t >= 0.0 and hit_t <= max_dist:
				return {"hit": true, "dist": hit_t, "id": id}
		# M15 terrain occlusion: if the ray has dropped to/below the terrain surface at this column,
		# the world (hill) blocks it — exactly like striking a piece (id 0 = terrain, not a piece).
		if terrain != null and t > 0.0:
			var pt := origin + d * t
			if pt.y <= Terrain.height_at(terrain, pt.x, pt.z):
				return {"hit": true, "dist": t, "id": 0}
		# advance to the nearest boundary crossing
		...
```

Terrain sample cadence == DDA cell crossings (~one per 2 m cell) matches the 2 m sample spacing — bounded per-step cost, no unbounded scan (spec §4). `march_normal` (structure.gd:254) calls `march` and then indexes `_by_id[int(m["id"])]`; guard it: when `m["id"] == 0` (terrain hit) return a synthetic ground/hill normal instead of indexing `_by_id[0]`. Add at the top of `march_normal` after the `march` call:

```gdscript
	if int(m.get("id", 0)) == 0:
		var d0 := dir.normalized()
		return {"hit": true, "dist": float(m["dist"]), "id": 0,
			"point": origin + d0 * float(m["dist"]), "normal": Vector3(0, 1, 0)}
```

- [ ] **Step 4: Set `_store.terrain` on the server + relax the LOS guard**

In `server/server_main.gd` `_start_match`, after `_store = StructureStore.new(_catalog)` (server_main.gd:237):

```gdscript
	_store.terrain = _terrain
```

At server_main.gd:1766, the LOS check `_store != null and _store.count() > 0 and bool(_store.march(...))` skips terrain when there are no pieces. Relax to include terrain:

```gdscript
	if _store != null and (_store.count() > 0 or _store.terrain != null) and bool(_store.march(center, to / d, d)["hit"]):
```

Grep for sibling guards and apply the same relaxation where LOS/occlusion must respect terrain even with zero pieces: `grep -n "count() > 0" server/server_main.gd server/fire.gd`. Update each occlusion-purpose guard (leave any non-occlusion count guard alone).

- [ ] **Step 5: Run to verify it passes + no regression**

Run: `godot --headless --path . -- --test --filter=terrain_march`
Expected: PASS.
Run: `godot --headless --path . -- --test --filter=structure`
Expected: existing structure/march tests PASS (null terrain = unchanged).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/structure.gd server/server_main.gd tests/terrain_march_test.gd
git commit -m "feat(m15): terrain occlusion folded into StructureStore.march (LOS/bullets/grenades/RPG/melee)"
```

---

## Task 10: Bot slope-avoidance (stuck-detection + directional sidestep) — bot-only

**Files:**
- Modify: `bots/bot_driver.gd` (the fleet shell — owns per-tick pos + the sent move command)
- Create/Test: `tests/bot_slope_avoid_test.gd`

**Design (spec §6):** Not sim-authoritative — a bot obeys `Terrain.resolve_movement` exactly like a human; this only keeps it from *sticking*. Track the bot's actual horizontal displacement over ~0.5 s. If it commanded movement but advanced near-zero (clipped by a slope), pick the perpendicular with the shallower `Terrain.slope_at` (biased toward the objective bearing) and steer along it for a short window, then re-aim. Extract the decision into a pure, testable helper so the gate doesn't depend on emergent bot behaviour.

- [ ] **Step 1: Read the shell's per-tick movement to place the hook**

Run: `grep -n "func _process\|func _tick\|move_x\|move_y\|_send\|intent\|pos\b\|decide\|observe" bots/bot_driver.gd | head -40`
Identify where the bot reads its own pawn `pos` and where it builds the `{move_x, move_y}` it sends. The slope-avoidance override wraps the heading just before the command is built.

- [ ] **Step 2: Write the failing test (pure helper)**

`tests/bot_slope_avoid_test.gd`:

```gdscript
extends TestCase
const BotDriver := preload("res://bots/bot_driver.gd")
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# Cliff rising along +x; shallow along z.
func _cliff() -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 41; g.rows = 41; g.spacing = 2.0; g.origin_x = -40.0; g.origin_z = -40.0
	var s := PackedFloat32Array(); s.resize(1681)
	for zi in 41:
		for xi in 41:
			var wx := -40.0 + float(xi) * 2.0
			s[zi*41 + xi] = maxf(0.0, wx) * 4.0   # steep up +x, flat/downhill -x
	g.samples = s
	return g

func test_stuck_detection_true_when_clipped() -> void:
	# commanded to move 3 m but actually moved 0.1 m -> stuck
	assert_true(BotDriver.is_slope_stuck(Vector3(3,0,0).length(), Vector3(0.1,0,0).length()), "clipped ~0 -> stuck")
	assert_false(BotDriver.is_slope_stuck(3.0, 2.8), "moved freely -> not stuck")

func test_sidestep_picks_shallower_perpendicular() -> void:
	# heading straight into the +x cliff at origin; both perpendiculars are +z/-z (both flat here),
	# so it must return a valid non-forward heading that is walkable.
	var g := _cliff()
	var new_dir := BotDriver.slope_sidestep(g, Vector3(0,0,0), Vector3(1,0,0))
	assert_true(Terrain.slope_at(g, new_dir.x * 2.0, new_dir.z * 2.0) <= Terrain.MAX_WALKABLE_SLOPE_DEG,
		"sidestep heading points somewhere walkable")
	assert_true(absf(new_dir.z) > 0.5, "steers laterally (along the ridge), not straight into the cliff")
```

- [ ] **Step 3: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=bot_slope_avoid`
Expected: FAIL — `is_slope_stuck`/`slope_sidestep` not defined.

- [ ] **Step 4: Implement the pure helpers in `bots/bot_driver.gd`**

Add as `static` functions (pure, testable):

```gdscript
const SLOPE_STUCK_RATIO := 0.25   # advanced < 25% of commanded travel while trying -> stuck

## True when the bot commanded `commanded` metres of horizontal travel but only achieved `actual`.
static func is_slope_stuck(commanded: float, actual: float) -> bool:
	return commanded > 0.5 and actual < commanded * SLOPE_STUCK_RATIO

## Pick a sidestep heading when blocked: sample slope slightly ahead along both perpendiculars to
## `heading`, steer toward the shallower one, biased toward the perpendicular nearer the objective
## bearing (avoid backtracking). Two cheap extra samples, no search. Returns a unit XZ direction.
static func slope_sidestep(grid: TerrainGrid, pos: Vector3, heading: Vector3) -> Vector3:
	var h := Vector3(heading.x, 0.0, heading.z).normalized()
	if h == Vector3.ZERO:
		return heading
	var perp := Vector3(-h.z, 0.0, h.x)   # left perpendicular (XZ)
	var probe := grid.spacing * 1.5 if grid != null else 3.0
	var left := pos + perp * probe
	var right := pos - perp * probe
	var sl := Terrain.slope_at(grid, left.x, left.z)
	var sr := Terrain.slope_at(grid, right.x, right.z)
	return perp if sl <= sr else -perp
```

- [ ] **Step 5: Wire the override into the per-tick command build**

At the movement hook found in Step 1, track a short displacement history (last ~15 ticks of `pos`) and the last commanded move. When `is_slope_stuck(commanded_len, actual_disp_len)` is true and terrain is present, replace the movement heading with `slope_sidestep(...)` for a bounded window (~15-20 ticks), then clear the override and re-aim at the objective. Keep this entirely in the shell (view-only); the server still authoritatively clips via `Terrain.resolve_movement`. The bot must have the terrain grid — build it once at bot startup via `Terrain.load_for_map(map, "res://maps", Callable())` where the shell already loads `MAP_PATH` (bot_driver.gd:7) and store it on the driver.

- [ ] **Step 6: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=bot_slope_avoid`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add bots/bot_driver.gd tests/bot_slope_avoid_test.gd
git commit -m "feat(m15): bot slope-avoidance — stuck-detection + directional sidestep (bot-only)"
```

---

## Task 11: Client chunked terrain mesh (replace the flat PlaneMesh)

**Files:**
- Modify: `client/world_renderer.gd` (the ground-plane build at world_renderer.gd:303-330)
- Modify: `client/client_main.gd` (build the grid; pass to `Prediction.terrain`, the `StructureStore` mirror `.terrain`, and `world_renderer`)

**Design (spec §7):** Replace the single `PlaneMesh` with a grid of `MeshInstance3D` chunks (~64×64 samples ≈ 128 m tiles) generated from the `TerrainGrid`, 1 vertex per 2 m sample, smooth-shaded, keeping the existing two-tone green material. Chunking gives free per-instance frustum culling (matters for `proving_grounds`, `world_half=1000` ≈ 1M verts as one mesh). No collision shape — the sim is pure kinematic; the mesh is purely visual. When the grid is `null` (flat map), keep the current `PlaneMesh` path unchanged.

- [ ] **Step 1: Locate the client map-adopt site**

Run: `grep -n "structures\|StructureStore\|_prediction\|world_renderer\|adopt\|MapDef\|_map\b\|setup(" client/client_main.gd | head -40`
Find where the client builds its `StructureStore` mirror and sets `_prediction.structures`. The terrain grid is built at that same site and forwarded three ways.

- [ ] **Step 2: Build the client grid and forward it**

At that site in `client/client_main.gd`, after the map is adopted and the structure mirror built:

```gdscript
	# M15: build the SAME grid the server derived (same PNG + building list -> identical) so
	# prediction, occlusion mirror, and render agree. Flat maps -> null (unchanged flat behaviour).
	var terrain_grid := Terrain.load_for_map(_map, "res://maps", _client_building_footprint_fn())
	_prediction.terrain = terrain_grid
	_store_mirror.terrain = terrain_grid   # name per the client's actual StructureStore mirror var
	_world_renderer.set_terrain(terrain_grid)
```

Use the same `_building_footprint_fn` logic as the server (Task 7 step 7) so `origin_cell.y` writeback matches — factor it into a shared static (e.g. on `Terrain` or `BuildingCatalog`) to avoid divergence. Confirm the client renders building pieces from the (now flattened) `_map.buildings` origin_cells.

- [ ] **Step 3: Replace the ground build in `world_renderer.gd`**

At world_renderer.gd:303-330, wrap the current `PlaneMesh` build so it only runs when there is no terrain grid, and add the chunked build. Add a `var _terrain: TerrainGrid = null` and a `set_terrain(g)` setter that stores the grid and (re)builds the ground. Replace the `# Ground plane` block:

```gdscript
	if _terrain == null:
		# Flat map: keep the original single-plane two-tone ground (unchanged).
		var ground := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(side, side)
		ground.mesh = plane
		ground.material_override = gmat
		add_child(ground)
	else:
		_build_terrain_chunks(gmat)
```

Add `_build_terrain_chunks`:

```gdscript
const TERRAIN_CHUNK := 64   # samples per chunk edge (~128 m tiles at 2 m spacing)

func _build_terrain_chunks(mat: Material) -> void:
	var g := _terrain
	var cx := 0
	while cx < g.cols - 1:
		var cz := 0
		while cz < g.rows - 1:
			var x_end := mini(cx + TERRAIN_CHUNK, g.cols - 1)
			var z_end := mini(cz + TERRAIN_CHUNK, g.rows - 1)
			var mi := MeshInstance3D.new()
			mi.mesh = _chunk_mesh(g, cx, cz, x_end, z_end)
			mi.material_override = mat
			add_child(mi)
			cz += TERRAIN_CHUNK
		cx += TERRAIN_CHUNK

func _chunk_mesh(g: TerrainGrid, x0: int, z0: int, x1: int, z1: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for zi in range(z0, z1):
		for xi in range(x0, x1):
			var p00 := _vtx(g, xi,   zi)
			var p10 := _vtx(g, xi+1, zi)
			var p01 := _vtx(g, xi,   zi+1)
			var p11 := _vtx(g, xi+1, zi+1)
			# two triangles (CCW up)
			st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
			st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)
	st.generate_normals()
	return st.commit()

func _vtx(g: TerrainGrid, xi: int, zi: int) -> Vector3:
	var wx := g.origin_x + float(xi) * g.spacing
	var wz := g.origin_z + float(zi) * g.spacing
	return Vector3(wx, g.sample(xi, zi), wz)
```

Add `const Terrain`/`TerrainGrid` preloads at the top of `world_renderer.gd` as needed. Reorder `_build_scene` so `set_terrain` runs before the ground build, or make `set_terrain` idempotently rebuild.

- [ ] **Step 4: Visual smoke on game2 Xvfb (or laptop)**

Follow the game2 Xvfb screenshot recipe (memory: `blockfire-game2-screenshot-xvfb`): `Xvfb` + `--rendering-driver opengl3 --shot-after`. Boot a local server + this client on `conquest_proving_grounds` (after Task 12 regenerates the terrain), capture a screenshot, and confirm rolling hills render (not a flat plane), no z-fighting, buildings sit on their pads.

- [ ] **Step 5: Commit**

```bash
git add client/world_renderer.gd client/client_main.gd
git commit -m "feat(m15): client chunked terrain mesh from heightmap (replaces flat PlaneMesh); grid wired to prediction+occlusion+render"
```

---

## Task 12: `map_gen.py` heightmap generator + regenerate `conquest_proving_grounds`

**Files:**
- Modify: `tools/map_gen.py`
- Create: `maps/heightmaps/proving_grounds.png` (generated)
- Modify: `maps/conquest_proving_grounds.json` (regenerated — never hand-edited)

**Design (spec §9):** Add a procedural heightmap generator that writes a grayscale PNG for `proving_grounds` mixing every mechanic: gentle rolling hills, a valley (LOS + fall), a deliberately-too-steep cliff face, flat plateaus around the existing bases/points/buildings (auto-flatten correctness), and a short tunnel segment (cutout + building-prefab corridor + sculpted entrance ramp). Emit the `terrain` field into the map JSON and add the tunnel building placement with `terrain_cutout: true`.

- [ ] **Step 1: Read `map_gen.py` and its proving_grounds path**

Run: `sed -n '1,226p' tools/map_gen.py` — identify how it writes `maps/conquest_proving_grounds.json` (the existing bases/points/buildings), what image libs are available (`grep -n "import\|PIL\|Image\|numpy\|png" tools/map_gen.py`), and where to add a `--terrain`/proving_grounds terrain branch. Prefer the stdlib/`Pillow`/`numpy` already used; if none, write a raw PNG via `zlib`+`struct` (grayscale 8-bit) or add `numpy`+`Pillow` only if already a dev dependency (check `requirements*.txt`/`pyproject`).

- [ ] **Step 2: Add the heightmap generator**

Add a function that, given `world_half`, `spacing`, and feature descriptors, produces a `cols×rows` (cols=rows=`int(round(2*world_half/spacing))+1`) grayscale array in `[0,255]` and writes the PNG. Compose features as height fields (metres) then normalize to `height_min`/`height_scale`:

```python
def gen_proving_grounds_heightmap(world_half=1000.0, spacing=2.0):
    import math
    n = int(round(2 * world_half / spacing)) + 1
    def wx(i): return -world_half + i * spacing
    hm = [[0.0] * n for _ in range(n)]           # metres
    for zi in range(n):
        for xi in range(n):
            x, z = wx(xi), wx(zi)
            h = 0.0
            # gentle rolling hills (low-frequency sinusoids), amplitude ~6 m
            h += 6.0 * math.sin(x / 220.0) * math.cos(z / 260.0)
            # a valley basin around (-300, 300) [near point B], depth ~ -12 m
            dvb = math.hypot(x + 300.0, z - 300.0)
            if dvb < 180.0:
                h += -12.0 * (1.0 - dvb / 180.0)
            # a deliberately too-steep cliff wall near x=400..430, ~40 m over ~30 m run (>50 deg)
            if 400.0 <= x <= 430.0 and -200.0 <= z <= 200.0:
                h += 40.0 * (x - 400.0) / 30.0
            elif x > 430.0 and -200.0 <= z <= 200.0:
                h += 40.0
            # tunnel entrance ramps sculpted down to a portal at (0,-120) and (0,120)
            for pz in (-120.0, 120.0):
                dp = math.hypot(x - 0.0, z - pz)
                if dp < 40.0:
                    h += -8.0 * (1.0 - dp / 40.0)
            hm[zi][xi] = h
    # flat plateaus under bases/points/buildings are done by the runtime auto-flatten pass, but pin
    # the immediate base/point centres flat here too so the render reads intentional (belt + braces):
    flats = [(-900,0),(900,0),(-600,-400),(-300,300),(0,0),(300,-300),(600,400)]
    for (fx, fz) in flats:
        for zi in range(n):
            for xi in range(n):
                if math.hypot(wx(xi)-fx, wx(zi)-fz) < 45.0:
                    hm[zi][xi] = 0.0
    # normalize metres -> 0..255 given height_min / height_scale
    height_min, height_scale = -16.0, 64.0    # covers valley (-12..-16) up to cliff top (~40..48)
    px = [[max(0, min(255, int(round((hm[zi][xi] - height_min) / height_scale * 255.0))))
           for xi in range(n)] for zi in range(n)]
    return px, height_min, height_scale
```

Write the PNG (8-bit grayscale) to `maps/heightmaps/proving_grounds.png`. Use `Pillow` if available (`Image.fromarray(np.uint8(px), 'L').save(path)`) else a minimal `zlib`-deflated grayscale PNG writer.

- [ ] **Step 3: Emit the `terrain` field + tunnel building into the map JSON**

Where `map_gen.py` builds the `proving_grounds` dict, add:

```python
map_dict["terrain"] = {
    "heightmap": "heightmaps/proving_grounds.png",
    "sample_spacing": 2.0,
    "height_min": -16.0,
    "height_scale": 64.0,
}
# short tunnel corridor between the two sculpted portals (cutout owns the columns).
# origin_cell y is authored below grade; the runtime carve_cutout suppresses terrain there.
map_dict.setdefault("buildings", []).append({
    "prefab": "tunnel_corridor",        # an ordinary floor/wall/ceiling prefab (add to buildings/ if absent)
    "origin_cell": [0, -3, -60],        # ~-6 m, spans z -120..120 at x~0
    "yaw": 0,
    "terrain_cutout": True,
})
```

If no `tunnel_corridor` prefab exists (`ls buildings/`), author a minimal straight corridor prefab (floor + side walls + ceiling cells) in `buildings/tunnel_corridor.json` following an existing prefab's schema, or reuse the closest existing corridor prefab. Keep the cutout AABB (derived at load from the prefab footprint) fully covering the corridor.

- [ ] **Step 4: Regenerate the map + asset**

Run: `python tools/map_gen.py` (or the specific subcommand — `python tools/map_gen.py --help`).
Verify: `ls -l maps/heightmaps/proving_grounds.png` exists; `git diff --stat maps/conquest_proving_grounds.json` shows the new `terrain` block + tunnel building; the JSON still parses:
`godot --headless --path . -- --test --filter=map_` (map-load tests green).

- [ ] **Step 5: Deterministic map-load + parity check**

Add a focused test (fold into `tests/terrain_integration_test.gd`) that loads `conquest_proving_grounds`, builds the grid via `Terrain.load_for_map(map, "res://maps", Callable())`, and asserts a handful of known sample points (server-vs-client parity is guaranteed by identical code; assert the grid is non-null, valley point reads negative, cliff-top reads high, a base centre reads ~0 flat):

```gdscript
func test_proving_grounds_terrain_features() -> void:
	var m := MapDef.load_file("res://maps/conquest_proving_grounds.json")
	assert_ne(m, null, "map loads")
	var g := Terrain.load_for_map(m, "res://maps", Callable())
	assert_ne(g, null, "proving_grounds has terrain")
	assert_true(Terrain.height_at(g, -300, 300) < -2.0, "valley basin is below grade")
	assert_true(Terrain.height_at(g, 431, 0) > 20.0, "cliff top is high")
	assert_almost_eq(Terrain.height_at(g, -900, 0), 0.0, 1.0, "team-0 base is flat")
```

Run: `godot --headless --path . -- --test --filter=terrain_integration`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/map_gen.py maps/heightmaps/proving_grounds.png maps/conquest_proving_grounds.json buildings/tunnel_corridor.json tests/terrain_integration_test.gd
git commit -m "feat(m15): heightmap generator + regenerated proving_grounds terrain (hills/valley/cliff/plateaus/tunnel)"
```

---

## Task 13: Full suite green + 128-bot fleet gate on `proving_grounds` + visual validation

**Files:** none (verification only). Evidence goes in a session log under `docs/sessions/`.

- [ ] **Step 1: Full deterministic suite**

Run: `godot --headless --path . -- --test`
Expected: all green (master count + the new M15 tests, 0 failed). Fix any regression before proceeding.

- [ ] **Step 2: Re-profile the movement/occlusion hot path locally**

Run a short local bot match on `conquest_proving_grounds` and confirm no new `[perf]` bottleneck in `move`/`snap`/`march` (the M11 lesson — measure, don't assume). Use the repo's stress/telemetry harness: `grep -rn "perf\]\|tick_mean\|stress.sh\|run-m11-gate" docker/ ci/ | head`. Note per-section timings before/after.

- [ ] **Step 3: 128-bot fleet gate on game2 (run server in tmux)**

Per memory (`blockfire-test-host-game2`, `blockfire-remote-client-launch`): the dev session runs ON game2 — run docker/stress directly, in tmux (teardown SIGKILLs bg tasks). Launch the 128-bot gate against `conquest_proving_grounds` (the M11 gate script already plumbs `MAP`): `MAP=conquest_proving_grounds` via `ci/m11_buildings_test.sh` / `docker/run-m11-gate.sh` (adjust to the current gate runner — `grep -n "MAP\|proving" docker/run-m11-gate.sh ci/*.sh`).
Expected: `winner` reached, mean/peak tick < 33.3 ms, vehicles/pawns follow terrain under load, 0 script errors. Capture the `srvlog-*.log` path.

- [ ] **Step 4: Visual validation**

game2 Xvfb (or laptop .128/.194 per `blockfire-m7-client-playtest-hosts`): screenshot a live client on `conquest_proving_grounds` showing (a) a pawn standing on a hillside, (b) a sightline blocked by a hill (stand behind the ridge, confirm a bot across it can't be hit / shot stops on the slope), (c) buildings sitting flush on their pads, (d) the tunnel reading as a subterranean space. Save shots to the session log.

- [ ] **Step 5: Record the gate evidence**

Create `docs/sessions/2026-07-06-m15-heightmap-terrain.md` with: suite count, local perf deltas, the fleet-gate srvlog line (`winner=… peak tick=…ms`), and the screenshots. Update the M15 row in `docs/TASKS.md` status to reflect gate PASS (deterministic + fleet) with the human feel-playtest still owner-pending (per AGENTS.md §10, feel is an owner gate).

- [ ] **Step 6: Commit**

```bash
git add docs/sessions/2026-07-06-m15-heightmap-terrain.md docs/TASKS.md
git commit -m "docs(m15): fleet-gate + visual-validation evidence; TASKS.md status"
```

---

## Task 14: Land the work (AGENTS.md §11 — commit → fetch/reconcile → merge to master → push)

**Files:** none (git only).

- [ ] **Step 1: Confirm clean tree + full suite once more**

Run: `git status` (clean) and `godot --headless --path . -- --test` (green).

- [ ] **Step 2: Fetch + reconcile with master**

Run: `git fetch origin && git log --oneline origin/master -5`
If `origin/master` advanced, rebase/merge and re-run the full suite. Watch for concurrent work touching `sim_loop.gd`/`pawn.gd`/`structure.gd`/`map_def.gd` (per memory, M16 standing-bleed may land concurrently) — reconcile the shared seams carefully and re-run tests.

- [ ] **Step 3: Merge to master + push**

Per AGENTS.md land-your-work: fast-forward/merge the feature branch to `master`, then `git push origin master`. Do **not** push feature branches to origin unasked (memory: `blockfire-autonomy-preference`).

- [ ] **Step 4: Flip the spec status**

Edit `docs/specs/heightmap-terrain.md` line 3 status from "brainstorm-of-record, ratified" to note implementation landed (commit hash), leaving the human feel-gate as the remaining owner sign-off. Commit + push.

---

## Self-review notes (spec coverage map)

- §1 heightmap format → Tasks 3, 4, 12. §2 query module (`height_at`/`slope_at`/`resolve_movement`/`MAX_WALKABLE_SLOPE_DEG`) → Tasks 1, 2 (the three nav-forward-compat primitives). §3 server sim (pawn clamp, floor chain, horizontal resolution, vehicles, fall-damage-unchanged) → Tasks 6, 7, 8. §4 LOS/bullet occlusion → Task 9. §5 buildings + cutouts (auto-flatten pad, `terrain_cutout`) → Tasks 4, 5, 12. §6 bots (free terrain-following via §3 + narrow slope-avoidance) → Task 10. §7 client render (chunked mesh) → Task 11. §8 wire protocol (no change) → invariant, no task. §9 authoring + demo/gate map → Task 12. Gate → Tasks 1-10 (deterministic) + 13 (fleet + visual). Housekeeping → Task 0. Land-your-work → Task 14.
- No-placeholder: every code step shows real code; file:line anchors are current-master (verified). Where exact wiring depends on an unread file (`server_main` footprint fn, `client_main` adopt site, `bot_driver` per-tick hook, `map_gen.py` internals), the step names the grep to locate it and the exact interface to implement — no "TBD".
- Type consistency: `TerrainGrid` fields (`cols/rows/spacing/origin_x/origin_z/samples/cutouts`), `Terrain` statics (`height_at/slope_at/resolve_movement/build_grid/flatten_pad/carve_cutout/load_for_map/snap_pad_height/CUTOUT_FLOOR/MAX_WALKABLE_SLOPE_DEG`), and the `.terrain` handle on `Pawn`/`Vehicle`/`SimLoop`/`StructureStore`/`Prediction` are used identically across tasks.
