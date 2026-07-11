# M12-P2 — Cooperative Shovel Construction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace M4's instant fortification placement with progressive, shovel-built construction — placing a piece creates a *build site* that friendly players shovel to completion (small = solo, large = ≥2 simultaneous builders), with friendly shovel-repair and enemy shovel-dismantle.

**Architecture:** Build sites live in a **parallel `BuildSiteStore`** (`shared/sim/build_site_store.gd`) — they have *no collision/cover* until complete, so the many M11 collision queries (`march`/`resolve_movement`/`floor_height_at`/…) need no `under_construction` guards. A held **`BTN_SHOVEL`** input bit (bit 9, free in the u16 buttons field) marks a builder; the server computes each tick which sites have enough eligible builders (in range + facing) and advances `build_progress`. On completion the site is handed to the existing M11 `StructureStore.place()` and replicated via the unchanged M4 `OP_PLACE` path — so collision, cover, and **all of M4 Phase-2 destruction are reused unchanged**. Repair/dismantle of finished structures reuse the chunk-mask model (`damage_chunks` for dismantle; a new inverse `repair_chunks` for repair). Pure math lives in `BuildSite` for deterministic unit tests; the milestone gate is the 128-bot bot fleet (AGENTS.md §10).

**Tech Stack:** Godot 4.6 GDScript; `class_name` sim classes in `shared/sim/`; custom binary wire in `shared/net/protocol.gd`; `TestCase` headless tests (`godot --headless --path . -- --test`); Docker bot-fleet gate.

**Spec:** [`docs/specs/squad-fob-class-refit.md`](../../specs/squad-fob-class-refit.md) §B. **ADR:** [ADR-0007](../../adr/0007-battlebit-divergences.md) §2. Supersedes M4 instant placement; reuses M4 grid/catalog/collision + M4 Phase-2 destruction. The FOB (§C) is **M12-P3**, out of scope here.

---

## Pre-flight (read before Task 1)

- Run `godot --headless --path . --import` once before the first test run (and after any new `class_name` file). Do **not** pipe `godot` through `tail`/`head` (it can hang); redirect to a file.
- Tests: `godot --headless --path . -- --test --filter=<substr>` (the harness fails any test with zero assertions).
- GDScript 4.6: annotate the type when assigning a Dictionary access to a `:=` var (Variant inference error otherwise).
- The `libvoice_opus.so not found` GDExtension error in test/server logs is **benign** (binary gitignored).
- Commit trailer on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01XfjtyogqaCby5ZBSS7cVLZ
  ```
  Use `git add -A` to include Godot `.uid` sidecars.
- **Branch:** create `m12-p2-shovel-construction` off `master` before Task 1 (`git checkout -b m12-p2-shovel-construction`).

### Reference: current subsystem (file:line)

- **Catalog** `shared/sim/piece_catalog.gd` — `from_dict` (line 98) builds `pieces[]` of `{id, half, health, material, chunk_grid, structural, damage_types, passable, surface, ramp}`; `pieces/pieces.json` is the data (type = array index: `sandbag`=0, `wall`=1, …). `health_of(type)`, `is_half(type)`, etc.
- **Structure store** `shared/sim/structure.gd` (`StructureStore`) — record `{id, type, cell, yaw, chunks, building_id, owner}`; `place(id,type,cell,yaw,owner,building_id=0)` (59), `remove(id)` (90), `damage_chunks(id,source,impact,radius)` (114) → `{hit,holed,destroyed,mask}`, `validate_place(cell,player_pos,now_tick,last_build_tick,world_half)` (168) → `{ok,reason}`, `region_of(cell)` (48), `records_in_region(region)` (52), `occupied(cell)` (30), `owner_count(owner)` (33), `get_record(id)` (36).
- **Chunk mask** `shared/sim/chunk_mask.gd` (`ChunkMask`) — `full_mask(grid)` (15), `clear_in_radius(mask,cell,yaw,grid,height,impact,radius)` (55).
- **Server placement** `server/server_main.gd` — `_handle_build_request(peer,bytes)` (1359), `_handle_build_remove` (1387), `_emit_structure_delta(op,rec,cell)` (2079), `_sync_structure_baselines(c,self_pos)` (2088); tick loop calls around line 277–297 (`_step_active_give` 278, `_emit_structure_deltas` 292, `_send_snapshots` 293). Input read: `inp["buttons"]` per pawn in `_step_movement` (336).
- **Protocol** `shared/net/protocol.gd` — `OP_PLACE=0/OP_REMOVE=1/OP_CHUNK=2` (53), `_put_record`/`_get_record` (212), `encode_structure_delta(op,rec)` / `decode_structure_delta` (234), `encode_structure_baseline(region,records)` / `decode` (504).
- **Input** `shared/net/input_command.gd` — `BTN_*` bits 0–8 used (`BTN_AIM=256` is bit 8); buttons is u16 → **bit 9 (512) free**.
- **Client mirror** `client/world_view.gd` — `apply_structure_baseline` (47), `apply_structure_delta` (52) over `_structs`; `client/client_main.gd` — `_rebuild_struct_store` (1203), `_apply_struct_delta_to_store` (1217) maintains the collision mirror `_struct_store`.
- **Bots** `bots/bot_driver.gd` — `MAX_BOT_BUILDS=0` (10, disabled), `_maybe_build(bot,me)` (351), `BuildGrid.cell_of` / `yaw_step_toward`.

---

## File Structure

- **Create** `shared/sim/build_site.gd` — `class_name BuildSite`: pure constants + progress/eligibility/decay math.
- **Create** `shared/sim/build_site_store.gd` — `class_name BuildSiteStore`: holds active under-construction sites + occupancy/region indexes.
- **Modify** `pieces/pieces.json` — add `build_cost` + `min_builders` per piece + one **large** piece (`heavy_barricade`).
- **Modify** `shared/sim/piece_catalog.gd` — parse `build_cost`/`min_builders`; add `build_cost_of(type)` / `min_builders_of(type)`.
- **Modify** `shared/sim/structure.gd` — add `repair_chunks(id,impact,radius)` (inverse of `damage_chunks`).
- **Modify** `shared/net/input_command.gd` — `BTN_SHOVEL := 512` (bit 9).
- **Modify** `shared/net/protocol.gd` — extend `_put_record`/`_get_record` with `under_construction`+`build_progress`; add `OP_PROGRESS=3` + encode/decode.
- **Modify** `server/server_main.gd` — placement → site; `_step_build_sites()`; shovel repair/dismantle; site replication + baseline; telemetry counters.
- **Modify** `bots/bot_driver.gd` — re-enable building as sites; shovel-to-complete drill (solo small + cooperative large); enemy dismantle fallback.
- **Modify** `client/world_view.gd` + `client/client_main.gd` — mirror sites (OP_PROGRESS + under_construction); keep ghosts out of the collision mirror.
- **Create** `tests/build_site_test.gd`, `tests/build_site_store_test.gd`, `tests/server_build_site_functional_test.gd`; **extend** `tests/piece_catalog_test.gd`, `tests/protocol_test.gd`, `tests/structure_test.gd`.
- **Create** `ci/m12_p2_test.sh` (≤48 smoke) + `docker/run-m12-p2-gate.sh` (128-bot gate).

---

## Task 1: Catalog gains `build_cost` + `min_builders` (+ a large piece)

**Files:**
- Modify: `pieces/pieces.json`
- Modify: `shared/sim/piece_catalog.gd:98-141` (`from_dict`), add accessors after `health_of`
- Test: `tests/piece_catalog_test.gd`

- [ ] **Step 1: Write the failing test**

Add to `tests/piece_catalog_test.gd`:

```gdscript
func test_build_cost_and_min_builders_parse() -> void:
	var data := {"pieces": [
		{"id": "small", "height": "half", "health": 150, "material": "METAL_THIN", "chunk_grid": 8,
			"build_cost": 120, "min_builders": 1, "damage": ["explosive", "melee"]},
		{"id": "big", "height": "full", "health": 600, "material": "CONCRETE", "chunk_grid": 8,
			"build_cost": 600, "min_builders": 2, "damage": ["explosive", "melee"]},
	]}
	var r := PieceCatalog.from_dict(data)
	assert_true(r["ok"], "catalog with build fields parses: %s" % r["error"])
	var c: PieceCatalog = r["catalog"]
	assert_eq(c.build_cost_of(0), 120, "small build_cost parsed")
	assert_eq(c.min_builders_of(0), 1, "small needs 1 builder")
	assert_eq(c.build_cost_of(1), 600, "large build_cost parsed")
	assert_eq(c.min_builders_of(1), 2, "large needs 2 builders")

func test_build_fields_default_when_absent() -> void:
	var data := {"pieces": [{"id": "p", "height": "half", "health": 100, "material": "WOOD",
		"chunk_grid": 1, "damage": ["melee"]}]}
	var c: PieceCatalog = PieceCatalog.from_dict(data)["catalog"]
	assert_eq(c.min_builders_of(0), 1, "min_builders defaults to 1 (solo)")
	assert_true(c.build_cost_of(0) > 0, "build_cost defaults > 0")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=piece_catalog`
Expected: FAIL — `build_cost_of` not a method / values wrong.

- [ ] **Step 3: Implement**

In `shared/sim/piece_catalog.gd` `from_dict`, inside the per-piece append (the `c.pieces.append({...})` near line 137), add two fields. Replace the append dict with:

```gdscript
		c.pieces.append({"id": id, "half": height == "half", "health": health,
			"material": _MATERIALS[mat_str], "chunk_grid": grid,
			"structural": bool(p.get("structural", false)), "damage_types": dmg,
			"passable": bool(p.get("passable", false)),
			"surface": bool(p.get("surface", false)), "ramp": bool(p.get("ramp", false)),
			"build_cost": int(p.get("build_cost", maxi(60, health / 2))),
			"min_builders": clampi(int(p.get("min_builders", 1)), 1, 4)})
```

Add accessors after `health_of` (near line 55):

```gdscript
func build_cost_of(type: int) -> int:
	return int(pieces[type]["build_cost"]) if type >= 0 and type < pieces.size() else 60

func min_builders_of(type: int) -> int:
	return int(pieces[type]["min_builders"]) if type >= 0 and type < pieces.size() else 1
```

In `pieces/pieces.json`, add `"build_cost"` + `"min_builders"` to the **player-buildable** pieces (`structural: false`) and append one large piece. Set `sandbag` → `"build_cost": 90, "min_builders": 1`; `wall` → `"build_cost": 150, "min_builders": 1`. Append a new large piece as the **last** array element (keeps existing type indices stable):

```json
    {
      "id": "heavy_barricade",
      "height": "full",
      "health": 700,
      "blocks": "both",
      "material": "METAL_THICK",
      "chunk_grid": 8,
      "structural": false,
      "build_cost": 600,
      "min_builders": 2,
      "damage": [
        "explosive",
        "melee"
      ]
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=piece_catalog`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: catalog build_cost + min_builders + heavy_barricade large piece"
```

---

## Task 2: `BuildSite` pure construction math

**Files:**
- Create: `shared/sim/build_site.gd`
- Test: `tests/build_site_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/build_site_test.gd`:

```gdscript
extends TestCase
## BuildSite (M12-P2): pure progressive-construction math — builder eligibility, progress accrual
## gated by min_builders, completion, decay. Deterministic; the server drives sites with these.

func test_solo_advances_small_site() -> void:
	# 1 builder, min_builders 1 -> progresses.
	var p := BuildSite.progress_step(0.0, 90, 1, 1, SimLoop.DT)
	assert_true(p > 0.0, "solo builder advances a min_builders=1 site")

func test_solo_blocked_on_large_site() -> void:
	# 1 builder, min_builders 2 -> no progress.
	var p := BuildSite.progress_step(100.0, 600, 1, 2, SimLoop.DT)
	assert_eq(p, 100.0, "a large (min 2) site does NOT advance with one builder")

func test_two_builders_advance_large_site() -> void:
	var p := BuildSite.progress_step(100.0, 600, 2, 2, SimLoop.DT)
	assert_true(p > 100.0, "two builders advance a min 2 site")

func test_progress_clamps_at_build_cost() -> void:
	var p := BuildSite.progress_step(599.0, 600, 4, 2, 1.0)
	assert_eq(p, 600.0, "progress never exceeds build_cost")

func test_more_builders_build_faster_up_to_cap() -> void:
	var two := BuildSite.progress_step(0.0, 10000, 2, 1, SimLoop.DT)
	var four := BuildSite.progress_step(0.0, 10000, 4, 1, SimLoop.DT)
	var eight := BuildSite.progress_step(0.0, 10000, 8, 1, SimLoop.DT)
	assert_true(four > two, "4 builders faster than 2")
	assert_almost_eq(eight, four, 0.001, "builders past MAX_BUILDERS_PER_SITE add nothing")

func test_is_complete() -> void:
	assert_true(BuildSite.is_complete(600.0, 600), "progress >= cost is complete")
	assert_false(BuildSite.is_complete(599.9, 600), "just under is not complete")

func test_eligibility_range_and_facing() -> void:
	var site := Vector3(0, 0, 5)
	assert_true(BuildSite.eligible(Vector3(0, 0, 2), Vector3(0, 0, 1), site), "in range + facing -> eligible")
	assert_false(BuildSite.eligible(Vector3(0, 0, 2), Vector3(0, 0, -1), site), "facing away -> not eligible")
	assert_false(BuildSite.eligible(Vector3(0, 0, -50), Vector3(0, 0, 1), site), "out of range -> not eligible")

func test_decay() -> void:
	assert_false(BuildSite.decayed(100, 100), "fresh work -> not decayed")
	assert_true(BuildSite.decayed(100 + BuildSite.BUILD_SITE_DECAY_TICKS, 100), "no work for the window -> decayed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=build_site_test`
Expected: FAIL — `BuildSite` not found.

- [ ] **Step 3: Implement**

Create `shared/sim/build_site.gd`:

```gdscript
class_name BuildSite
extends Object
## Pure progressive-construction math for M12-P2 cooperative shovel building. A placed fortification
## starts as a *build site* at progress 0 and accrues `build_progress` while enough eligible builders
## (in range + facing + holding the shovel) work it; small pieces need 1 builder, large pieces need
## ≥2. On completion the server hands the site to StructureStore.place (a normal M4 structure). All
## rules live here so server authority and any future client prediction can't diverge (AGENTS.md §5).

const SHOVEL_RANGE := 4.0                 # m: a builder must be within this of the site centre
const SHOVEL_FACING_DOT := 0.35           # must be roughly facing the site (cos of the half-angle)
const SHOVEL_RATE_PER_BUILDER := 70.0     # build_cost units per second per builder
const MAX_BUILDERS_PER_SITE := 4          # builders past this add nothing (anti-zerg)
const BUILD_SITE_DECAY_TICKS := 450       # 15 s @ 30 Hz of no work -> an unfinished site is freed
const SHOVEL_DISMANTLE_RATE := 28.0       # progress/sec/builder removed when digging an enemy site

## New progress after one tick. No advance unless `builders >= min_builders` (the cooperation gate);
## scales with builders up to MAX_BUILDERS_PER_SITE; clamps at build_cost.
static func progress_step(progress: float, build_cost: int, builders: int, min_builders: int, dt: float) -> float:
	if builders < min_builders or builders <= 0:
		return progress
	var n := mini(builders, MAX_BUILDERS_PER_SITE)
	return minf(progress + SHOVEL_RATE_PER_BUILDER * float(n) * dt, float(build_cost))

## New (reduced) progress when enemies dig down an under-construction site; floors at 0.
static func dismantle_step(progress: float, builders: int, dt: float) -> float:
	if builders <= 0:
		return progress
	var n := mini(builders, MAX_BUILDERS_PER_SITE)
	return maxf(progress - SHOVEL_DISMANTLE_RATE * float(n) * dt, 0.0)

static func is_complete(progress: float, build_cost: int) -> bool:
	return progress >= float(build_cost)

## A builder counts toward a site iff within SHOVEL_RANGE and roughly facing it.
static func eligible(builder_pos: Vector3, builder_fwd: Vector3, site_center: Vector3) -> bool:
	var to := site_center - builder_pos
	var d := to.length()
	if d > SHOVEL_RANGE:
		return false
	if d < 0.01:
		return true   # standing on it
	return builder_fwd.normalized().dot(to / d) >= SHOVEL_FACING_DOT

static func decayed(now_tick: int, last_work_tick: int) -> bool:
	return (now_tick - last_work_tick) >= BUILD_SITE_DECAY_TICKS
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=build_site_test`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: BuildSite pure construction math (progress/eligibility/decay)"
```

---

## Task 3: `BuildSiteStore` — active under-construction sites

**Files:**
- Create: `shared/sim/build_site_store.gd`
- Test: `tests/build_site_store_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/build_site_store_test.gd`:

```gdscript
extends TestCase
## BuildSiteStore (M12-P2): holds active build sites (no collision until complete). Mirrors the
## StructureStore region/occupancy indexing so the server can validate placement against both stores
## and stream sites by interest region.

func _site(id: int, cell: Vector3i, owner: int = 1) -> Dictionary:
	return {"id": id, "owner": owner, "team": 0, "type": 0, "cell": cell, "yaw": 0,
		"build_progress": 0.0, "build_cost": 90, "min_builders": 1, "last_work_tick": 0}

func test_add_get_remove() -> void:
	var s := BuildSiteStore.new()
	s.add(_site(5, Vector3i(1, 0, 1)))
	assert_eq(s.count(), 1)
	assert_eq(int(s.get_site(5)["id"]), 5, "get_site returns the record")
	assert_true(s.occupied(Vector3i(1, 0, 1)), "site occupies its cell")
	s.remove(5)
	assert_eq(s.count(), 0)
	assert_false(s.occupied(Vector3i(1, 0, 1)), "cell freed on remove")

func test_owner_count_and_cap_recycle() -> void:
	var s := BuildSiteStore.new()
	s.add(_site(1, Vector3i(0, 0, 0)))
	s.add(_site(2, Vector3i(2, 0, 0)))
	assert_eq(s.owner_count(1), 2)
	assert_eq(s.oldest_id(1), 1, "FIFO: oldest is the first placed")

func test_records_in_region() -> void:
	var s := BuildSiteStore.new()
	s.add(_site(7, Vector3i(0, 0, 0)))
	var region := s.region_of(Vector3i(0, 0, 0))
	var recs := s.records_in_region(region)
	assert_eq(recs.size(), 1, "site streamed in its region")
	assert_eq(int(recs[0]["id"]), 7)

func test_get_missing_returns_empty() -> void:
	assert_eq(BuildSiteStore.new().get_site(999).size(), 0, "missing id -> empty dict")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=build_site_store`
Expected: FAIL — `BuildSiteStore` not found.

- [ ] **Step 3: Implement**

Create `shared/sim/build_site_store.gd`:

```gdscript
class_name BuildSiteStore
extends Object
## Holds active build sites (M12-P2). Sites are under-construction fortifications with NO collision
## or cover — keeping them out of StructureStore means none of the M11 collision queries
## (march/resolve_movement/floor_height_at/…) accidentally treat a ghost site as solid. On completion
## the server removes the site here and calls StructureStore.place to create the real piece.
## Indexing mirrors StructureStore (occupancy by cell + region buckets) so placement can validate
## against both stores and sites stream by interest region.

const REGION_CELL := 64.0   # must match StructureStore.REGION_CELL / InterestGrid

var _by_id: Dictionary = {}        # id -> site record
var _occupancy: Dictionary = {}    # Vector3i cell -> id
var _by_owner: Dictionary = {}     # owner -> Array[int] ids (FIFO)
var _by_region: Dictionary = {}    # Vector2i region -> {id: true}

func count() -> int:
	return _by_id.size()

func get_site(id: int) -> Dictionary:
	return _by_id.get(id, {})

func occupied(cell: Vector3i) -> bool:
	return _occupancy.has(cell)

func owner_count(owner: int) -> int:
	return (_by_owner.get(owner, []) as Array).size()

func region_of(cell: Vector3i) -> Vector2i:
	return Vector2i(int(floor(float(cell.x) * BuildGrid.CELL_SIZE / REGION_CELL)),
		int(floor(float(cell.z) * BuildGrid.CELL_SIZE / REGION_CELL)))

func ids() -> Array:
	return _by_id.keys()

func add(rec: Dictionary) -> void:
	var id := int(rec["id"])
	_by_id[id] = rec
	_occupancy[rec["cell"]] = id
	var owner := int(rec["owner"])
	if not _by_owner.has(owner):
		_by_owner[owner] = []
	(_by_owner[owner] as Array).append(id)
	var region := region_of(rec["cell"])
	if not _by_region.has(region):
		_by_region[region] = {}
	_by_region[region][id] = true

func remove(id: int) -> void:
	if not _by_id.has(id):
		return
	var rec: Dictionary = _by_id[id]
	_occupancy.erase(rec["cell"])
	var owner := int(rec["owner"])
	if _by_owner.has(owner):
		(_by_owner[owner] as Array).erase(id)
	var region := region_of(rec["cell"])
	if _by_region.has(region):
		(_by_region[region] as Dictionary).erase(id)
		if (_by_region[region] as Dictionary).is_empty():
			_by_region.erase(region)
	_by_id.erase(id)

func oldest_id(owner: int) -> int:
	var arr: Array = _by_owner.get(owner, [])
	return int(arr[0]) if not arr.is_empty() else 0

func records_in_region(region: Vector2i) -> Array:
	var out: Array = []
	for id in _by_region.get(region, {}):
		out.append(_by_id[id])
	return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=build_site_store`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: BuildSiteStore (active sites, occupancy + region indexing)"
```

---

## Task 4: `BTN_SHOVEL` input bit

**Files:**
- Modify: `shared/net/input_command.gd` (button-bit block near line 12-20; the u16 encode at line 48 already carries bit 9)
- Test: `tests/protocol_test.gd` (or `tests/input_command_test.gd` if present — grep first)

- [ ] **Step 1: Write the failing test**

Grep `tests/` for an existing input-command round-trip test (`grep -l "BTN_AIM\|encode_input" tests/*.gd`). Add to that file (or `tests/protocol_test.gd`):

```gdscript
func test_btn_shovel_round_trips() -> void:
	var btns := InputCommand.BTN_SHOVEL | InputCommand.BTN_FIRE
	var bytes := Protocol.encode_input({"seq": 1, "yaw": 0.0, "pitch": 0.0, "move_x": 0, "move_y": 0,
		"buttons": btns, "view_server_tick": 0})
	var d := Protocol.decode_input(bytes)
	assert_true((int(d["buttons"]) & InputCommand.BTN_SHOVEL) != 0, "shovel bit survives the wire")
	assert_eq(InputCommand.BTN_SHOVEL, 512, "shovel is bit 9 (free above BTN_AIM)")
```

> If `Protocol.encode_input`'s dict keys differ in this codebase, mirror the existing input round-trip test's call exactly — only the `buttons` value matters here.

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=shovel`
Expected: FAIL — `BTN_SHOVEL` not defined.

- [ ] **Step 3: Implement**

In `shared/net/input_command.gd`, after `BTN_AIM := 256` (bit 8):

```gdscript
const BTN_SHOVEL := 512    # bit 9: held shovel-use (M12-P2 build/repair/dismantle); server-computed
```

No encode/decode change — buttons is already a u16 and bit 9 fits.

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=shovel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: BTN_SHOVEL held-input bit (bit 9)"
```

---

## Task 5: Protocol — `under_construction` + `build_progress` on records; `OP_PROGRESS`

**Files:**
- Modify: `shared/net/protocol.gd` — `OP_*` consts (line 53-55), `_put_record`/`_get_record` (212-231), `encode_structure_delta`/`decode_structure_delta` (234-256)
- Test: `tests/protocol_test.gd`

- [ ] **Step 1: Write the failing test**

Add to `tests/protocol_test.gd`:

```gdscript
func test_record_carries_under_construction_and_progress() -> void:
	var rec := {"id": 7, "type": 1, "cell": Vector3i(2, 0, 3), "yaw": 1, "chunks": -1,
		"building_id": 0, "owner": 5, "under_construction": 1, "build_progress": 250}
	var bytes := Protocol.encode_structure_delta(Protocol.OP_PLACE, rec)
	var d := Protocol.decode_structure_delta(bytes)
	assert_eq(d["op"], Protocol.OP_PLACE)
	assert_eq(int(d["rec"]["under_construction"]), 1, "ghost flag round-trips")
	assert_eq(int(d["rec"]["build_progress"]), 250, "progress round-trips")

func test_finished_record_defaults_zero() -> void:
	var rec := {"id": 8, "type": 0, "cell": Vector3i(0, 0, 0), "yaw": 0, "chunks": -1,
		"building_id": 0, "owner": 1}
	var d := Protocol.decode_structure_delta(Protocol.encode_structure_delta(Protocol.OP_PLACE, rec))
	assert_eq(int(d["rec"]["under_construction"]), 0, "missing flag encodes as finished")
	assert_eq(int(d["rec"]["build_progress"]), 0)

func test_op_progress_round_trip() -> void:
	var bytes := Protocol.encode_structure_progress(7, 412)
	var d := Protocol.decode_structure_delta(bytes)
	assert_eq(d["op"], Protocol.OP_PROGRESS)
	assert_eq(int(d["id"]), 7)
	assert_eq(int(d["progress"]), 412)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=protocol`
Expected: FAIL — fields missing / `encode_structure_progress` undefined / `OP_PROGRESS` undefined.

- [ ] **Step 3: Implement**

In `shared/net/protocol.gd` add the op (after `OP_CHUNK`, line 54):

```gdscript
const OP_PROGRESS := 3   ## STRUCTURE_DELTA payload {id u16, progress u16} — build-site progress tick (M12-P2)
```

Extend `_put_record` (append two fields at the end so existing readers that stop early still work — but `_get_record` reads them, so keep order consistent). Replace `_put_record`/`_get_record`:

```gdscript
static func _put_record(buf: StreamPeerBuffer, rec: Dictionary) -> void:
	buf.put_u8(int(rec["type"]))
	buf.put_u16(int(rec["id"]))
	buf.put_16(int(rec["cell"].x)); buf.put_16(int(rec["cell"].y)); buf.put_16(int(rec["cell"].z))
	buf.put_u8(int(rec["yaw"]))
	buf.put_u64(int(rec.get("chunks", -1)))
	buf.put_u16(int(rec.get("building_id", 0)))
	buf.put_u16(int(rec.get("owner", 0)))
	buf.put_u8(int(rec.get("under_construction", 0)))                       # M12-P2
	buf.put_u16(clampi(int(rec.get("build_progress", 0)), 0, 65535))        # M12-P2

static func _get_record(r: StreamPeerBuffer) -> Dictionary:
	var type := r.get_u8()
	var id := r.get_u16()
	var cell := Vector3i(r.get_16(), r.get_16(), r.get_16())
	var yaw := r.get_u8()
	var chunks := r.get_u64()
	var building_id := r.get_u16()
	var owner := r.get_u16()
	var uc := r.get_u8() if r.get_available_bytes() > 0 else 0              # trailing, back-compatible
	var prog := r.get_u16() if r.get_available_bytes() > 0 else 0
	return {"id": id, "type": type, "cell": cell, "yaw": yaw, "chunks": chunks,
		"building_id": building_id, "owner": owner, "under_construction": uc, "build_progress": prog}
```

> Verify the real `_put_record`/`_get_record` field order/types against the file before editing (the map above lists them); preserve any field not shown. Only the two trailing fields are added.

Add the progress encode + extend the decode `match`. After `encode_structure_delta` add:

```gdscript
static func encode_structure_progress(id: int, progress: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.STRUCTURE_DELTA)
	buf.put_u8(OP_PROGRESS)
	buf.put_u16(id)
	buf.put_u16(clampi(progress, 0, 65535))
	return buf.data_array
```

In `decode_structure_delta`, add an `OP_PROGRESS` branch alongside `OP_CHUNK` (it reads `id` + `progress`):

```gdscript
	elif op == OP_PROGRESS:
		return {"op": op, "id": r.get_u16(), "progress": r.get_u16()}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=protocol`
Expected: PASS. Also run the full suite to catch baseline/record callers: `godot --headless --path . -- --test --filter=structure` (the extra trailing bytes are backward-compatible).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: protocol record under_construction+build_progress + OP_PROGRESS"
```

---

## Task 6: `StructureStore.repair_chunks` (inverse of damage_chunks)

**Files:**
- Modify: `shared/sim/structure.gd` (add after `damage_chunks`, ~line 131)
- Test: `tests/structure_test.gd`

- [ ] **Step 1: Write the failing test**

Add to `tests/structure_test.gd`:

```gdscript
func test_repair_chunks_refills_a_holed_piece() -> void:
	var cat := PieceCatalog.from_dict({"pieces": [{"id": "wall", "height": "full", "health": 350,
		"material": "CONCRETE", "chunk_grid": 8, "damage": ["explosive", "melee"]}]})["catalog"]
	var s := StructureStore.new(cat)
	var rec := s.place(1, 0, Vector3i(0, 0, 0), 0, 9)
	var center := BuildGrid.cell_min(Vector3i(0, 0, 0)) + Vector3(0.5, 0.5, 0.5)
	var dmg := s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 0.6)
	assert_true(dmg["hit"], "explosive holes the wall")
	var holed_mask := int(s.get_record(1)["chunks"])
	var rep := s.repair_chunks(1, center, 0.6)
	assert_true(rep["changed"], "repair re-sets cleared chunks")
	assert_true(int(s.get_record(1)["chunks"]) != holed_mask, "mask grew back toward full")

func test_repair_noop_on_full_piece() -> void:
	var cat := PieceCatalog.from_dict({"pieces": [{"id": "wall", "height": "full", "health": 350,
		"material": "CONCRETE", "chunk_grid": 8, "damage": ["explosive"]}]})["catalog"]
	var s := StructureStore.new(cat)
	s.place(1, 0, Vector3i(0, 0, 0), 0, 9)
	var rep := s.repair_chunks(1, Vector3(0, 0, 0), 0.6)
	assert_false(rep["changed"], "repairing an intact piece does nothing")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: FAIL — `repair_chunks` not a method.

- [ ] **Step 3: Implement**

In `shared/sim/structure.gd`, after `damage_chunks` (study it first — it calls `ChunkMask.clear_in_radius(mask, cell, yaw, grid, height, impact, radius)` and writes the new mask back to the record). Add the inverse — OR the cleared region's bits back toward `full_mask`:

```gdscript
## Inverse of damage_chunks: re-sets (heals) chunk bits within `radius` of `impact`, toward the full
## mask. Used by M12-P2 friendly shovel-repair. Returns {changed:bool, mask:int}. No-op if already full.
func repair_chunks(id: int, impact: Vector3, radius: float) -> Dictionary:
	if not _by_id.has(id):
		return {"changed": false, "mask": 0}
	var rec: Dictionary = _by_id[id]
	var grid := _catalog.chunk_grid_of(int(rec["type"]))
	var full := ChunkMask.full_mask(grid)
	var cur := int(rec["chunks"])
	if cur == full:
		return {"changed": false, "mask": cur}
	var height := 0.5 if _catalog.is_half(int(rec["type"])) else 1.0
	# Which chunks fall in the repair radius? clear_in_radius on a FULL mask yields a mask whose
	# CLEARED bits are exactly the in-radius chunks; the bits it left set are out-of-radius. So the
	# in-radius set = full XOR that. Re-set those bits in the current mask.
	var in_radius := full ^ ChunkMask.clear_in_radius(full, rec["cell"], int(rec["yaw"]), grid, height, impact, radius)
	var healed := cur | in_radius
	if healed == cur:
		return {"changed": false, "mask": cur}
	rec["chunks"] = healed
	return {"changed": true, "mask": healed}
```

> If `damage_chunks`/`ChunkMask.clear_in_radius` signatures differ from the map, match them exactly (read both before writing). The XOR trick assumes `clear_in_radius` only clears in-radius bits — verify from `chunk_mask.gd:55`.

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: StructureStore.repair_chunks (shovel-repair inverse of damage)"
```

---

## Task 7: Server — placement creates a build site (not a finished piece)

**Files:**
- Modify: `server/server_main.gd` — add `_sites` member; rewrite `_handle_build_request` (1359-1385); add `_next_struct_id` helper if needed
- Test: `tests/server_build_site_functional_test.gd` (new; uses the headless server harness pattern from `server_buildings_functional_test.gd`)

- [ ] **Step 1: Write the failing test**

Read `tests/server_buildings_functional_test.gd` for the server-harness construction pattern (how it builds a `ServerMain` / store + injects a build request). Create `tests/server_build_site_functional_test.gd` mirroring it:

```gdscript
extends TestCase
## M12-P2 server: a BUILD_REQUEST creates an under-construction site (no collision), not a finished
## piece; shovelling it to completion promotes it into the StructureStore.

# Follow the harness style of server_buildings_functional_test.gd. Pseudocode of intent:
func test_build_request_makes_a_site_then_completes() -> void:
	var srv := _make_server_with_one_player(_class_assault)   # helper per existing functional test
	srv._handle_build_request_cell(_player_id, _build_type_small, Vector3i(3, 0, 0), 0)  # test seam
	assert_eq(srv._store.count(), 0, "no finished piece yet")
	assert_eq(srv._sites.count(), 1, "a build site exists")
	# Simulate the player standing on the site holding the shovel for enough ticks.
	for _i in range(120):
		srv._set_player_shovelling(_player_id, true, Vector3i(3, 0, 0))   # test seam
		srv._step_build_sites()
	assert_eq(srv._sites.count(), 0, "site completed and removed")
	assert_eq(srv._store.count(), 1, "promoted to a real structure")
```

> The exact harness seams (`_make_server_with_one_player`, `_set_player_shovelling`, a cell-level `_handle_build_request` entry) depend on what the existing functional test exposes. If the existing test drives the full `ServerMain` Node, add minimal **test-only** helper methods on `server_main.gd` (clearly commented `# test seam`) rather than duplicating tick plumbing. Keep assertions concrete (counts, ids).

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=server_build_site`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `server/server_main.gd`:

Add the member near `_store`:

```gdscript
var _sites := BuildSiteStore.new()   # M12-P2: active under-construction build sites
const MAX_SITES_PER_PLAYER := 4
```

Rewrite `_handle_build_request` so a valid request creates a **site** (progress 0) instead of calling `_store.place`. Keep all M4 validation (`validate_place` against the **structure** store) and add an occupancy check against `_sites`:

```gdscript
func _handle_build_request(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var cid := _peer_to_id.get(peer, 0)
	if cid == 0: return
	var d := Protocol.decode_build_request(bytes)
	var type := int(d["type"]); var cell: Vector3i = d["cell"]; var yaw := int(d["yaw"])
	if type < 0 or type >= _catalog.size(): return
	if yaw < 0 or yaw >= BuildGrid.YAW_STEPS: return
	if _catalog.is_structural(type): return   # players build only fortifications, not building pieces
	var pawn: Pawn = _sim.world.get_pawn(cid)
	if pawn == null or not pawn.alive or pawn.is_downed: return
	# M4 placement validation (bounds/range/cooldown/occupancy) against finished structures…
	var last := int(_clients[cid].get("last_build_tick", -100000))
	var v := _store.validate_place(cell, pawn.pos, _sim.tick, last, _world_half())
	if not v["ok"]: return
	# …plus: not already an active site there.
	if _sites.occupied(cell): return
	# Per-player site cap: recycle the oldest unfinished site.
	if _sites.owner_count(cid) >= MAX_SITES_PER_PLAYER:
		var old := _sites.oldest_id(cid)
		if old != 0:
			_sites.remove(old); _emit_structure_delta(Protocol.OP_REMOVE, {"id": old}, _site_cell(old))
	_clients[cid]["last_build_tick"] = _sim.tick
	var sid := _alloc_struct_id()
	var rec := {"id": sid, "owner": cid, "team": pawn.team, "type": type, "cell": cell, "yaw": yaw,
		"build_progress": 0.0, "build_cost": _catalog.build_cost_of(type),
		"min_builders": _catalog.min_builders_of(type), "last_work_tick": _sim.tick}
	_sites.add(rec)
	_emit_structure_delta(Protocol.OP_PLACE, _site_wire_record(rec), cell)
```

Add helpers (id allocation must be shared with `_store` placement so site/structure ids never collide — reuse the existing id allocator the old `_handle_build_request` used; if it was a counter like `_next_sid`, route both through `_alloc_struct_id`):

```gdscript
func _alloc_struct_id() -> int:
	_next_sid += 1
	return _next_sid

func _site_cell(id: int) -> Vector3i:
	var r := _sites.get_site(id)
	return r["cell"] if not r.is_empty() else Vector3i.ZERO

## Wire record for a site: the StructureStore record shape + under_construction/build_progress.
func _site_wire_record(rec: Dictionary) -> Dictionary:
	return {"id": rec["id"], "type": rec["type"], "cell": rec["cell"], "yaw": rec["yaw"],
		"chunks": ChunkMask.full_mask(_catalog.chunk_grid_of(int(rec["type"]))),
		"building_id": 0, "owner": rec["owner"],
		"under_construction": 1, "build_progress": int(rec["build_progress"])}
```

> Find the existing structure-id allocator in `_handle_build_request` (it passed an id to `_store.place`). Reuse it for `_alloc_struct_id` so promoted sites keep the same id space as direct placements. Add the `# test seam` helpers the Task-7 test needs (`_set_player_shovelling`, a cell-level request entry).

- [ ] **Step 4: Run test to verify it passes** (after Task 8 wires `_step_build_sites`, this test fully passes; here, assert the *site is created*). Run: `godot --headless --path . -- --test --filter=server_build_site`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: server BUILD_REQUEST creates a build site (no instant placement)"
```

---

## Task 8: Server — `_step_build_sites` (progress, completion, decay) + shovelling set

**Files:**
- Modify: `server/server_main.gd` — add `_step_build_sites()`, call it in the tick loop (after `_step_active_give`, ~line 278); build the per-tick shovelling set in `_step_movement` (336) or a small pre-step
- Test: `tests/server_build_site_functional_test.gd` (the completion + solo-block cases)

- [ ] **Step 1: Write the failing tests** — extend the Task-7 test file:

```gdscript
func test_large_site_blocked_solo_then_built_by_two() -> void:
	var srv := _make_server_with_two_teammates()
	srv._handle_build_request_cell(_p1, _build_type_large, Vector3i(4, 0, 0), 0)
	for _i in range(120):
		srv._set_player_shovelling(_p1, true, Vector3i(4, 0, 0))   # only one builder
		srv._step_build_sites()
	assert_eq(srv._sites.count(), 1, "large site does NOT complete with one builder")
	assert_true(srv._build_blocked_solo >= 1, "blocked-solo telemetry incremented")
	for _i in range(200):
		srv._set_player_shovelling(_p1, true, Vector3i(4, 0, 0))
		srv._set_player_shovelling(_p2, true, Vector3i(4, 0, 0))
		srv._step_build_sites()
	assert_eq(srv._store.count(), 1, "two builders complete the large site")
	assert_true(srv._built_large >= 1, "built_large telemetry incremented")

func test_abandoned_site_decays() -> void:
	var srv := _make_server_with_one_player(_class_assault)
	srv._handle_build_request_cell(_p1, _build_type_small, Vector3i(6, 0, 0), 0)
	for _i in range(BuildSite.BUILD_SITE_DECAY_TICKS + 2):
		srv._step_build_sites()   # nobody shovels
	assert_eq(srv._sites.count(), 0, "an abandoned site decays away")
```

- [ ] **Step 2: Run to verify fail** — `godot --headless --path . -- --test --filter=server_build_site` → FAIL.

- [ ] **Step 3: Implement**

Add telemetry counters near the other counters (`_built_small`, `_built_large`, `_build_blocked_solo`, `_dismantled`, `_repaired` — all `int = 0`).

Build the per-tick shovelling set. In the tick loop, just before `_step_build_sites()`, populate from each pawn's current input:

```gdscript
func _collect_shovellers() -> Dictionary:
	# pawn_id -> {pos, fwd, team} for pawns holding BTN_SHOVEL this tick (alive, not downed).
	var out := {}
	for cid in _clients:
		var inp = _clients[cid].get("last_input", null)
		if inp == null or (int(inp["buttons"]) & InputCommand.BTN_SHOVEL) == 0:
			continue
		var p: Pawn = _sim.world.get_pawn(cid)
		if p == null or not p.alive or p.is_downed:
			continue
		out[cid] = {"pos": p.pos, "fwd": Combat._forward(p.yaw, p.pitch), "team": p.team}
	return out
```

> Use whatever field already stores the latest input per client (the fire/aim reads at lines 421/469/537 use `inp["buttons"]` — find that source and reuse it). If a `_set_player_shovelling` test seam is used, have it write into the same structure `_collect_shovellers` reads.

Add `_step_build_sites`:

```gdscript
func _step_build_sites() -> void:
	if _sites.count() == 0:
		return
	var shov := _collect_shovellers()
	var to_complete: Array = []
	var to_decay: Array = []
	for id in _sites.ids():
		var s: Dictionary = _sites.get_site(id)
		var center := BuildGrid.cell_min(s["cell"]) + Vector3(0.5, 0.5, 0.5)
		# Count eligible FRIENDLY builders (same team as the site owner).
		var builders := 0
		for bid in shov:
			var b: Dictionary = shov[bid]
			if int(b["team"]) != int(s["team"]):
				continue
			if BuildSite.eligible(b["pos"], b["fwd"], center):
				builders += 1
		if builders <= 0:
			if BuildSite.decayed(_sim.tick, int(s["last_work_tick"])):
				to_decay.append(id)
			continue
		if builders < int(s["min_builders"]):
			_build_blocked_solo += 1   # someone is shovelling but not enough hands for this size
			continue
		var before := float(s["build_progress"])
		var after := BuildSite.progress_step(before, int(s["build_cost"]), builders, int(s["min_builders"]), SimLoop.DT)
		s["build_progress"] = after
		s["last_work_tick"] = _sim.tick
		# Low-cadence progress replication (every ~6 ticks of change).
		if int(after / 6.0) != int(before / 6.0):
			_emit_structure_delta_progress(int(id), int(after), s["cell"])
		if BuildSite.is_complete(after, int(s["build_cost"])):
			to_complete.append(id)
	for id in to_complete:
		_complete_site(int(id))
	for id in to_decay:
		var c := _site_cell(int(id))
		_sites.remove(int(id))
		_emit_structure_delta(Protocol.OP_REMOVE, {"id": int(id)}, c)

func _complete_site(id: int) -> void:
	var s: Dictionary = _sites.get_site(id)
	if s.is_empty(): return
	_sites.remove(id)
	# Promote into the real structure store (full collision/cover/HP, destructible via M4 Phase-2).
	var rec := _store.place(id, int(s["type"]), s["cell"], int(s["yaw"]), int(s["owner"]))
	if rec.is_empty():
		return   # cell got occupied in the same tick; drop silently
	# Tell clients it is now a finished piece (under_construction flips to 0).
	var wire := _store.get_record(id).duplicate()
	wire["under_construction"] = 0; wire["build_progress"] = int(s["build_cost"])
	_emit_structure_delta(Protocol.OP_PLACE, wire, s["cell"])
	if int(s["min_builders"]) >= 2:
		_built_large += 1
	else:
		_built_small += 1
```

Add a thin progress-delta emitter that mirrors `_emit_structure_delta`'s region routing but sends `encode_structure_progress`:

```gdscript
func _emit_structure_delta_progress(id: int, progress: int, cell: Vector3i) -> void:
	var region := _store.region_of(cell)
	var pkt := Protocol.encode_structure_progress(id, progress)
	_send_struct_pkt_to_region(region, pkt)   # extract the region-routing loop from _emit_structure_delta
```

> Refactor the per-client region-routing loop out of `_emit_structure_delta` into `_send_struct_pkt_to_region(region, pkt)` and call it from both. Wire `_step_build_sites()` into the tick loop right after `_step_active_give()` (line 278).

- [ ] **Step 4: Run to verify pass** — `godot --headless --path . -- --test --filter=server_build_site` (Task-7 + Task-8 cases all green).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: server _step_build_sites — progress/completion/decay + shovelling set"
```

---

## Task 9: Server — shovel-repair (friendly) + shovel-dismantle (enemy) of finished structures

**Files:**
- Modify: `server/server_main.gd` — extend the shovel step to act on finished structures a shoveller is aiming at
- Test: `tests/server_build_site_functional_test.gd`

- [ ] **Step 1: Write the failing tests:**

```gdscript
func test_enemy_shovel_dismantles_a_finished_structure() -> void:
	var srv := _make_server_with_two_enemies()   # p1 team0, p2 team1
	# p1 builds + completes a small piece (helper that fast-forwards a solo build).
	var sid := srv._test_build_and_complete(_p1, _build_type_small, Vector3i(8, 0, 0))
	assert_true(srv._store.count() == 1)
	# enemy p2 shovels it down.
	for _i in range(400):
		srv._set_player_shovelling(_p2, true, Vector3i(8, 0, 0))
		srv._step_build_sites()
	assert_eq(srv._store.count(), 0, "enemy shovel-dismantle removes the structure")
	assert_true(srv._dismantled >= 1, "dismantled telemetry incremented")

func test_friendly_shovel_repairs_a_holed_structure() -> void:
	var srv := _make_server_with_one_player(_class_assault)
	var sid := srv._test_build_and_complete(_p1, _build_type_small, Vector3i(9, 0, 0))
	srv._test_hole_structure(sid)   # apply explosive damage so chunks < full
	var holed := int(srv._store.get_record(sid)["chunks"])
	for _i in range(120):
		srv._set_player_shovelling(_p1, true, Vector3i(9, 0, 0))
		srv._step_build_sites()
	assert_true(int(srv._store.get_record(sid)["chunks"]) != holed, "repair refilled chunks")
	assert_true(srv._repaired >= 1, "repaired telemetry incremented")
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement** — in `_step_build_sites` (or a sibling `_step_shovel_structures` called right after it), for each shoveller **not** counted toward a site this tick, raycast/aim at the nearest finished structure within `BuildSite.SHOVEL_RANGE`:

```gdscript
func _step_shovel_structures(shov: Dictionary) -> void:
	for bid in shov:
		var b: Dictionary = shov[bid]
		var hit := _store.march(b["pos"], b["fwd"], BuildSite.SHOVEL_RANGE)
		if not hit["hit"]:
			continue
		var sid := int(hit["id"])
		var rec := _store.get_record(sid)
		if rec.is_empty():
			continue
		var impact: Vector3 = b["pos"] + (b["fwd"] as Vector3).normalized() * float(hit["dist"])
		var owner_pawn: Pawn = _sim.world.get_pawn(int(rec["owner"]))
		var struct_team := owner_pawn.team if owner_pawn != null else int(b["team"])
		if int(b["team"]) == struct_team:
			# Friendly: repair toward full.
			var rep := _store.repair_chunks(sid, impact, BuildSite.SHOVEL_DISMANTLE_RADIUS)
			if rep["changed"]:
				_repaired += 1
				_emit_structure_delta(Protocol.OP_CHUNK, {"id": sid, "mask": int(rep["mask"])}, rec["cell"])
		else:
			# Enemy: dig it down via the melee damage path (slow; the no-explosives demolition route).
			if not _catalog.takes_damage(int(rec["type"]), PieceCatalog.SRC_MELEE):
				continue
			var dmg := _store.damage_chunks(sid, PieceCatalog.SRC_MELEE, impact, BuildSite.SHOVEL_DISMANTLE_RADIUS)
			if dmg["destroyed"]:
				_dismantled += 1
				_pending_removes.append(sid)   # reuse the M4 removal path (cascade/C4-cleanup)
			elif dmg["holed"]:
				_dmg_touched[sid] = true        # reuse the M4 bucket-delta emit
```

Call `_step_shovel_structures(shov)` from `_step_build_sites` using the same `shov` dict (compute it once and pass it). A shoveller already counted toward a *site* should be skipped for structure-shovel (track the ids that contributed to a site, or simply allow both — a builder rarely overlaps a finished piece and a site in the same cell). Prefer: collect site-contributors into a set and skip them here.

> `damage_chunks`/`_pending_removes`/`_dmg_touched` are the existing M4 Phase-2 mechanisms (see `_damage_structure`/`_emit_structure_deltas`). Reusing them means destruction replication, cascade, and attached-C4 cleanup all work unchanged. `enemy dismantle` is deliberately slow (small radius + per-tick), so it takes seconds.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: shovel-repair (friendly) + shovel-dismantle (enemy) of finished structures"
```

---

## Task 10: Server — stream sites in structure baselines

**Files:**
- Modify: `server/server_main.gd` — `_sync_structure_baselines` (2088): include active sites for the region
- Test: covered by the Task-13 integration smoke (a late-joining client gets in-progress sites) — add a focused functional assertion if the harness allows.

- [ ] **Step 1: Write the failing test** (functional, if the harness exposes baseline building):

```gdscript
func test_baseline_includes_active_sites() -> void:
	var srv := _make_server_with_one_player(_class_assault)
	srv._handle_build_request_cell(_p1, _build_type_small, Vector3i(2, 0, 0), 0)
	var region := srv._store.region_of(Vector3i(2, 0, 0))
	var recs := srv._baseline_records_for_region(region)   # test seam wrapping the baseline build
	var found := recs.any(func(r): return int(r.get("under_construction", 0)) == 1)
	assert_true(found, "a joining client's baseline includes the under-construction site")
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement** — in `_sync_structure_baselines`, after gathering `_store.records_in_region(region)`, append site wire records:

```gdscript
		var records := _store.records_in_region(region)
		for s in _sites.records_in_region(region):
			records.append(_site_wire_record(s))
		# …existing encode_structure_baseline(region, records) + send…
```

Add the `_baseline_records_for_region(region)` test seam returning that merged array.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: include active build sites in structure baselines (late-join sync)"
```

---

## Task 11: Client — mirror sites; keep ghosts out of the collision store

**Files:**
- Modify: `client/world_view.gd` — `apply_structure_delta` (52): handle `OP_PROGRESS`; carry `under_construction`/`build_progress` on records
- Modify: `client/client_main.gd` — `_apply_struct_delta_to_store` (1217) + `_rebuild_struct_store` (1203): only insert into the **collision** mirror when `under_construction == 0`
- Test: `tests/world_view.gd`-style test if one exists (grep `tests/world_view*`); else assert via a small new `tests/client_struct_site_test.gd`

- [ ] **Step 1: Write the failing test** — create `tests/client_struct_site_test.gd`:

```gdscript
extends TestCase
## M12-P2 client: a WorldView mirrors under-construction sites (so M7 can ghost them) and applies
## OP_PROGRESS updates; the collision mirror in client_main excludes ghosts (handled there).

func test_site_place_then_progress_then_complete() -> void:
	var wv := WorldView.new()
	var site := {"id": 7, "type": 0, "cell": Vector3i(1, 0, 1), "yaw": 0, "chunks": -1,
		"building_id": 0, "owner": 5, "under_construction": 1, "build_progress": 0}
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_PLACE, site))
	assert_eq(int(wv.structures()[7]["under_construction"]), 1, "ghost recorded")
	wv.apply_structure_delta(Protocol.encode_structure_progress(7, 300))
	assert_eq(int(wv.structures()[7]["build_progress"]), 300, "progress applied")
	var done := site.duplicate(); done["under_construction"] = 0
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_PLACE, done))
	assert_eq(int(wv.structures()[7]["under_construction"]), 0, "completion flips ghost to finished")
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement** — in `client/world_view.gd` `apply_structure_delta`, add the `OP_PROGRESS` branch and ensure `OP_PLACE` stores the full record (it already does):

```gdscript
		Protocol.OP_PROGRESS:
			if _structs.has(d["id"]):
				_structs[d["id"]]["build_progress"] = int(d["progress"])
				_structs_version += 1
```

In `client/client_main.gd` `_apply_struct_delta_to_store` and `_rebuild_struct_store`, guard the **collision** store insert:

```gdscript
		Protocol.OP_PLACE:
			if int(d["rec"].get("under_construction", 0)) == 0:
				_struct_store.place(...)   # finished piece -> collision
				# set chunks as today
			else:
				_struct_store.remove(int(d["rec"]["id"]))   # a ghost has no collision (and clears any prior)
```

(Mirror the same `under_construction` guard in `_rebuild_struct_store` so a baseline ghost is not inserted into collision.)

- [ ] **Step 4: Run to verify pass** — `godot --headless --path . -- --test --filter=client_struct_site`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: client mirrors sites + OP_PROGRESS; ghosts excluded from collision"
```

---

## Task 12: Bots — build as sites + shovel to completion (solo small + cooperative large) + enemy dismantle

**Files:**
- Modify: `bots/bot_driver.gd` — `MAX_BOT_BUILDS` (10), `_maybe_build` (351); add `_maybe_shovel`/build-drill state
- Test: exercised by the gate (Task 14); add a tiny pure unit test only if a bot helper is extracted.

- [ ] **Step 1:** No new unit test (bot behaviour is gate-validated, AGENTS.md §10). If a pure decision helper is extracted (e.g. `_should_cooperate_on(site)`), unit-test that.

- [ ] **Step 2:** N/A.

- [ ] **Step 3: Implement** a scripted build drill so the gate exercises every counter deterministically:

- Re-enable building: `const MAX_BOT_BUILDS := 3`.
- Give a fraction of bots a **builder** role. A builder bot, off cooldown and not in a firefight:
  1. Places a site ahead (`_maybe_build`, now creating a site). Most place a **small** piece (`type = _small_type`, `min_builders 1`); a designated **squad pair** (two bots sharing a squad id) places + co-shovels a **large** piece (`type = _large_type`) at a shared cell so `built_large` fires.
  2. After placing (or seeing a friendly site within `SHOVEL_RANGE`), the bot **holds `BTN_SHOVEL`** while standing near + facing the site until it completes (set the bit in the bot's input each tick; clear when no site in range).
- Enemy dismantle: a bot with no explosives that walks up to an **enemy** finished structure within range holds `BTN_SHOVEL` to dig it (so `dismantled` fires). Reuse the same "face + hold shovel" code; the server decides repair vs dismantle by team.

Concrete shape:

```gdscript
const MAX_BOT_BUILDS := 3
const SHOVEL_HOLD_RANGE := BuildSite.SHOVEL_RANGE

func _maybe_shovel(bot: Dictionary, me: EntityState) -> bool:
	# Returns true if the bot is holding the shovel this tick (caller OR-s BTN_SHOVEL into buttons).
	# Find the nearest site/structure the bot knows about within range and roughly ahead.
	var target := _nearest_buildable_or_enemy_struct(bot, me)   # uses the client struct mirror the bot keeps
	if target == Vector3.INF:
		return false
	# Face it (steer yaw toward target) and signal shovel.
	bot["aim_override"] = target
	return true
```

In the bot's input assembly, `if _maybe_shovel(bot, me): buttons |= InputCommand.BTN_SHOVEL`. Designate builder bots by id parity within a squad (deterministic, like `gadget_for_player`). Keep `BUILD_COOLDOWN_TICKS` so they don't spam.

> The bot already keeps a structure mirror to navigate around cover (check `bot_driver.gd` for how it reads `STRUCTURE_*`). Reuse it to locate sites (under_construction records) and enemy structures. If the bot has no structure mirror, give the drill a simpler deterministic loop: a builder bot places a site at a fixed offset, then walks onto that cell and holds shovel for N ticks regardless — enough for the gate counters.

- [ ] **Step 4: Run** the ≤48 smoke (Task 14) and confirm `built_small`/`built_large`/`dismantled`/`repaired` appear in telemetry.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: bot shovel-build drill (solo small + cooperative large) + enemy dismantle"
```

---

## Task 13: Telemetry line — expose the M12-P2 counters

**Files:**
- Modify: `server/server_main.gd` — the `[telemetry]` format string in `_log_telemetry` (grep `\[telemetry\]`); reset counters per window like the others
- Test: none (format change); verify by reading a smoke log.

- [ ] **Step 1–2:** N/A (telemetry formatting).

- [ ] **Step 3: Implement** — add `built_small=%d built_large=%d build_blocked_solo=%d dismantled=%d repaired=%d` to the telemetry line using the counters; reset them each window where the other per-window counters reset.

- [ ] **Step 4:** Run a 10-bot local smoke and confirm the fields print:
`godot --headless --path . -- --server --port=27050 --time-limit=30 &` then a bot driver `--bots --bot-count=10 --connect=127.0.0.1 --port=27050`, grep the server log for `built_`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: telemetry counters (built_small/large, blocked_solo, dismantled, repaired)"
```

---

## Task 14: CI smoke + Docker fleet gate scripts

**Files:**
- Create: `ci/m12_p2_test.sh` (≤48-bot smoke; assert build counters ≥1 + winner + tick budget)
- Create: `docker/run-m12-p2-gate.sh` (128-bot, mirrors `run-m4.5-p2-gate.sh`)
- Test: run them.

- [ ] **Step 1–2:** N/A (scripts).

- [ ] **Step 3: Implement** — copy `ci/m4.5_p2_test.sh` → `ci/m12_p2_test.sh`, change the asserted counters to the M12-P2 set: **gate** `built_small >= 1`, `built_large >= 1`, `build_blocked_solo >= 1`, `dismantled >= 1`, `repaired >= 1`, valid winner, peak tick `< 33.3` (max across windows). Copy `docker/run-m4.5-p2-gate.sh` → `docker/run-m12-p2-gate.sh` and swap in the same assertions + a persisted `srvlog-m12-p2-<ts>.log`.

- [ ] **Step 4: Run** the ≤48 smoke locally: `./ci/m12_p2_test.sh`. Expected: PASS with the counters reported.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: CI smoke + Docker 128-bot fleet gate scripts"
```

---

## Task 15: Full-suite regression + supersede notes

**Files:**
- Modify: `docs/milestones/M4-building-destruction.md` (superseded note: instant placement → progressive shovel construction; destruction reused)
- Modify: `docs/specs/destruction.md` if it asserts instant placement (add a pointer to M12-P2)
- Test: full suite.

- [ ] **Step 1:** Run the full suite: `godot --headless --path . -- --test` → expect **0 failed** (record the count).
- [ ] **Step 2:** Boot the server headless for 10 s and confirm no script errors with sites active.
- [ ] **Step 3:** Add a one-line superseded note to the M4 building milestone/spec pointing at ADR-0007 §2 + this plan (M4 destruction reused unchanged; only instant placement replaced).
- [ ] **Step 4:** Re-run the suite.
- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M12-P2: M4 superseded notes (instant placement -> shovel construction)"
```

---

## Task 16: Gate run + milestone close-out

**Files:**
- Modify: `docs/TASKS.md`, `docs/milestones/M12-squad-fob-class-refit.md` (P2 row → done with evidence)

- [ ] **Step 1:** Run the 128-bot fleet gate on game2 (P-cores):
`cd docker && SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./run-m12-p2-gate.sh`
- [ ] **Step 2:** Confirm verdict PASS: valid winner, peak tick `< 33.3`, `built_small/built_large/build_blocked_solo/dismantled/repaired` all `≥ 1`. Save the `srvlog-m12-p2-<ts>.log`.
- [ ] **Step 3:** Record the evidence line in `docs/milestones/M12-squad-fob-class-refit.md` (P2 row) + flip the TASKS.md M12 status to `P2 done`.
- [ ] **Step 4:** Merge the branch to master via `superpowers:finishing-a-development-branch`.
- [ ] **Step 5: Commit + push** (owner authorized pushing once a major goal lands).

---

## Self-Review (completed by plan author)

**Spec coverage (spec §B):** universal shovel ✓ (Task 4 bit + Task 8 server step). Build sites replace instant placement ✓ (Task 7). Min-builders by size ✓ (Tasks 1, 2, 8 — small=1/large=2, `build_blocked_solo`). Progress accrual scaled by builders + cap ✓ (Task 2). Completion → M4 structure ✓ (Task 8 `_complete_site`). Repair (solo-allowed) ✓ (Task 6 + Task 9). Enemy shovel-dismantle (any class, slow) ✓ (Task 9). Decay ✓ (Tasks 2, 8). Catalog `build_cost`/`min_builders` + large piece ✓ (Task 1). Replication `under_construction`+`build_progress` low-cadence ✓ (Tasks 5, 8, 10). Client mirror ✓ (Task 11). Bots ✓ (Task 12). Gate counters ✓ (Tasks 13, 14, 16). **FOB (§C) intentionally excluded — M12-P3.**

**Placeholder scan:** the bot drill (Task 12) and the functional-test harness seams (Tasks 7–10) reference existing patterns the implementer must read first (`server_buildings_functional_test.gd`, the bot structure mirror) rather than inventing — flagged with `>` notes and a deterministic fallback for the bot drill. No `TODO`/`TBD`.

**Type consistency:** site record shape `{id, owner, team, type, cell, yaw, build_progress, build_cost, min_builders, last_work_tick}` is identical across Tasks 3, 7, 8. Wire record adds `under_construction`+`build_progress` consistently (Tasks 5, 7, 10, 11). `BuildSite.progress_step(progress, build_cost, builders, min_builders, dt)` signature identical in Tasks 2 and 8. `repair_chunks(id, impact, radius) -> {changed, mask}` consistent (Tasks 6, 9).

**Known risk:** the per-tick `[telemetry]`/tick budget at 128 bots with many active sites — `_step_build_sites` is O(sites × shovellers); sites are capped per player and shovellers are few, so it folds into the cheap respawn-phase cost like grenades/gadgets. Watch the `[perf]` line in the gate; if it regresses, bound site iteration with the interest grid (sites are region-indexed already).
