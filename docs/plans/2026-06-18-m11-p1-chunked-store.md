# M11 Phase 1 — Chunked StructureStore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip every `StructureStore` piece onto a 64-bit sub-cell **chunk alive-mask** as the single source of truth for destruction (spatial clear-where-hit + hole-aware ray-march + per-type damage immunity), replacing M4's scalar-HP/bucket model, and **re-gate M4** to prove no regression.

**Architecture:** A piece's destruction state becomes an N×N (N=`chunk_grid`, max 8 → 64 chunks) alive-mask held in one Godot `int`. Damage sources (bullet/explosive/melee) clear chunks within a world radius of the impact, projected onto the piece face; a piece is destroyed when its mask hits 0. The ray-march skips dead chunks (holes you can shoot through). All logic stays in `shared/` (server-authoritative, deterministic, unit-testable). Replication swaps M4's `OP_DAMAGE{id,bucket}` for `OP_CHUNK{id,mask:u64}` and carries the mask + `building_id` in the place/baseline record.

**Tech Stack:** Godot 4 / GDScript; headless `TestCase` suite (`tests/*_test.gd`); ENet message layer (`shared/net/protocol.gd`).

**Conventions:** Run the unit suite with `godot --headless --path . -- --test [--filter=<substr>]` (prints `TESTS: N run, M failed`, exit 0/1). Every `git commit` in this plan must end with the repo trailer (`Co-Authored-By:` + `Claude-Session:` per CLAUDE.md) — omitted from the step snippets for brevity. Work on branch `m11-destructible-buildings`.

**Scope note:** This is M11 Phase 1 of 4 (renumbered after the Option-B boundary decision): **P1 chunked store (this plan)** → P2 support cascade + collapse → P3 building prefab authoring + procedural art → P4 client cosmetic layer (blocked by M7). Bullets do NOT damage building pieces (per-type flag); player-built sandbag/wall keep bullet vulnerability. Movement collision still blocks while any chunk of a piece is alive (walk-through-holes is out of scope for P1).

---

### Task 1: `ChunkMask` pure helpers

**Files:**
- Create: `shared/sim/chunk_mask.gd`
- Test: `tests/chunk_mask_test.gd`

64-bit alive-mask helpers. Bit `row*grid + col` set = that chunk is intact; bit 0 = the face's
U/V-min corner. Spatial helpers project a world point onto the piece face (U = horizontal axis
rotated by `yaw`, V = world-up scaled to the piece's face `height`).

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/chunk_mask_test.gd
extends TestCase

func test_full_mask_and_count() -> void:
	assert_eq(ChunkMask.count(1), 1)
	assert_eq(ChunkMask.count(8), 64)
	assert_eq(ChunkMask.full_mask(1), 1)
	assert_eq(ChunkMask.popcount(ChunkMask.full_mask(8)), 64)   # all 64 bits set
	assert_eq(ChunkMask.popcount(ChunkMask.full_mask(4)), 16)

func test_clear_in_radius_clears_only_near_chunks() -> void:
	var cell := Vector3i(0, 0, 0)
	var grid := 8
	var full := ChunkMask.full_mask(grid)
	var height := 2.0
	# Impact at the bottom-left of a yaw=0 face (U=+X, V=+Y), small radius -> a few chunks gone.
	var impact := ChunkMask.chunk_center(cell, 0, 0, 0, grid, height)
	var after := ChunkMask.clear_in_radius(full, cell, 0, grid, height, impact, 0.3)
	assert_true(ChunkMask.popcount(after) < 64, "some chunks cleared")
	assert_true(ChunkMask.popcount(after) > 0, "not all chunks cleared")
	assert_false(ChunkMask.is_alive_at(after, cell, 0, grid, height, impact), "hit chunk is dead")

func test_clear_whole_face_destroys() -> void:
	var cell := Vector3i(0, 0, 0)
	var grid := 8
	var full := ChunkMask.full_mask(grid)
	var center := ChunkMask.chunk_center(cell, 0, 3, 3, grid, 2.0)
	var after := ChunkMask.clear_in_radius(full, cell, 0, grid, 2.0, center, 100.0)  # radius covers all
	assert_eq(after, 0)

func test_clear_is_monotonic_and_idempotent() -> void:
	var cell := Vector3i(2, 1, -3)
	var grid := 8
	var m := ChunkMask.full_mask(grid)
	var impact := ChunkMask.chunk_center(cell, 2, 4, 4, grid, 2.0)
	var once := ChunkMask.clear_in_radius(m, cell, 2, grid, 2.0, impact, 0.5)
	var twice := ChunkMask.clear_in_radius(once, cell, 2, grid, 2.0, impact, 0.5)
	assert_eq(once, twice, "re-clearing same impact is a no-op")
	assert_true(ChunkMask.popcount(once) <= ChunkMask.popcount(m), "bits only clear")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=chunk_mask`
Expected: FAIL — `ChunkMask` not defined / no assertions.

- [ ] **Step 3: Write minimal implementation**

```gdscript
# shared/sim/chunk_mask.gd
class_name ChunkMask
extends Object
## Pure 64-bit sub-cell alive-mask helpers (M11). A piece face is an NxN grid (N=grid, max 8 ->
## 64 chunks fit one 64-bit int). Bit (row*grid+col) set = chunk intact; bit 0 = U/V-min corner.
## U = horizontal axis rotated by yaw (face width); V = world-up scaled to the face `height`
## (full piece = CELL_SIZE, half piece = CELL_SIZE*0.5). Masks are bit patterns (full 8x8 == -1).
## See docs/specs/destructible-buildings.md §A.

const MAX_GRID := 8

static func count(grid: int) -> int:
	return grid * grid

static func full_mask(grid: int) -> int:
	var n := grid * grid
	if n >= 64:
		return ~0            # all 64 bits set (== -1 signed); bit pattern is what matters
	return (1 << n) - 1

static func popcount(mask: int) -> int:
	var c := 0
	for i in 64:
		if mask & (1 << i) != 0:
			c += 1
	return c

static func is_empty(mask: int) -> bool:
	return mask == 0

static func _u_axis(yaw: int) -> Vector3:
	var a := BuildGrid.yaw_radians(yaw)
	return Vector3(cos(a), 0.0, sin(a))

## World-space centre of chunk (row,col) on the piece at `cell`, oriented by `yaw`, face `height`.
static func chunk_center(cell: Vector3i, yaw: int, row: int, col: int, grid: int, height: float) -> Vector3:
	var origin := BuildGrid.cell_min(cell)
	var u := _u_axis(yaw)
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	return origin + u * ((float(col) + 0.5) * ustep) + Vector3(0.0, (float(row) + 0.5) * vstep, 0.0)

## Bit index of the chunk at world `point` on the piece face (clamped into the grid).
static func bit_at(cell: Vector3i, yaw: int, grid: int, height: float, point: Vector3) -> int:
	var rel := point - BuildGrid.cell_min(cell)
	var u := _u_axis(yaw)
	var col := clampi(int(rel.dot(u) / (BuildGrid.CELL_SIZE / float(grid))), 0, grid - 1)
	var row := clampi(int(rel.y / (height / float(grid))), 0, grid - 1)
	return row * grid + col

static func is_alive_at(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, point: Vector3) -> bool:
	return mask & (1 << bit_at(cell, yaw, grid, height, point)) != 0

## Clear every intact chunk whose centre is within `radius` (world) of `impact`. New mask.
static func clear_in_radius(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, impact: Vector3, radius: float) -> int:
	var m := mask
	for row in grid:
		for col in grid:
			var bit := row * grid + col
			if m & (1 << bit) == 0:
				continue
			if chunk_center(cell, yaw, row, col, grid, height).distance_to(impact) <= radius:
				m &= ~(1 << bit)
	return m
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=chunk_mask`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/chunk_mask.gd shared/sim/chunk_mask.gd.uid tests/chunk_mask_test.gd
git commit -m "feat(m11): ChunkMask pure 64-bit sub-cell alive-mask helpers"
```

---

### Task 2: `PieceCatalog` — chunk_grid, structural, damage_types

**Files:**
- Modify: `shared/sim/piece_catalog.gd`
- Test: `tests/piece_catalog_test.gd`

Add per-type `chunk_grid` (default 1), `structural` (default false), and a `damage_types` bitmask
(default = all three sources). Source bitflags live here (the catalog owns who-can-damage-what).

- [ ] **Step 1: Write the failing test**

```gdscript
# append to tests/piece_catalog_test.gd
func test_chunk_and_damage_fields_parse_with_defaults() -> void:
	var res := PieceCatalog.from_json_string('{"pieces":[{"id":"wall","height":"full","health":350,"material":"CONCRETE"}]}')
	assert_true(res["ok"])
	var c: PieceCatalog = res["catalog"]
	assert_eq(c.chunk_grid_of(0), 1)                         # default
	assert_eq(c.is_structural(0), false)                     # default
	assert_true(c.takes_damage(0, PieceCatalog.SRC_BULLET))  # default: all sources
	assert_true(c.takes_damage(0, PieceCatalog.SRC_EXPLOSIVE))

func test_explicit_chunk_and_damage_fields() -> void:
	var res := PieceCatalog.from_json_string('{"pieces":[{"id":"bwall","height":"full","health":800,"material":"CONCRETE","chunk_grid":8,"structural":true,"damage":["explosive","melee"]}]}')
	assert_true(res["ok"])
	var c: PieceCatalog = res["catalog"]
	assert_eq(c.chunk_grid_of(0), 8)
	assert_eq(c.is_structural(0), true)
	assert_false(c.takes_damage(0, PieceCatalog.SRC_BULLET), "building wall is bullet-immune")
	assert_true(c.takes_damage(0, PieceCatalog.SRC_EXPLOSIVE))
	assert_true(c.takes_damage(0, PieceCatalog.SRC_MELEE))

func test_rejects_bad_chunk_grid_and_damage() -> void:
	assert_false(PieceCatalog.from_json_string('{"pieces":[{"id":"w","height":"full","health":1,"chunk_grid":3}]}')["ok"], "chunk_grid must be 1,2,4,8")
	assert_false(PieceCatalog.from_json_string('{"pieces":[{"id":"w","height":"full","health":1,"damage":["lasers"]}]}')["ok"], "unknown damage source")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=piece_catalog`
Expected: FAIL — `chunk_grid_of`/`SRC_BULLET` not defined.

- [ ] **Step 3: Write minimal implementation**

In `shared/sim/piece_catalog.gd`, add the source bitflags near the material consts:

```gdscript
# Damage-source bitflags (M11). damage_types is an OR of these; default = all.
const SRC_BULLET := 1
const SRC_EXPLOSIVE := 2
const SRC_MELEE := 4
const SRC_ALL := SRC_BULLET | SRC_EXPLOSIVE | SRC_MELEE
const _SRC_NAMES := {"bullet": SRC_BULLET, "explosive": SRC_EXPLOSIVE, "melee": SRC_MELEE}
const _VALID_GRIDS := [1, 2, 4, 8]
```

Add accessors (next to `health_of`):

```gdscript
func chunk_grid_of(type: int) -> int:
	return int(pieces[type]["chunk_grid"])

func is_structural(type: int) -> bool:
	return bool(pieces[type]["structural"])

func takes_damage(type: int, source: int) -> bool:
	return (int(pieces[type]["damage_types"]) & source) != 0
```

In `from_dict`, after the `material` parse and before `c.pieces.append(...)`, parse the new fields
and extend the appended dict:

```gdscript
		var grid := int(p.get("chunk_grid", 1))
		if not _VALID_GRIDS.has(grid):
			return {"ok": false, "catalog": null, "error": "chunk_grid must be one of 1,2,4,8"}
		var dmg := SRC_ALL
		if p.has("damage"):
			var raw_d = p["damage"]
			if typeof(raw_d) != TYPE_ARRAY:
				return {"ok": false, "catalog": null, "error": "damage must be an array"}
			dmg = 0
			for s in raw_d:
				var key := String(s)
				if not _SRC_NAMES.has(key):
					return {"ok": false, "catalog": null, "error": "unknown damage source '%s'" % key}
				dmg |= _SRC_NAMES[key]
		c.pieces.append({"id": id, "half": height == "half", "health": health,
			"material": _MATERIALS[mat_str], "chunk_grid": grid,
			"structural": bool(p.get("structural", false)), "damage_types": dmg})
```

(Delete the old single-line `c.pieces.append(...)`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=piece_catalog`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/piece_catalog.gd tests/piece_catalog_test.gd
git commit -m "feat(m11): catalog chunk_grid/structural/damage_types + source flags"
```

---

### Task 3: Author player pieces as chunked + bullet-vulnerable

**Files:**
- Modify: `pieces/fortifications.json`
- Test: `tests/piece_catalog_test.gd`

Player-built pieces become 8×8 chunked, non-structural, and keep all damage sources (M4 behaviour:
bullets chew them down). This is what makes a wall take many hits rather than dying in one chunk-clear.

- [ ] **Step 1: Write the failing test**

```gdscript
# append to tests/piece_catalog_test.gd
func test_fortifications_file_is_chunked_and_bullet_vulnerable() -> void:
	var c := PieceCatalog.load_file("res://pieces/fortifications.json")
	assert_true(c != null)
	for t in c.size():
		assert_eq(c.chunk_grid_of(t), 8, "player pieces are 8x8 chunked")
		assert_true(c.takes_damage(t, PieceCatalog.SRC_BULLET), "player pieces keep M4 bullet damage")
		assert_false(c.is_structural(t), "player pieces are non-structural")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=fortifications_file`
Expected: FAIL — `chunk_grid_of` returns 1 (default).

- [ ] **Step 3: Update the data file**

```json
{
  "pieces": [
    {"id": "sandbag", "height": "half", "health": 150, "blocks": "both", "material": "METAL_THIN", "chunk_grid": 8, "structural": false, "damage": ["bullet", "explosive", "melee"]},
    {"id": "wall",    "height": "full", "health": 350, "blocks": "both", "material": "CONCRETE",   "chunk_grid": 8, "structural": false, "damage": ["bullet", "explosive", "melee"]}
  ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=fortifications_file`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pieces/fortifications.json tests/piece_catalog_test.gd
git commit -m "feat(m11): player fortifications become 8x8 chunked (bullet-vulnerable)"
```

---

### Task 4: `StructureStore` record — `chunks` + `building_id`, drop `health`

**Files:**
- Modify: `shared/sim/structure.gd`
- Test: `tests/structure_test.gd`

The record becomes `{id,type,cell,yaw,chunks,building_id,owner}`. `place()` is born with a full mask
and an optional `building_id` (default 0 = loose player piece). Remove the scalar `health` field and
the `DAMAGE_BUCKETS`/`bucket_of` machinery (replaced in Task 5).

- [ ] **Step 1: Update the failing test**

Replace `test_place_indexes_record` in `tests/structure_test.gd` and add a building_id test:

```gdscript
const CAT := '{"pieces":[{"id":"sandbag","height":"half","health":150,"chunk_grid":8},{"id":"wall","height":"full","health":350,"chunk_grid":8}]}'

func test_place_indexes_record() -> void:
	var s := _store()
	var rec := s.place(1, 1, Vector3i(2, 0, 3), 0, 7)   # type=wall, owner=7
	assert_eq(rec["id"], 1)
	assert_eq(rec["chunks"], ChunkMask.full_mask(8))     # born intact
	assert_eq(rec["building_id"], 0)                      # loose piece
	assert_eq(s.count(), 1)
	assert_eq(s.occupied(Vector3i(2, 0, 3)), true)
	assert_eq(s.owner_count(7), 1)

func test_place_with_building_id() -> void:
	var s := _store()
	var rec := s.place(5, 1, Vector3i(4, 0, 4), 0, 0, 42)
	assert_eq(rec["building_id"], 42)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: FAIL — record has `health`, not `chunks`/`building_id`; `place` takes 5 args.

- [ ] **Step 3: Update `structure.gd`**

Update the doc comment record shape, delete `const DAMAGE_BUCKETS` and `static func bucket_of(...)`,
and change `place`:

```gdscript
## Insert a record. Returns the record on success, {} if the cell is occupied.
func place(id: int, type: int, cell: Vector3i, yaw: int, owner: int, building_id: int = 0) -> Dictionary:
	if _occupancy.has(cell):
		return {}
	var rec := {"id": id, "type": type, "cell": cell, "yaw": yaw,
		"chunks": ChunkMask.full_mask(_catalog.chunk_grid_of(type)),
		"building_id": building_id, "owner": owner}
	return insert(rec)
```

`insert`, `remove`, region/owner indexes, `validate_place`, `resolve_movement`,
`ground_blocker_top` are unchanged (they key off `cell`/`type`, not `health`).

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: PASS (the two updated tests; other `structure_test` methods don't read `health`).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/structure.gd tests/structure_test.gd
git commit -m "feat(m11): store record carries chunks+building_id, drop scalar health"
```

---

### Task 5: `StructureStore.damage_chunks` (spatial, per-type immunity)

**Files:**
- Modify: `shared/sim/structure.gd`
- Test: `tests/structure_test.gd`

Replace `apply_damage` with `damage_chunks(id, source_type, impact, radius)`: clears chunks within
`radius` of `impact` (face-projected), honouring the piece's `damage_types`; removes the piece when
the mask reaches 0. The piece's face `height` (full vs half) is derived from the catalog.

- [ ] **Step 1: Write the failing test**

```gdscript
# append to tests/structure_test.gd
const CAT_IMMUNE := '{"pieces":[{"id":"bwall","height":"full","health":800,"chunk_grid":8,"damage":["explosive","melee"]}]}'

func test_damage_chunks_clears_and_destroys() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 0, 0), 0, 0)             # wall, 8x8
	var center := BuildGrid.cell_min(Vector3i(0, 0, 0)) + Vector3(1, 1, 0)
	var r1 := s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 0.4)
	assert_true(r1["hit"]); assert_true(r1["holed"]); assert_false(r1["destroyed"])
	assert_true(ChunkMask.popcount(r1["mask"]) < 64, "some chunks gone")
	assert_eq(s.count(), 1, "piece still present (partial)")
	var r2 := s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 100.0)  # clear everything
	assert_true(r2["destroyed"]); assert_eq(r2["mask"], 0)
	assert_eq(s.count(), 0, "piece removed at empty mask")
	assert_false(s.occupied(Vector3i(0, 0, 0)))

func test_damage_chunks_respects_immunity() -> void:
	var s := StructureStore.new(PieceCatalog.from_json_string(CAT_IMMUNE)["catalog"])
	s.place(1, 0, Vector3i(0, 0, 0), 0, 0)             # bullet-immune building wall
	var center := BuildGrid.cell_min(Vector3i(0, 0, 0)) + Vector3(1, 1, 0)
	var res := s.damage_chunks(1, PieceCatalog.SRC_BULLET, center, 100.0)
	assert_false(res["hit"], "bullets do not damage a building wall")
	assert_eq(s.count(), 1)
	assert_true(s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 100.0)["destroyed"])

func test_damage_chunks_unknown_id() -> void:
	var s := _store()
	assert_false(s.damage_chunks(99, PieceCatalog.SRC_EXPLOSIVE, Vector3.ZERO, 1.0)["hit"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: FAIL — `damage_chunks` not defined.

- [ ] **Step 3: Write the implementation**

Delete `func apply_damage(...)` and add (it needs the face height, so add a small helper):

```gdscript
## Face vertical extent of a piece: full = CELL_SIZE, half = CELL_SIZE*0.5.
func _face_height(type: int) -> float:
	return BuildGrid.CELL_SIZE * (0.5 if _catalog.is_half(type) else 1.0)

## Clear chunks within `radius` of world `impact` on piece `id`, if the source can damage this
## piece type. Returns {hit, holed, destroyed, mask}; removes the piece when the mask empties.
## Pure over store state + catalog — unit-testable.
func damage_chunks(id: int, source_type: int, impact: Vector3, radius: float) -> Dictionary:
	if not _by_id.has(id):
		return {"hit": false, "holed": false, "destroyed": false, "mask": 0}
	var rec: Dictionary = _by_id[id]
	var type := int(rec["type"])
	var before := int(rec["chunks"])
	if not _catalog.takes_damage(type, source_type):
		return {"hit": false, "holed": false, "destroyed": false, "mask": before}
	var grid := _catalog.chunk_grid_of(type)
	var after := ChunkMask.clear_in_radius(before, rec["cell"], int(rec["yaw"]), grid,
		_face_height(type), impact, radius)
	if after == before:
		return {"hit": false, "holed": false, "destroyed": false, "mask": before}
	if after == 0:
		remove(id)
		return {"hit": true, "holed": true, "destroyed": true, "mask": 0}
	rec["chunks"] = after
	return {"hit": true, "holed": true, "destroyed": false, "mask": after}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/structure.gd tests/structure_test.gd
git commit -m "feat(m11): StructureStore.damage_chunks (spatial clear + per-type immunity)"
```

---

### Task 6: Hole-aware ray-march

**Files:**
- Modify: `shared/sim/structure.gd`
- Test: `tests/structure_march_test.gd`

A ray that strikes a piece at a **dead** chunk passes through (a hole); a live chunk blocks as
before. With the default `chunk_grid=1` (single chunk) the behaviour is identical to M4, so existing
march tests keep passing.

- [ ] **Step 1: Write the failing test**

```gdscript
# append to tests/structure_march_test.gd  (use a chunked wall)
func _chunked_store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string('{"pieces":[{"id":"wall","height":"full","health":350,"chunk_grid":8}]}')["catalog"])

func test_march_passes_through_a_hole() -> void:
	var s := _chunked_store()
	s.place(1, 0, Vector3i(2, 0, 0), 0, 0)   # wall cell at x in [4,6]
	# A ray straight down +X at y=1 hits the wall face.
	var origin := Vector3(0.0, 1.0, 5.0)
	var dir := Vector3(1, 0, 0)
	assert_true(s.march(origin, dir, 20.0)["hit"], "intact wall blocks")
	# Blast a hole right where that ray crosses the face, then re-march.
	var face_hit := Vector3(4.0, 1.0, 5.0)
	s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, face_hit, 0.3)
	assert_false(s.march(origin, dir, 20.0)["hit"], "ray now passes through the hole")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_march`
Expected: FAIL — second assert fails (march still blocks at the dead chunk).

- [ ] **Step 3: Update `march`**

In `march`, where it currently accepts a hit, gate it on the chunk being alive:

```gdscript
			if id != 0:
				var hit_t := _ray_piece(origin, d, _by_id[id])
				if hit_t >= 0.0 and hit_t <= max_dist and hit_t < best_t:
					var rec: Dictionary = _by_id[id]
					var pt := origin + d * hit_t
					var grid := _catalog.chunk_grid_of(int(rec["type"]))
					if ChunkMask.is_alive_at(int(rec["chunks"]), rec["cell"], int(rec["yaw"]),
							grid, _face_height(int(rec["type"])), pt):
						best_t = hit_t
						best_id = id
```

(Only the inner `if id != 0:` block changes — the surrounding `while`/`seen` loop is untouched.)

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_march`
Expected: PASS (new test + existing single-chunk march tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/structure.gd tests/structure_march_test.gd
git commit -m "feat(m11): hole-aware ray-march (shots pass through dead chunks)"
```

---

### Task 7: Protocol — `chunks`+`building_id` record, `OP_CHUNK`

**Files:**
- Modify: `shared/net/protocol.gd`
- Test: `tests/protocol_test.gd` (or the existing protocol structure test — see Task 10)

The wire record swaps `health:u16` for `chunks:u64` + `building_id:u16`. `OP_DAMAGE` is renamed
`OP_CHUNK` (value stays 2) and carries `{id:u16, mask:u64}`.

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/protocol_test.gd  (append; create the file if absent — extends TestCase)
func test_structure_record_roundtrip_with_chunks() -> void:
	var rec := {"id": 7, "type": 1, "cell": Vector3i(3, 0, -4), "yaw": 5,
		"chunks": ChunkMask.full_mask(8), "building_id": 42, "owner": 9}
	var bytes := Protocol.encode_structure_delta(Protocol.OP_PLACE, rec)
	var d := Protocol.decode_structure_delta(bytes)
	assert_eq(d["op"], Protocol.OP_PLACE)
	assert_eq(d["rec"]["chunks"], ChunkMask.full_mask(8))
	assert_eq(d["rec"]["building_id"], 42)
	assert_eq(d["rec"]["cell"], Vector3i(3, 0, -4))

func test_op_chunk_roundtrip() -> void:
	var mask := ChunkMask.full_mask(8) & ~0b1011    # a few chunks cleared
	var bytes := Protocol.encode_structure_delta(Protocol.OP_CHUNK, {"id": 12, "mask": mask})
	var d := Protocol.decode_structure_delta(bytes)
	assert_eq(d["op"], Protocol.OP_CHUNK)
	assert_eq(d["id"], 12)
	assert_eq(d["mask"], mask)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=protocol_test`
Expected: FAIL — `OP_CHUNK` not defined / record carries `health`.

- [ ] **Step 3: Update `protocol.gd`**

Rename the op constant and update the codecs:

```gdscript
const OP_CHUNK := 2   ## STRUCTURE_DELTA payload {id u16, mask u64} — sub-cell alive-mask (M11)
```

`_put_record` / `_get_record` — replace the `health` line:

```gdscript
# in _put_record, replace `buf.put_u16(int(rec["health"]))` with:
	buf.put_u64(int(rec["chunks"]))
	buf.put_u16(int(rec["building_id"]))
```
```gdscript
# in _get_record, replace `var health := r.get_u16()` and the returned dict:
	var chunks := r.get_u64()
	var building_id := r.get_u16()
	var owner := r.get_u16()
	return {"id": id, "type": type, "cell": cell, "yaw": yaw, "chunks": chunks, "building_id": building_id, "owner": owner}
```

`encode_structure_delta` / `decode_structure_delta` — swap the `OP_DAMAGE` branch:

```gdscript
# encode
	elif op == OP_CHUNK:
		buf.put_u16(int(rec["id"]))
		buf.put_u64(int(rec["mask"]))
```
```gdscript
# decode
	elif op == OP_CHUNK:
		var id := r.get_u16()
		return {"op": op, "id": id, "mask": r.get_u64()}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=protocol_test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/net/protocol.gd tests/protocol_test.gd
git commit -m "feat(m11): wire chunks+building_id record and OP_CHUNK(mask) delta"
```

---

### Task 8: Bot mirror — apply `OP_CHUNK`

**Files:**
- Modify: `bots/bot_driver.gd`
- Test: `tests/bot_mirror_test.gd`

The bot's local structure mirror stores the chunk mask and updates it on `OP_CHUNK` (must NOT remove
the record; removal is its own op). PLACE/baseline records already carry `chunks` via Task 7.

- [ ] **Step 1: Write the failing test**

```gdscript
# append to tests/bot_mirror_test.gd
func test_apply_op_chunk_updates_mask_in_place() -> void:
	var structs := {}
	var rec := {"id": 3, "type": 1, "cell": Vector3i(0, 0, 0), "yaw": 0,
		"chunks": ChunkMask.full_mask(8), "building_id": 0, "owner": 1}
	BotDriver.apply_structure_delta(structs, {"op": Protocol.OP_PLACE, "rec": rec})
	assert_eq(structs[3]["chunks"], ChunkMask.full_mask(8))
	var newmask := ChunkMask.full_mask(8) & ~0b111
	BotDriver.apply_structure_delta(structs, {"op": Protocol.OP_CHUNK, "id": 3, "mask": newmask})
	assert_eq(structs[3]["chunks"], newmask)
	assert_true(structs.has(3), "OP_CHUNK must not remove the record")
```

(If the bot class is referenced by a different `class_name`, match the existing test's usage.)

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=bot_mirror`
Expected: FAIL — handler still reads `d["bucket"]`.

- [ ] **Step 3: Update `apply_structure_delta`**

```gdscript
	elif op == Protocol.OP_CHUNK:
		var id: int = d["id"]
		if structs.has(id):
			structs[id]["chunks"] = d["mask"]
```

(Replace the old `OP_DAMAGE`/`bucket` branch. Update the doc comment to say "OP_CHUNK updates the
record's chunk mask in place".)

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=bot_mirror`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bots/bot_driver.gd tests/bot_mirror_test.gd
git commit -m "feat(m11): bot mirror applies OP_CHUNK mask updates"
```

---

### Task 9: Server — spatial damage + `OP_CHUNK` emission

**Files:**
- Modify: `server/server_main.gd`

Rewire the three call sites onto `damage_chunks` and emit the mask. Remove the bucket bookkeeping.

- [ ] **Step 1: Add a bullet-carve constant**

Near `MAX_STRUCTURE_DELTAS_PER_TICK`:

```gdscript
const BULLET_CARVE_RADIUS := 0.30   # m: chunks a single blocked bullet clears (M11)
```

- [ ] **Step 2: Rewrite `_damage_structure` to take a source + impact**

```gdscript
## Apply chunk damage to a piece from `source` at world `impact` (radius `radius`) and record the
## side effects for end-of-tick replication (_emit_structure_deltas). Destruction queues a remove +
## frees the cell (in damage_chunks); a non-lethal hole marks the piece for a chunk-mask resend.
func _damage_structure(id: int, source: int, impact: Vector3, radius: float) -> void:
	var cell := _cell_of_struct(id)       # capture BEFORE possible removal
	var res := _store.damage_chunks(id, source, impact, radius)
	if not res["hit"]:
		return
	_dmg += 1
	if res["destroyed"]:
		_destroyed += 1
		_pending_removes.append({"id": id, "cell": cell})
		_dmg_touched.erase(id)
		_remove_c4_on_cell(cell)
	else:
		_dmg_touched[id] = true
```

Delete the `_last_bucket` declaration (line ~119) and any other reference to it.

- [ ] **Step 3: Update the blast struct loop and the fire-cover call sites**

In `_apply_blast` (the structure loop, ~line 1294), replace the per-piece falloff-amount call:

```gdscript
	if struct_dmg > 0 and struct_radius > 0.0:
		for sid in _store.ids_in_radius(center, struct_radius):
			_damage_structure(sid, PieceCatalog.SRC_EXPLOSIVE, center, struct_radius)
```

(The `struct_dmg`/`falloff_damage` lines for structures are no longer used — the radius carve
replaces scalar falloff. Leave the pawn-splash falloff untouched.)

In the fire/cover path (~line 483 and ~488, where it currently calls `_damage_structure(block_id, body_dmg)` / `_damage_structure(block_id, int(split["piece_damage"]))`), the bullet now carves at the march hit point:

```gdscript
	var hit_pt := shot_origin + shot_dir * dist_struct   # impact on the blocking piece
	_damage_structure(block_id, PieceCatalog.SRC_BULLET, hit_pt, BULLET_CARVE_RADIUS)
```

(Use the variable names already in scope for the shot origin/dir and the structure hit distance from
the `march` result — confirm them when editing; they feed `_ray_piece` today.)

- [ ] **Step 4: Rewrite `_emit_structure_deltas` to send the mask**

```gdscript
func _emit_structure_deltas() -> void:
	var budget := MAX_STRUCTURE_DELTAS_PER_TICK
	while not _pending_removes.is_empty() and budget > 0:
		var r: Dictionary = _pending_removes.pop_front()
		_removes += 1
		_emit_structure_delta(Protocol.OP_REMOVE, {"id": r["id"]}, r["cell"])
		budget -= 1
	for id in _dmg_touched.keys():
		if budget <= 0:
			break
		var rec := _store.get_record(id)
		if rec.is_empty():
			_dmg_touched.erase(id)
			continue
		_emit_structure_delta(Protocol.OP_CHUNK, {"id": id, "mask": int(rec["chunks"])}, rec["cell"])
		_dmg_touched.erase(id)
		budget -= 1
```

- [ ] **Step 5: Run the full suite (compile + behaviour)**

Run: `godot --headless --path . -- --test`
Expected: server compiles; any remaining failures are stale tests fixed in Task 10. Note the count.

- [ ] **Step 6: Commit**

```bash
git add server/server_main.gd
git commit -m "feat(m11): server applies spatial chunk damage and emits OP_CHUNK"
```

---

### Task 10: Fix tests broken by the refactor; full suite green

**Files:**
- Modify: any `tests/*_test.gd` still referencing `health`/`bucket`/`apply_damage`/`OP_DAMAGE`
  (candidates from the codebase: `tests/structure_cover_test.gd`, `tests/structure_store_test.gd`,
  and any protocol test that asserted the old structure record).

- [ ] **Step 1: Find the stragglers**

Run: `grep -rln "apply_damage\|bucket_of\|OP_DAMAGE\|\"health\"\|\\[\"health\"\\]" tests/`
Then run the full suite to see exact failures:
`godot --headless --path . -- --test`

- [ ] **Step 2: Update each failing test**

For each: replace `apply_damage(id, n)` with `damage_chunks(id, PieceCatalog.SRC_EXPLOSIVE, <impact>, <radius>)`; replace `health` assertions with `chunks`/`popcount`/`damage_chunks(...)["destroyed"]`; ensure any inline catalog JSON that needs partial damage sets `"chunk_grid":8`. Keep each test's intent identical — only the damage API changes.

Example (cover test that destroyed a piece to prove the ray re-passes):
```gdscript
	# was: store.apply_damage(id, 9999)
	store.damage_chunks(id, PieceCatalog.SRC_EXPLOSIVE, BuildGrid.world_of(cell), 100.0)
```

- [ ] **Step 3: Run the full suite to verify green**

Run: `godot --headless --path . -- --test`
Expected: `TESTS: N run, 0 failed` (N ≥ the prior M4-P2 count of 140 + the new M11 tests).

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test(m11): migrate structure tests to chunk-mask API"
```

---

### Task 11: M4 re-gate (no-regression evidence)

**Files:**
- Run only (no edits); record evidence in `docs/milestones/M11-destructible-buildings.md`.

The unify refactor touched M4's closed hot paths, so M4's own gates must still pass.

- [ ] **Step 1: Full unit suite green**

Run: `godot --headless --path . -- --test`
Expected: `TESTS: N run, 0 failed`. Record N.

- [ ] **Step 2: M4 building smoke (≤48 bots, on game2)**

Run: `BOTS=48 MAX_WAIT=420 ci/m4_building_test.sh`
Expected: `M4 GATE: PASS` (pieces accumulate, replicate, cover blocks, winner, peak tick < 33.3 ms).

- [ ] **Step 3: M4 destruction smoke (≤48 bots, on game2)**

Run: `BOTS=48 MAX_WAIT=420 ci/m4_destruction_test.sh`
Expected: `M4-P2 GATE: PASS` (`destroyed≥1`, `nades≥1`, structures replicate to bots, winner, tick < 33.3 ms). Destruction now emits `OP_CHUNK` masks instead of buckets — the gate asserts `destroyed`, which still holds.

- [ ] **Step 4: Record evidence + update milestone**

Paste the two `GATE: PASS` summary lines + the unit count into the M11 milestone doc under a new "Phase 1 (chunked store) — gate evidence" section (mirror the M4 milestone's evidence format). Commit:

```bash
git add docs/milestones/M11-destructible-buildings.md
git commit -m "docs(m11): record Phase 1 M4 re-gate evidence"
```

> The full 128-bot fleet gate for M11 (buildings present, cascade, collapse) lands with Phase 2/3 once there are buildings to destroy; Phase 1's gate is **unit suite green + M4 smoke re-gate** (the substrate is behaviour-equivalent for player pieces, finer-grained for damage).

---

## Self-Review

**Spec coverage (Phase-1 slice of `docs/specs/destructible-buildings.md`):**
- §A chunk model (64-bit mask, born full, popcount, clear-in-radius, hole-aware march) → Tasks 1, 5, 6. ✓
- §2 unified store (chunks + building_id, health dropped) → Task 4. ✓
- Decision 4 (0.25 m / 8×8 / per-type grid) → Tasks 1–3 (`chunk_grid`, fortifications 8×8). ✓
- Decision 5 / §B (per-type bullet immunity; player pieces keep bullet) → Tasks 2, 3, 5, 9. ✓
- §D wire (`OP_CHUNK{id,mask}`, baseline/place carry mask + building_id) → Task 7; bot mirror → Task 8. ✓
- §E client cosmetic, §C cascade/collapse, §G authoring → **deferred to P2–P4** (correct; out of P1 scope). ✓
- M4 re-gate (Decision 2) → Task 11. ✓

**Placeholder scan:** No TBD/TODO; every code step has concrete code; every test step has a run command + expected result. Task 9 Step 3 asks the engineer to confirm in-scope variable names at the one site where the M4 source uses local names not fully shown here — this is a "verify the identifier" note, not a missing implementation.

**Type consistency:** `chunk_grid_of`, `is_structural`, `takes_damage`, `SRC_BULLET/EXPLOSIVE/MELEE` (PieceCatalog); `full_mask`, `popcount`, `clear_in_radius`, `is_alive_at`, `bit_at`, `chunk_center`, `count` (ChunkMask); `damage_chunks(id,source,impact,radius)→{hit,holed,destroyed,mask}`, `place(...,building_id=0)`, `_face_height` (StructureStore); `OP_CHUNK`, record `{...,chunks,building_id,...}` (Protocol); `apply_structure_delta` OP_CHUNK (bot) — names match across Tasks 1–10. `health`/`bucket_of`/`apply_damage`/`OP_DAMAGE` are fully removed and Task 10 sweeps the test suite for stragglers.
