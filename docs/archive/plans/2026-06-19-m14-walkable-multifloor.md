# M14: Walkable Multi-Floor Structures — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make destructible structure pieces walkable in the vertical dimension — pawns stand on structure floors, walls block per-floor, staircases are walkable ramps, and falling off a height deals BattleBit-style fall damage.

**Architecture:** Extend the existing M4.5-P3 vertical-movement system (`Ladder.platform_floor` + `SimLoop._apply_platform_floor` + `Vault`) to read structure floor/stair surfaces from `StructureStore`, and make horizontal structure collision height-aware. All logic in `shared/sim/` (server-authoritative, deterministic; the client reconciles to the replicated `pawn.y` exactly as it already does for ladders/platforms — no client-prediction change, no protocol change). Fall damage is applied server-side through the existing `_apply_pawn_damage` pipeline.

**Tech Stack:** Godot 4.6 GDScript. Tests in `tests/*_test.gd` extending the global `TestCase`; run with `godot --headless --path . -- --test [--filter=<substr>]`. Tabs for indentation. Run `godot --headless --path . --import` once after adding any new `class_name` file before running tests.

**Conventions:** `BuildGrid.CELL_SIZE = 2.0`; a piece at grid cell `Y` spans world `[Y·2, Y·2+2)`. The walkable surface of a floor at cell `Y` is the cell **base plane** `Y·2`.

---

## File Structure

- **Create** `shared/sim/stairs.gd` — pure ramp-height math (`Stairs.run_dir`, `Stairs.surface_at`).
- **Create** `shared/sim/fall.gd` — pure fall-damage curve (`Fall.damage_for`).
- **Modify** `pieces/pieces.json` — add `"surface": true` to `bfloor`, `"ramp": true` to `bstair`.
- **Modify** `shared/sim/piece_catalog.gd` — carry + expose `is_flat_surface` / `is_ramp`.
- **Modify** `shared/sim/structure.gd` — add `floor_height_at`; make `_blocks_ground` height-aware and non-blocking for surface/ramp/passable pieces.
- **Modify** `shared/sim/sim_loop.gd` — fold structure floor into `_apply_platform_floor`; track per-pawn fall and set `landed_fall`.
- **Modify** `shared/sim/pawn.gd` — add `fall_peak_y` + `landed_fall` fields.
- **Modify** `shared/sim/revive.gd` — `is_instant_kill` includes `FALL`.
- **Modify** `server/server_main.gd` — apply `landed_fall` damage after `_sim.step`.
- **Modify** `client/art/building_kit.gd` — align the `bfloor` mesh top to the cell-base walkable plane.
- **Create** `buildings/test_twostory.json` + place it on `maps/conquest_arena_buildings.json` — a minimal walkable 2-story structure for the gate + playtest.
- **Create** docs: `docs/milestones/M14-walkable-multifloor.md`; append M14 to `docs/runbooks/playtest-checklist.md`.

---

## Task 1: `Stairs` pure ramp-height helper

**Files:**
- Create: `shared/sim/stairs.gd`
- Test: `tests/stairs_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/stairs_test.gd
extends TestCase
const Stairs := preload("res://shared/sim/stairs.gd")

func test_run_dir_quarter_turns() -> void:
	assert_eq(Stairs.run_dir(0), Vector2(0, 1), "yaw 0 ascends +Z")
	assert_eq(Stairs.run_dir(2), Vector2(1, 0), "yaw 2 ascends +X")
	assert_eq(Stairs.run_dir(4), Vector2(0, -1), "yaw 4 ascends -Z")
	assert_eq(Stairs.run_dir(6), Vector2(-1, 0), "yaw 6 ascends -X")

func test_surface_rises_low_to_high_edge() -> void:
	# Stair at cell (0,1,0): world cell spans x,z in [0,2], base y = 2.0, rising to 4.0 toward +Z (yaw 0).
	var cell := Vector3i(0, 1, 0)
	assert_almost_eq(Stairs.surface_at(cell, 0, 1.0, 0.0), 2.0, 0.01, "low edge = cell base")
	assert_almost_eq(Stairs.surface_at(cell, 0, 1.0, 2.0), 4.0, 0.01, "high edge = next floor")
	assert_almost_eq(Stairs.surface_at(cell, 0, 1.0, 1.0), 3.0, 0.01, "mid = halfway up")

func test_surface_respects_yaw_direction() -> void:
	var cell := Vector3i(0, 1, 0)
	# yaw 4 ascends -Z: high edge is the LOW z, low edge is the HIGH z.
	assert_almost_eq(Stairs.surface_at(cell, 4, 1.0, 0.0), 4.0, 0.01, "yaw4 low-z edge is the top")
	assert_almost_eq(Stairs.surface_at(cell, 4, 1.0, 2.0), 2.0, 0.01, "yaw4 high-z edge is the bottom")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=stairs_test`
Expected: FAIL (cannot load `res://shared/sim/stairs.gd`).

- [ ] **Step 3: Write minimal implementation**

```gdscript
# shared/sim/stairs.gd
class_name Stairs
extends Object
## Pure ramp-height math for walkable bstair pieces. A stair at cell Y rises CELL_SIZE across the cell
## from its low edge (surface Y*CELL_SIZE) to its high edge ((Y+1)*CELL_SIZE), along the run direction
## set by the piece yaw. Side-effect-free; shared by server + client. See docs/specs/walkable-multifloor.md.

## XZ ascent direction for a stair at the given yaw step. (yaw 0 ascends +Z; quarter-turns per 2 steps,
## matching BuildGrid's 8-step yaw and the bstair render orientation.)
static func run_dir(yaw: int) -> Vector2:
	var quarters := (yaw % BuildGrid.YAW_STEPS) / 2
	match quarters:
		0: return Vector2(0, 1)
		1: return Vector2(1, 0)
		2: return Vector2(0, -1)
		_: return Vector2(-1, 0)

## Walkable surface height at world (x,z) on a stair occupying `cell`, facing `yaw`. Linearly ramps
## from the cell base (low edge) to the next cell base (high edge) along run_dir.
static func surface_at(cell: Vector3i, yaw: int, x: float, z: float) -> float:
	var lo := BuildGrid.cell_min(cell)
	var lx := clampf((x - lo.x) / BuildGrid.CELL_SIZE, 0.0, 1.0)
	var lz := clampf((z - lo.z) / BuildGrid.CELL_SIZE, 0.0, 1.0)
	var d := run_dir(yaw)
	var f := d.x * lx + d.y * lz
	if d.x + d.y < 0.0:
		f += 1.0   # negative run dir: invert progress so the named edge is the top
	return float(cell.y) * BuildGrid.CELL_SIZE + clampf(f, 0.0, 1.0) * BuildGrid.CELL_SIZE
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . --import && godot --headless --path . -- --test --filter=stairs_test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/stairs.gd shared/sim/stairs.gd.uid tests/stairs_test.gd tests/stairs_test.gd.uid
git commit -m "feat(m14): Stairs pure ramp-height helper"
```

---

## Task 2: Piece-catalog `surface` / `ramp` flags

**Files:**
- Modify: `pieces/pieces.json` (add flags to `bfloor`, `bstair`)
- Modify: `shared/sim/piece_catalog.gd` (carry flags in `from_dict`; add `is_flat_surface` / `is_ramp`)
- Test: `tests/piece_catalog_test.gd` (append)

- [ ] **Step 1: Write the failing test** (append to `tests/piece_catalog_test.gd`)

```gdscript
func test_surface_and_ramp_flags() -> void:
	var cat: PieceCatalog = PieceCatalog.load_file("res://pieces/pieces.json")
	var floor_t := cat.index_of("bfloor")
	var stair_t := cat.index_of("bstair")
	var wall_t := cat.index_of("bwall")
	assert_true(cat.is_flat_surface(floor_t), "bfloor is a walkable flat surface")
	assert_false(cat.is_ramp(floor_t), "bfloor is not a ramp")
	assert_true(cat.is_ramp(stair_t), "bstair is a ramp")
	assert_false(cat.is_flat_surface(wall_t), "bwall is neither surface nor ramp")
	assert_false(cat.is_ramp(wall_t), "bwall is not a ramp")
```

> Note: if `PieceCatalog` has no `index_of(name)` helper, add it in Step 3 (a linear scan over `pieces` matching `id`). Check first: `grep -n "func index_of" shared/sim/piece_catalog.gd`.

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=piece_catalog_test`
Expected: FAIL (`is_flat_surface`/`is_ramp` not defined, or `index_of` missing).

- [ ] **Step 3: Implement**

In `pieces/pieces.json`, add `"surface": true` to the `bfloor` entry and `"ramp": true` to the `bstair` entry (alongside their existing fields).

In `shared/sim/piece_catalog.gd`, extend the normalized dict built in `from_dict` (the `c.pieces.append({...})` call) to include the two flags:

```gdscript
		c.pieces.append({"id": id, "half": height == "half", "health": health,
			"material": _MATERIALS[mat_str], "chunk_grid": grid,
			"structural": bool(p.get("structural", false)), "damage_types": dmg,
			"passable": bool(p.get("passable", false)),
			"surface": bool(p.get("surface", false)), "ramp": bool(p.get("ramp", false))})
```

Add the accessors (next to `passable_of`):

```gdscript
## True if pawns stand on this piece's flat top (a floor). Surface = the cell base plane.
func is_flat_surface(type: int) -> bool:
	return bool(pieces[type].get("surface", false))

## True if this piece is a walkable ramp (a staircase), surfaced via Stairs.surface_at.
func is_ramp(type: int) -> bool:
	return bool(pieces[type].get("ramp", false))
```

If `index_of` is missing, add:

```gdscript
## First piece type index whose id matches `name`, or -1.
func index_of(name: String) -> int:
	for i in pieces.size():
		if String(pieces[i]["id"]) == name:
			return i
	return -1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=piece_catalog_test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pieces/pieces.json shared/sim/piece_catalog.gd tests/piece_catalog_test.gd
git commit -m "feat(m14): catalog surface/ramp flags for floors and stairs"
```

---

## Task 3: `StructureStore.floor_height_at`

**Files:**
- Modify: `shared/sim/structure.gd` (add `floor_height_at` + the `FLOOR_REACH_EPS` const)
- Test: `tests/structure_floor_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/structure_floor_test.gd
extends TestCase
## floor_height_at returns the highest walkable structure surface at/below a query height.
const CAT := '{"pieces":[{"id":"bfloor","height":"full","health":350,"blocks":"both","surface":true},{"id":"bstair","height":"full","health":350,"blocks":"both","ramp":true},{"id":"bwall","height":"full","health":350,"blocks":"both"}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_no_structure_returns_neg_inf() -> void:
	assert_true(_store().floor_height_at(1.0, 1.0, 5.0) == -INF, "empty column -> -INF")

func test_floor_surface_is_cell_base() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 1, 0), 0, 99)   # bfloor (type 0) at cell y=1 -> surface 2.0
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 3.0), 2.0, 0.01, "floor at cell 1 -> surface 2.0")

func test_returns_highest_at_or_below_query() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 99)   # floor at y=0 -> surface 0.0
	s.place(2, 0, Vector3i(0, 1, 0), 0, 99)   # floor at y=1 -> surface 2.0
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 2.5), 2.0, 0.01, "standing high -> upper floor")
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 1.0), 0.0, 0.01, "below upper floor -> lower floor")

func test_stair_cell_returns_ramped_height() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 1, 0), 0, 99)   # bstair (type 1) at cell y=1, yaw 0 (ascends +Z)
	assert_almost_eq(s.floor_height_at(1.0, 0.0, 4.0), 2.0, 0.05, "stair low edge ~ base")
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 4.0), 3.0, 0.05, "stair mid ~ halfway")

func test_wall_is_not_a_surface() -> void:
	var s := _store()
	s.place(1, 2, Vector3i(0, 1, 0), 0, 99)   # bwall (type 2) at cell y=1
	assert_true(s.floor_height_at(1.0, 1.0, 3.0) == -INF, "a wall is not standable")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_floor_test`
Expected: FAIL (`floor_height_at` not defined).

- [ ] **Step 3: Implement** (add to `shared/sim/structure.gd`)

Add the const near the top consts:

```gdscript
const FLOOR_REACH_EPS := 0.35   # m; a pawn within this distance below a surface "catches" it (small step-up)
```

Add the method (near `ground_blocker_top`):

```gdscript
## Highest walkable structure surface at or below `y` at column (x,z); -INF if none. Floors yield
## their cell-base plane; stairs yield a ramped height. Bounded by building height (a handful of cells).
func floor_height_at(x: float, z: float, y: float) -> float:
	var col := BuildGrid.cell_of(Vector3(x, 0.0, z))
	var top := BuildGrid.cell_of(Vector3(x, y + FLOOR_REACH_EPS, z)).y
	var best := -INF
	for cy in range(top, -1, -1):
		var cell := Vector3i(col.x, cy, col.z)
		if not _occupancy.has(cell):
			continue
		var rec: Dictionary = _by_id[_occupancy[cell]]
		var t := int(rec["type"])
		var surf: float
		if _catalog.is_ramp(t):
			surf = Stairs.surface_at(cell, int(rec["yaw"]), x, z)
		elif _catalog.is_flat_surface(t):
			surf = float(cy) * BuildGrid.CELL_SIZE
		else:
			continue
		if surf <= y + FLOOR_REACH_EPS and surf > best:
			best = surf
	return best
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_floor_test`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/structure.gd tests/structure_floor_test.gd tests/structure_floor_test.gd.uid
git commit -m "feat(m14): StructureStore.floor_height_at (floors + stair ramps)"
```

---

## Task 4: Height-aware horizontal collision

**Files:**
- Modify: `shared/sim/structure.gd` (`_blocks_ground`)
- Test: `tests/structure_height_collision_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/structure_height_collision_test.gd
extends TestCase
## A wall blocks only at its own floor level; floors/stairs/doors are walk-through.
const CAT := '{"pieces":[{"id":"bwall","height":"full","health":350,"blocks":"both"},{"id":"bfloor","height":"full","health":350,"blocks":"both","surface":true},{"id":"bstair","height":"full","health":350,"blocks":"both","ramp":true},{"id":"bwall_door","height":"full","health":350,"blocks":"both","passable":true}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_upper_wall_blocks_only_upstairs() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(1, 1, 0), 0, 99)   # wall at cell (1,1,0): blocks at y in [2,4]
	# Pawn on the upper floor (y=2) is blocked walking into that cell:
	var up := s.resolve_movement(Vector3(1.0, 2.0, 1.0), Vector3(3.0, 2.0, 1.0))
	assert_true(up.distance_to(Vector3(3.0, 2.0, 1.0)) > 0.5, "upper-floor wall blocks at y=2")
	# Same column on the GROUND floor (y=0) is clear (the wall is one cell up):
	var down := s.resolve_movement(Vector3(1.0, 0.0, 1.0), Vector3(3.0, 0.0, 1.0))
	assert_eq(down, Vector3(3.0, 0.0, 1.0), "ground floor under an upper wall is clear")

func test_ground_wall_still_blocks() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(1, 0, 0), 0, 99)   # wall at cell (1,0,0)
	var r := s.resolve_movement(Vector3(1.0, 0.0, 1.0), Vector3(3.0, 0.0, 1.0))
	assert_true(r.distance_to(Vector3(3.0, 0.0, 1.0)) > 0.5, "ground wall blocks")

func test_floor_and_stair_and_door_do_not_block_walking() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(1, 0, 0), 0, 99)   # bfloor at ground
	s.place(2, 2, Vector3i(3, 0, 0), 0, 99)   # bstair at ground (x cell 3 -> world [6,8])
	s.place(3, 3, Vector3i(5, 0, 0), 0, 99)   # bwall_door at ground (x cell 5 -> world [10,12])
	assert_eq(s.resolve_movement(Vector3(1,0,1), Vector3(3,0,1)), Vector3(3,0,1), "floor cell walkable")
	assert_eq(s.resolve_movement(Vector3(5,0,1), Vector3(7,0,1)), Vector3(7,0,1), "stair cell walkable")
	assert_eq(s.resolve_movement(Vector3(9,0,1), Vector3(11,0,1)), Vector3(11,0,1), "door cell walkable")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_height_collision_test`
Expected: FAIL (`test_upper_wall_blocks_only_upstairs`: current `_blocks_ground` ignores `y`, so the ground case is wrongly blocked / the floor cells wrongly block).

- [ ] **Step 3: Implement** — replace `_blocks_ground` in `shared/sim/structure.gd`:

```gdscript
const FEET_EPS := 0.1   # m; lift the collision sample off the floor plane into the wall's cell band

func _blocks_ground(p: Vector3) -> bool:
	var cell := BuildGrid.cell_of(Vector3(p.x, p.y + FEET_EPS, p.z))
	if not _occupancy.has(cell):
		return false
	# Walk-through pieces: doors (aperture), floors (you stand on them), stairs (you walk up them).
	var t := int(_by_id[_occupancy[cell]]["type"])
	return not (_catalog.passable_of(t) or _catalog.is_flat_surface(t) or _catalog.is_ramp(t))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_height_collision_test`
Expected: PASS (3 tests). Also run the existing collision tests to confirm no regression:
`godot --headless --path . -- --test --filter=structure_door` and `--filter=structure_cover` — both PASS (ground-level `y=0` resolves to cell `Y=0` exactly as before).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/structure.gd tests/structure_height_collision_test.gd tests/structure_height_collision_test.gd.uid
git commit -m "feat(m14): height-aware structure collision (walls block per-floor)"
```

---

## Task 5: Pawns stand on structure floors + climb ramps (SimLoop integration)

**Files:**
- Modify: `shared/sim/sim_loop.gd` (`_apply_platform_floor`)
- Test: `tests/sim_loop_multifloor_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/sim_loop_multifloor_test.gd
extends TestCase
## A pawn falls onto a structure floor and stands; walking a stair ramp raises it to the next floor.
const CAT := '{"pieces":[{"id":"bfloor","height":"full","health":350,"blocks":"both","surface":true},{"id":"bstair","height":"full","health":350,"blocks":"both","ramp":true}]}'

func _sim_with_floor(cell: Vector3i, type: int, yaw: int) -> SimLoop:
	var sim := SimLoop.new()
	sim.structures = StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	sim.structures.place(1, type, cell, yaw, 99)
	return sim

func test_pawn_settles_onto_structure_floor() -> void:
	var sim := _sim_with_floor(Vector3i(0, 1, 0), 0, 0)   # bfloor at cell y=1 -> surface 2.0
	var p := Pawn.new(1)
	p.pos = Vector3(1.0, 3.0, 1.0)   # dropped in above the floor
	p.grounded = false
	sim.world.pawns[1] = p
	for _i in 30:
		sim.step({1: {}})
	assert_almost_eq(p.pos.y, 2.0, 0.05, "pawn lands on the structure floor at y=2")
	assert_true(p.grounded, "grounded on the floor")

func test_walking_a_stair_ramp_raises_the_pawn() -> void:
	var sim := _sim_with_floor(Vector3i(0, 0, 0), 1, 0)   # bstair at cell y=0, yaw 0 (ascends +Z)
	var p := Pawn.new(1)
	p.pos = Vector3(1.0, 0.0, 0.2)   # at the low edge of the stair
	sim.world.pawns[1] = p
	# Walk in +Z across the stair cell.
	for _i in 40:
		sim.step({1: {"move_y": 1.0}})
	assert_true(p.pos.y > 1.5, "walking up the ramp raised the pawn toward the next floor (got y=%f)" % p.pos.y)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . --import && godot --headless --path . -- --test --filter=sim_loop_multifloor_test`
Expected: FAIL (`_apply_platform_floor` ignores structures; pawn falls to y=0).

- [ ] **Step 3: Implement** — fold the structure floor into `_apply_platform_floor` in `shared/sim/sim_loop.gd`:

```gdscript
func _apply_platform_floor(p: Pawn) -> void:
	var floor_y := Ladder.platform_floor(platforms, p.pos.x, p.pos.z, p.pos.y)
	if structures != null:
		floor_y = maxf(floor_y, structures.floor_height_at(p.pos.x, p.pos.z, p.pos.y))
	if p.pos.y < floor_y:
		p.pos.y = floor_y
		p.velocity.y = 0.0
		p.grounded = true
	elif p.pos.y <= floor_y + Ladder.ANCHOR_EPS and floor_y > 0.0:
		p.grounded = true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=sim_loop_multifloor_test`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/sim_loop.gd tests/sim_loop_multifloor_test.gd tests/sim_loop_multifloor_test.gd.uid
git commit -m "feat(m14): pawns stand on structure floors and climb stair ramps"
```

---

## Task 6: `Fall` pure damage curve

**Files:**
- Create: `shared/sim/fall.gd`
- Test: `tests/fall_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/fall_test.gd
extends TestCase
const Fall := preload("res://shared/sim/fall.gd")

func test_safe_fall_no_damage() -> void:
	assert_eq(Fall.damage_for(0.0), 0, "no fall, no damage")
	assert_eq(Fall.damage_for(4.0), 0, "at the safe threshold, no damage")
	assert_eq(Fall.damage_for(3.5), 0, "below threshold, no damage")

func test_damage_scales_above_threshold() -> void:
	assert_true(Fall.damage_for(6.0) > 0, "above threshold deals damage")
	assert_true(Fall.damage_for(9.0) > Fall.damage_for(6.0), "more height -> more damage")

func test_big_fall_is_lethal() -> void:
	assert_true(Fall.damage_for(12.0) >= 100, "a ~12m fall is lethal (>=100)")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=fall_test`
Expected: FAIL (cannot load `res://shared/sim/fall.gd`).

- [ ] **Step 3: Implement**

```gdscript
# shared/sim/fall.gd
class_name Fall
extends Object
## Pure height-based fall-damage curve (BattleBit-style). Side-effect-free; the server applies the
## result via _apply_pawn_damage. See docs/specs/walkable-multifloor.md §4.

const SAFE_FALL := 4.0     # m; falls up to here are harmless
const DMG_PER_M := 13.5    # damage per metre above SAFE_FALL (~100 / lethal at ~11.4 m)

## Damage for a fall of `distance` metres (peak height minus landing height). 0 below SAFE_FALL.
static func damage_for(distance: float) -> int:
	if distance <= SAFE_FALL:
		return 0
	return int(round((distance - SAFE_FALL) * DMG_PER_M))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . --import && godot --headless --path . -- --test --filter=fall_test`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/fall.gd shared/sim/fall.gd.uid tests/fall_test.gd tests/fall_test.gd.uid
git commit -m "feat(m14): Fall pure height-damage curve"
```

---

## Task 7: Pawn fall tracking + SimLoop `landed_fall`

**Files:**
- Modify: `shared/sim/pawn.gd` (add fields)
- Modify: `shared/sim/sim_loop.gd` (`step` — track peak, set `landed_fall` on landing)
- Test: `tests/sim_loop_multifloor_test.gd` (append)

- [ ] **Step 1: Write the failing test** (append to `tests/sim_loop_multifloor_test.gd`)

```gdscript
func test_landed_fall_records_drop_distance() -> void:
	var sim := SimLoop.new()   # no structures: pawn falls to the y=0 ground
	var p := Pawn.new(1)
	p.pos = Vector3(0.0, 10.0, 0.0)
	p.grounded = false
	p.fall_peak_y = 10.0
	sim.world.pawns[1] = p
	var seen_fall := 0.0
	for _i in 60:
		sim.step({1: {}})
		if p.landed_fall > 0.0:
			seen_fall = p.landed_fall
	assert_almost_eq(seen_fall, 10.0, 0.3, "landed_fall ~ the 10 m drop to ground")

func test_no_landed_fall_when_already_grounded() -> void:
	var sim := SimLoop.new()
	var p := Pawn.new(1)
	p.pos = Vector3(0.0, 0.0, 0.0)
	p.grounded = true
	sim.world.pawns[1] = p
	sim.step({1: {"move_x": 1.0}})
	assert_almost_eq(p.landed_fall, 0.0, 0.001, "walking on the ground records no fall")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=sim_loop_multifloor_test`
Expected: FAIL (`fall_peak_y` / `landed_fall` not defined on Pawn).

- [ ] **Step 3: Implement**

In `shared/sim/pawn.gd`, add the two fields (near `climbing`/`vaulting`):

```gdscript
var fall_peak_y: float = 0.0   # highest y reached since leaving the ground (for fall damage)
var landed_fall: float = 0.0   # transient: fall distance on the tick a landing occurred, else 0 (not replicated)
```

In `shared/sim/sim_loop.gd`, in `step`, capture grounded before stepping and do fall accounting after the movement branch. Replace the per-pawn loop body so it reads:

```gdscript
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		if not p.alive:
			continue
		var prev := p.pos
		var prev_stance: int = p.stance
		var prev_grounded: bool = p.grounded
		var cmd: Dictionary = inputs.get(id, {})
		p.step(DT, cmd, world_half)
		if p.climbing:
			_step_climb(p, cmd)
		elif p.vaulting:
			p.pos = Vault.advance(p)
			if not p.vaulting:
				_apply_platform_floor(p)
		else:
			_step_normal(p, prev, cmd)
		if p.stance != prev_stance:
			p.last_stance_change_tick = tick
		_account_fall(p, prev_grounded)
```

Add the helper:

```gdscript
## Track airborne peak height and emit landed_fall (distance) on the tick a pawn lands. Climbing pawns
## are anchored to the ladder line (no fall). Server reads landed_fall to apply fall damage.
func _account_fall(p: Pawn, prev_grounded: bool) -> void:
	p.landed_fall = 0.0
	if p.climbing:
		p.fall_peak_y = p.pos.y
		return
	if p.grounded:
		if not prev_grounded:
			p.landed_fall = maxf(0.0, p.fall_peak_y - p.pos.y)
		p.fall_peak_y = p.pos.y
	else:
		p.fall_peak_y = maxf(p.fall_peak_y, p.pos.y)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=sim_loop_multifloor_test`
Expected: PASS (4 tests in the file now).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/pawn.gd shared/sim/sim_loop.gd tests/sim_loop_multifloor_test.gd
git commit -m "feat(m14): pawn fall tracking + SimLoop landed_fall"
```

---

## Task 8: Fall damage is lethal (Revive) + server applies it

**Files:**
- Modify: `shared/sim/revive.gd` (`is_instant_kill` includes `FALL`)
- Modify: `server/server_main.gd` (apply `landed_fall` after `_sim.step`)
- Test: `tests/revive_test.gd` (append — or create if absent)

- [ ] **Step 1: Write the failing test** (append to `tests/revive_test.gd`; if the file does not exist, create it with `extends TestCase`)

```gdscript
func test_fall_is_instant_kill_not_downed() -> void:
	assert_true(Revive.is_instant_kill(false, Revive.Source.FALL), "a lethal fall kills outright, not DBNO")
	assert_false(Revive.is_instant_kill(false, Revive.Source.BULLET), "bullets still down")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=revive_test`
Expected: FAIL (`is_instant_kill` returns false for FALL).

- [ ] **Step 3: Implement**

In `shared/sim/revive.gd`, update `is_instant_kill`:

```gdscript
static func is_instant_kill(headshot: bool, source: int) -> bool:
	return headshot or source == Source.BLAST or source == Source.FALL
```

In `server/server_main.gd`, immediately after the `_sim.step(inputs, _map.world_half)` call (currently line ~321), add the fall-damage pass:

```gdscript
	_apply_fall_damage()
```

And add the method (near `_apply_pawn_damage`):

```gdscript
## Apply height-based fall damage to any pawn that landed this tick (landed_fall set by SimLoop).
## Routes through the normal damage pipeline; a lethal fall kills outright (Revive.Source.FALL).
func _apply_fall_damage() -> void:
	for id in _clients:
		var p: Pawn = _sim.world.get_pawn(id)
		if p == null or not p.alive or p.is_downed:
			continue
		if p.landed_fall <= 0.0:
			continue
		var dmg := Fall.damage_for(p.landed_fall)
		if dmg > 0:
			_apply_pawn_damage(id, p, dmg, false, Revive.Source.FALL, id, 0)
```

- [ ] **Step 4: Run test + boot to verify**

Run: `godot --headless --path . -- --test --filter=revive_test`
Expected: PASS.
Then verify the server boots clean (server_main has no `class_name`, so it is only checked at runtime):
Run: `godot --headless --path . -- --server --port=27099 --map=conquest_arena_buildings --time-limit=20 > /tmp/m14boot.log 2>&1 & sleep 5; grep -iE "listening|SCRIPT ERROR|ERROR: res://" /tmp/m14boot.log | grep -v voice_opus; pkill -f port=27099`
Expected: `[server] listening …`, no script errors.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/revive.gd server/server_main.gd tests/revive_test.gd
git commit -m "feat(m14): lethal fall damage applied server-side"
```

---

## Task 9: Align the `bfloor` render mesh to the walkable plane

**Files:**
- Modify: `client/art/building_kit.gd` (the `bfloor` case)
- Test: visual (no unit test — geometry-only render change)

- [ ] **Step 1: Inspect the current `bfloor` mesh**

The walkable surface is the cell **base** plane (`Y·2`). The current `bfloor` renders a `2 × 0.3 × 2` slab at offset `(0, 0.15, 0)` — its top sits at `+0.3` within the cell, i.e. 0.3 m above the walkable plane, so a standing pawn's feet would float 0.3 m above the visible slab. Lower the slab so its **top** aligns to the cell base.

- [ ] **Step 2: Implement** — in `client/art/building_kit.gd`, change the `bfloor` case so the slab's top is at the cell base (slab hangs below the walkable plane):

```gdscript
		"bfloor":
			# Walkable surface = cell base plane (M14). Hang the slab just below it so the pawn's feet
			# rest on the visible top.
			root.add_child(_box("Floor", Vector3(CELL, 0.3, CELL), Vector3(0, -0.15, 0), bucket, COL_FLOOR))
```

- [ ] **Step 3: Verify it imports + the kit test still passes**

Run: `godot --headless --path . --import && godot --headless --path . -- --test --filter=building_kit`
Expected: PASS (or no building_kit test present — then just confirm import is clean: no SCRIPT ERROR).

- [ ] **Step 4: Commit**

```bash
git add client/art/building_kit.gd
git commit -m "feat(m14): align bfloor mesh top to the walkable cell-base plane"
```

---

## Task 10: Walkable 2-story test structure (for the gate + playtest)

**Files:**
- Create: `buildings/test_twostory.json`
- Modify: `maps/conquest_arena_buildings.json` (add the building)
- Test: integration boot + a placement check

- [ ] **Step 1: Author the prefab** — a 3×3 two-story box: ground walls + a door, a first floor (`bfloor`) at `y=1` over the interior, a `bstair` connecting ground→first floor, upper walls at `y=1`, a flat roof at `y=2`. Use only yaw 0/2.

```json
{
  "name": "test_twostory",
  "pieces": [
    {"type": "bwall_door",   "offset": [1, 0, 0], "yaw": 0},
    {"type": "bwall",        "offset": [0, 0, 0], "yaw": 0},
    {"type": "bwall",        "offset": [2, 0, 0], "yaw": 0},
    {"type": "bwall",        "offset": [0, 0, 1], "yaw": 2},
    {"type": "bwall",        "offset": [2, 0, 1], "yaw": 2},
    {"type": "bwall",        "offset": [0, 0, 2], "yaw": 0},
    {"type": "bwall",        "offset": [1, 0, 2], "yaw": 0},
    {"type": "bwall",        "offset": [2, 0, 2], "yaw": 0},
    {"type": "bstair",       "offset": [1, 0, 1], "yaw": 0},

    {"type": "bfloor", "offset": [0, 1, 0], "yaw": 0},
    {"type": "bfloor", "offset": [2, 1, 0], "yaw": 0},
    {"type": "bfloor", "offset": [0, 1, 1], "yaw": 0},
    {"type": "bfloor", "offset": [1, 1, 1], "yaw": 0},
    {"type": "bfloor", "offset": [2, 1, 1], "yaw": 0},
    {"type": "bfloor", "offset": [0, 1, 2], "yaw": 0},
    {"type": "bfloor", "offset": [1, 1, 2], "yaw": 0},
    {"type": "bfloor", "offset": [2, 1, 2], "yaw": 0},

    {"type": "bwall_window", "offset": [0, 1, 0], "yaw": 0},
    {"type": "bwall_window", "offset": [2, 1, 0], "yaw": 0},
    {"type": "bwall",        "offset": [0, 1, 2], "yaw": 0},
    {"type": "bwall_window", "offset": [2, 1, 2], "yaw": 0},

    {"type": "bfloor", "offset": [0, 2, 0], "yaw": 0},
    {"type": "bfloor", "offset": [1, 2, 0], "yaw": 0},
    {"type": "bfloor", "offset": [2, 2, 0], "yaw": 0},
    {"type": "bfloor", "offset": [0, 2, 1], "yaw": 0},
    {"type": "bfloor", "offset": [1, 2, 1], "yaw": 0},
    {"type": "bfloor", "offset": [2, 2, 1], "yaw": 0},
    {"type": "bfloor", "offset": [0, 2, 2], "yaw": 0},
    {"type": "bfloor", "offset": [1, 2, 2], "yaw": 0},
    {"type": "bfloor", "offset": [2, 2, 2], "yaw": 0}
  ]
}
```

> The stair at `(1,0,1)` is the interior cell; the ground floor under it is the natural ground (`y=0`), so it ramps from ground up to the `y=1` first floor. The interior ground cell `(1,0,1)` is the stair; surrounding ground cells are walls/door — walk in the door, up the stair, onto the first floor.

- [ ] **Step 2: Place it on the arena map** — add to the `buildings` array in `maps/conquest_arena_buildings.json`:

```json
    {"prefab": "test_twostory", "origin_cell": [6, 0, 4], "yaw": 0}
```

(World cells x 6..8, z 4..6 → world x 12..16, z 8..12 — clear of the other buildings and the central objective.)

- [ ] **Step 3: Boot + verify it stamps cleanly**

Run: `godot --headless --path . -- --server --port=27099 --map=conquest_arena_buildings --time-limit=20 > /tmp/m14map.log 2>&1 & sleep 5; grep -iE "listening|struct=|overlap|SCRIPT ERROR|ERROR: res://" /tmp/m14map.log | grep -v voice_opus | head; pkill -f port=27099`
Expected: `[server] listening …`, a `struct=` count that includes the new prefab's 30 pieces, no overlap/script errors.

- [ ] **Step 4: Commit**

```bash
git add buildings/test_twostory.json maps/conquest_arena_buildings.json
git commit -m "feat(m14): walkable 2-story test structure on the arena map"
```

---

## Task 11: Full suite, milestone doc, playtest checklist

**Files:**
- Create: `docs/milestones/M14-walkable-multifloor.md`
- Modify: `docs/runbooks/playtest-checklist.md` (append an M14 section)

- [ ] **Step 1: Run the full suite**

Run: `godot --headless --path . --import && godot --headless --path . -- --test`
Expected: `TESTS: N run, 0 failed` (N = prior count + the new tests).

- [ ] **Step 2: Headless multi-floor smoke** (server + a deploy-smoke human client driven up the stairs is out of scope for a script; instead confirm the sim mechanics via the unit tests above, and record the human-playtest steps in the checklist). Run a 12-bot arena smoke to confirm no runtime regression with the height-aware collision + floor queries live:

Run: `godot --headless --path . -- --server --port=27099 --map=conquest_arena_buildings --tickets=2000 --time-limit=120 > /tmp/m14srv.log 2>&1 & sleep 5; godot --headless --path . -- --bots --bot-count=12 --connect=127.0.0.1 --port=27099 --map=conquest_arena_buildings > /tmp/m14bots.log 2>&1 & sleep 35; grep "\[telemetry\]" /tmp/m14srv.log | tail -1; grep -iE "SCRIPT ERROR|ERROR: res://" /tmp/m14srv.log /tmp/m14bots.log | grep -v voice_opus | head; pkill -f port=27099`
Expected: bots connect + fight, tick_mean well under 33.3 ms, no script errors (bots are ground-level; floor queries add no breach).

- [ ] **Step 3: Write the milestone doc** `docs/milestones/M14-walkable-multifloor.md` with: objective, the §gate from the spec, status (implemented + unit-verified), the deterministic-test evidence (suite count), the headless smoke result, and the human-playtest checklist (walk in a door, climb the stair to the first floor, get blocked by an upper wall but not the ground below it, drop off the first floor / roof and take fall damage, lethal from the roof). Link `docs/specs/walkable-multifloor.md`.

- [ ] **Step 4: Append an M14 section to `docs/runbooks/playtest-checklist.md`** (append-only) with the human verification points above, including the fall-damage feel (safe ≤ 4 m, lethal ~12 m) and the stair-ascent direction (flag if a stair runs the wrong way → `Stairs.run_dir` base case is a one-line flip).

- [ ] **Step 5: Commit**

```bash
git add docs/milestones/M14-walkable-multifloor.md docs/runbooks/playtest-checklist.md
git commit -m "docs(m14): milestone doc + playtest checklist for walkable multi-floor"
```

---

## Self-Review

**Spec coverage:** §1 standable floors → Tasks 2,3,5. §2 height-aware collision → Task 4. §3 walkable-ramp stairs → Tasks 1,3,5. §4 fall damage → Tasks 6,7,8. §5 determinism/no-protocol/tick-budget → inherent (shared sim; Task 11 smoke confirms budget). §6 bots ground-level → Task 4 ground-safety test + Task 11 smoke. Gate (deterministic tests + 128-bot tick + human playtest) → Tasks 1–8 tests, Task 11 smoke + checklist. Out-of-scope items (ceiling bonk, bot multi-floor, finer grid, bladder, sloped-roof walkability) are intentionally not tasked.

**Type consistency:** `floor_height_at(x,z,y)`, `is_flat_surface(type)`, `is_ramp(type)`, `passable_of(type)`, `Stairs.run_dir(yaw)`, `Stairs.surface_at(cell,yaw,x,z)`, `Fall.damage_for(distance)`, `Pawn.fall_peak_y`/`landed_fall`, `Revive.Source.FALL`, `_apply_pawn_damage(vid,victim,dmg,headshot,source,killer_id,weapon_id)`, `_apply_fall_damage()` — names are used identically across tasks.

**Placeholder scan:** every code/test step contains complete code; no TBD/TODO. The one verification-only step (Task 9 visual) is explicitly a render change with no unit test, and Task 2 flags the `index_of` precondition to check.

**Note on the live client:** the local player's vertical position on structures is server-authoritative + reconciled (the client predicts with a bare `Pawn.step`, same as ladders/platforms today). If the LAN playtest shows vertical jitter while standing on an upper floor, a follow-up can give `client/prediction.gd` a structure-store reference + a floor snap — out of scope for v1.
