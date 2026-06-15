# M4 Phase 2 (Destruction) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Phase-1 fortifications destructible and add thrown explosives (frag: area damage to structures + pawns) and smoke grenades (server-side zones, no damage), holding the 128-bot tick + bandwidth budget.

**Architecture:** Pieces already carry `health`; Phase 1 only *blocked* the fire ray. Phase 2 makes the blocked shot apply `weapon.damage_body` to the piece (remove at 0 HP). Partial health replicates as coarse **75/50/25 % buckets** via a new `STRUCTURE_DELTA(OP_DAMAGE)`, emitted ≤1/piece/tick after fire+blast resolution and bounded globally by `MAX_STRUCTURE_DELTAS_PER_TICK` (graceful degradation: authoritative state is never throttled — only the send volume, removes first, overflow carried). Grenades are **server-side**, off the snapshot path, thrown via a new `GRENADE_THROW` input carrying a `type` (FRAG/SMOKE); both share throw/arc/fuse logic and only differ at detonation. **Frag** detonates at server-present time with linear-falloff area damage to structures (cell radius) and pawns (sphere, FF-off, no rewind). **Smoke** creates a server-side smoke zone `{pos, radius, expire_tick}` broadcast via `SMOKE_DEPLOYED` (no damage; consumed by M7 LOS culling — zone data only here). All math lives in `shared/` (`StructureStore`, new `Grenade` helpers) so server authority and future client prediction can't diverge (AGENTS.md §7).

**Tech Stack:** Godot 4.6 / GDScript. Headless `TestCase` unit tests (auto-discovered `tests/*_test.gd`). Bash gate script + Docker fleet.

**Spec:** `docs/specs/destruction.md`. **Branch:** `m4-destruction` (already created). **Builds on:** `docs/plans/2026-06-15-m4-building.md` (Phase 1, merged). **Next milestone after M4:** M4.5 Combat Depth (`docs/milestones/M4.5-combat-depth.md`).

---

## Conventions for the implementer (READ FIRST)

- **Import after adding a `class_name`:** run `godot --headless --path . --import` once after creating any new `class_name` script (Task 3's `Grenade`), before running tests. Do **not** pipe `godot` through `tail`/`head` (it can hang on first run) — redirect to a file if needed.
- **Run tests:** `godot --headless --path . -- --test` (all) or `--filter=<substr>` (subset; matches method name or file name). The harness **fails any test that runs zero assertions** (catches compile-error false-passes), so a green run is meaningful.
- **GDScript 4.6 gotcha:** never write `var x := <Dictionary access>` (the value is Variant and `:=` inference fails) — annotate the type explicitly, e.g. `var id: int = d["id"]`. Don't change logic to dodge this.
- **Commit trailer (every commit):**
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
  Use `git add -A` so Godot `.uid` sidecars are included.
- **Assertion helpers** (`tests/test_case.gd`): `assert_true(cond, msg)`, `assert_eq(a, b, msg)`, `assert_almost_eq(a, b, tol, msg)`. There is no `assert_false`/`assert_ne` — use `assert_eq(x, false)` / `assert_true(a != b)`.
- **Static funcs in tests:** call them via a `preload`ed script const, e.g. `const Bot := preload("res://bots/bot_driver.gd")` then `Bot.apply_structure_delta(...)` (see `tests/bot_objective_test.gd`). `StructureStore`/`Grenade`/`BuildGrid` have `class_name`, so reference them directly.
- **Server/bot integration tasks are not unit-tested** (they're `Node`s): each extracts pure helpers (unit-tested) and is finally verified by the laptop smoke (Task 12) + fleet gate (Task 13), exactly as Phase 1 did.
- **Naming note:** the spec sketch calls the blast query `cells_in_radius` returning cells; this plan implements `ids_in_radius` returning piece ids (what the blast loop actually consumes) — same intent, better signature for the caller.

---

## Task 1: StructureStore — `bucket_of` + `apply_damage`

**Files:**
- Modify: `shared/sim/structure.gd`
- Test: `tests/structure_test.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/structure_test.gd` (reuses the file's `_store()` helper and `CAT`, where type 1 = wall, health 350):
```gdscript
func test_bucket_of_thresholds() -> void:
	assert_eq(StructureStore.bucket_of(100, 100), 3)   # pristine
	assert_eq(StructureStore.bucket_of(80, 100), 3)    # >0.75
	assert_eq(StructureStore.bucket_of(75, 100), 2)    # ==0.75 -> not >0.75
	assert_eq(StructureStore.bucket_of(60, 100), 2)
	assert_eq(StructureStore.bucket_of(50, 100), 1)
	assert_eq(StructureStore.bucket_of(40, 100), 1)
	assert_eq(StructureStore.bucket_of(25, 100), 0)
	assert_eq(StructureStore.bucket_of(10, 100), 0)
	assert_eq(StructureStore.bucket_of(5, 0), 0)       # guard: max 0

func test_apply_damage_reduces_health_and_buckets() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 0, 0), 0, 7)             # wall, health 350
	var r := s.apply_damage(1, 100)                    # 250/350 = 0.714 -> bucket 2
	assert_eq(r["hit"], true)
	assert_eq(r["destroyed"], false)
	assert_eq(r["health"], 250)
	assert_eq(r["bucket"], 2)
	assert_eq(s.get_record(1)["health"], 250)

func test_apply_damage_destroys_and_frees_cell() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 0, 0), 0, 7)
	var r := s.apply_damage(1, 400)                    # lethal
	assert_eq(r["destroyed"], true)
	assert_eq(r["health"], 0)
	assert_eq(s.count(), 0)
	assert_eq(s.occupied(Vector3i(0, 0, 0)), false)
	assert_eq(s.owner_count(7), 0)

func test_apply_damage_unknown_id_is_noop() -> void:
	var s := _store()
	assert_eq(s.apply_damage(999, 50)["hit"], false)
```

- [ ] **Step 2: Run to verify they fail**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: FAIL ("Invalid call ... 'bucket_of'" / "'apply_damage'").

- [ ] **Step 3: Implement in `shared/sim/structure.gd`**

Add the bucket constant near the other consts (after line 14, `REGION_CELL`):
```gdscript
## Damage buckets as fractions of max health. A piece is bucket 3 (pristine) above 0.75, then
## 2/1/0 as it drops past 0.50/0.25. health<=0 is destroyed (removed; no bucket). Replication
## emits a STRUCTURE_DELTA(OP_DAMAGE) only when a piece crosses to a lower bucket. See
## docs/specs/destruction.md.
const DAMAGE_BUCKETS := [0.75, 0.50, 0.25]
```
Add these two functions right after `func remove(id: int)` (keep the mutators together):
```gdscript
## Current damage bucket from remaining-health fraction: 3=pristine .. 0=heavy. Pure/static.
static func bucket_of(health: int, max_health: int) -> int:
	if max_health <= 0:
		return 0
	var f := float(health) / float(max_health)
	var b := 0
	for thr in DAMAGE_BUCKETS:
		if f > thr:
			b += 1
	return b

## Apply `amount` damage to piece `id`. Returns {hit, destroyed, health, bucket}; hit=false if
## the id is unknown. On destruction the piece is removed from all indexes here (the caller emits
## the remove delta). Pure over store state — unit-testable.
func apply_damage(id: int, amount: int) -> Dictionary:
	if not _by_id.has(id):
		return {"hit": false, "destroyed": false, "health": 0, "bucket": 0}
	var rec: Dictionary = _by_id[id]
	var max_health := _catalog.health_of(int(rec["type"]))
	var h: int = int(rec["health"]) - amount
	if h <= 0:
		remove(id)
		return {"hit": true, "destroyed": true, "health": 0, "bucket": 0}
	rec["health"] = h
	return {"hit": true, "destroyed": false, "health": h, "bucket": bucket_of(h, max_health)}
```

- [ ] **Step 4: Run to verify they pass**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: PASS (old + 4 new).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M4-P2: StructureStore.apply_damage + bucket_of (piece health/destruction)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: StructureStore — `ids_in_radius` (blast query)

**Files:**
- Modify: `shared/sim/structure.gd`
- Test: `tests/structure_test.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/structure_test.gd`:
```gdscript
func test_ids_in_radius_returns_occupied_within_range() -> void:
	var s := _store()
	# cell centres: (0,0,0)->(1,1,1), (2,0,0)->(5,1,1), (3,0,0)->(7,1,1)
	s.place(1, 1, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 1, Vector3i(2, 0, 0), 0, 7)
	s.place(3, 1, Vector3i(3, 0, 0), 0, 7)
	var near := s.ids_in_radius(Vector3(1, 1, 1), 3.0)   # only id1 (id2 is 4m away)
	assert_eq(near.size(), 1)
	assert_eq(near[0], 1)
	var wider := s.ids_in_radius(Vector3(1, 1, 1), 4.5)  # id1 (0m) + id2 (4m)
	assert_eq(wider.size(), 2)
	assert_eq(wider.has(1) and wider.has(2), true)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: FAIL ("Invalid call ... 'ids_in_radius'").

- [ ] **Step 3: Implement in `shared/sim/structure.gd`**

Add after `apply_damage`:
```gdscript
## Ids of occupied pieces whose cell-centre is within `radius_m` of the world point `center`.
## Bounded by the (small) blast cell neighbourhood; used by explosive area damage. Array[int].
func ids_in_radius(center: Vector3, radius_m: float) -> Array:
	var out: Array = []
	var cr := int(ceil(radius_m / BuildGrid.CELL_SIZE))
	var cc := BuildGrid.cell_of(center)
	var half := BuildGrid.CELL_SIZE * 0.5
	for dx in range(-cr, cr + 1):
		for dy in range(-cr, cr + 1):
			for dz in range(-cr, cr + 1):
				var cell := Vector3i(cc.x + dx, cc.y + dy, cc.z + dz)
				if not _occupancy.has(cell):
					continue
				var wc := BuildGrid.cell_min(cell) + Vector3(half, half, half)
				if wc.distance_to(center) <= radius_m:
					out.append(int(_occupancy[cell]))
	return out
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=structure_test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M4-P2: StructureStore.ids_in_radius (blast area query)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Grenade — pure ballistic + falloff helpers (+ FRAG/SMOKE types)

**Files:**
- Create: `shared/sim/grenade.gd`
- Test: `tests/grenade_test.gd`

- [ ] **Step 1: Write the failing test**

`tests/grenade_test.gd`:
```gdscript
extends TestCase

func test_types_are_distinct() -> void:
	assert_eq(Grenade.FRAG, 0)
	assert_eq(Grenade.SMOKE, 1)

func test_launch_velocity_is_dir_times_speed() -> void:
	var v := Grenade.launch_velocity(Vector3(1, 0, 0))
	assert_almost_eq(v.x, Grenade.THROW_SPEED, 0.001)
	assert_almost_eq(v.y, 0.0, 0.001)

func test_integrate_applies_gravity() -> void:
	var s := Grenade.integrate(Vector3.ZERO, Vector3.ZERO, 0.1)
	# v = -G*dt = -2.0; pos = v*dt = -0.2
	assert_almost_eq(s["vel"].y, -2.0, 0.001)
	assert_almost_eq(s["pos"].y, -0.2, 0.001)

func test_falloff_is_linear_to_zero_at_edge() -> void:
	var c := Vector3.ZERO
	assert_eq(Grenade.falloff_damage(c, Vector3.ZERO, 100, 6.0), 100)
	assert_eq(Grenade.falloff_damage(c, Vector3(3, 0, 0), 100, 6.0), 50)
	assert_eq(Grenade.falloff_damage(c, Vector3(6, 0, 0), 100, 6.0), 0)
	assert_eq(Grenade.falloff_damage(c, Vector3(9, 0, 0), 100, 6.0), 0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=grenade_test`
Expected: FAIL (Grenade not found).

- [ ] **Step 3: Implement `shared/sim/grenade.gd`**

```gdscript
class_name Grenade
extends Object
## Pure helpers for server-side thrown grenades (M4 Phase 2). A grenade is a plain dict held by
## the server; these are the deterministic, unit-testable math for its ballistic flight and blast
## falloff. The `type` (FRAG/SMOKE) is stored on that dict — throw/arc/fuse are identical for both;
## only the detonation side effect differs (server). Nothing here touches networking or the
## snapshot path. See docs/specs/destruction.md.

const FRAG := 0            # area damage to structures + pawns
const SMOKE := 1           # spawns a smoke zone (no damage)

const GRAVITY := 20.0      # m/s^2 downward (gameplay gravity, not realistic 9.8)
const THROW_SPEED := 18.0  # initial launch speed (m/s)

## Initial velocity for a throw in look-direction `dir`.
static func launch_velocity(dir: Vector3) -> Vector3:
	return dir.normalized() * THROW_SPEED

## One integration step of the ballistic arc. Returns {pos:Vector3, vel:Vector3}.
static func integrate(pos: Vector3, vel: Vector3, dt: float) -> Dictionary:
	var v := vel - Vector3(0.0, GRAVITY, 0.0) * dt
	return {"pos": pos + v * dt, "vel": v}

## Linear-falloff damage from a blast at `center` onto a point `at`: max_dmg at the centre,
## 0 at/beyond `radius`. Never negative.
static func falloff_damage(center: Vector3, at: Vector3, max_dmg: int, radius: float) -> int:
	if radius <= 0.0:
		return 0
	var d := center.distance_to(at)
	if d >= radius:
		return 0
	return int(round(float(max_dmg) * (1.0 - d / radius)))
```

- [ ] **Step 4: Import + run to verify it passes**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=grenade_test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M4-P2: Grenade pure helpers + FRAG/SMOKE types

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Protocol — `OP_DAMAGE`, `GRENADE_THROW(type)`, `SMOKE_DEPLOYED`

**Files:**
- Modify: `shared/net/protocol.gd`
- Test: `tests/protocol_test.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/protocol_test.gd`:
```gdscript
func test_structure_delta_damage_roundtrip() -> void:
	var b := Protocol.encode_structure_delta(Protocol.OP_DAMAGE, {"id": 42, "bucket": 1})
	var d := Protocol.decode_structure_delta(b)
	assert_eq(d["op"], Protocol.OP_DAMAGE)
	assert_eq(d["id"], 42)
	assert_eq(d["bucket"], 1)

func test_structure_delta_place_and_remove_still_roundtrip() -> void:
	var rec := {"id": 7, "type": 1, "cell": Vector3i(-3, 0, 5), "yaw": 2, "health": 350, "owner": 9}
	var pd := Protocol.decode_structure_delta(Protocol.encode_structure_delta(Protocol.OP_PLACE, rec))
	assert_eq(pd["rec"]["id"], 7)
	assert_eq(pd["rec"]["health"], 350)
	var rd := Protocol.decode_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 7}))
	assert_eq(rd["op"], Protocol.OP_REMOVE)
	assert_eq(rd["id"], 7)

func test_grenade_throw_roundtrip() -> void:
	var d := Protocol.decode_grenade_throw(Protocol.encode_grenade_throw(Vector3(1, 0, 0), Grenade.SMOKE))
	assert_almost_eq(d["dir"].x, 1.0, 0.001)
	assert_almost_eq(d["dir"].y, 0.0, 0.001)
	assert_eq(d["type"], Grenade.SMOKE)

func test_smoke_deployed_roundtrip() -> void:
	var d := Protocol.decode_smoke_deployed(Protocol.encode_smoke_deployed(Vector3(10, 0, -20), 6.0, 1234))
	assert_eq(d["pos"], Vector3(10, 0, -20))
	assert_eq(d["radius"], 6)
	assert_eq(d["expire_tick"], 1234)
```

- [ ] **Step 2: Run to verify they fail**

Run: `godot --headless --path . -- --test --filter=protocol_test`
Expected: FAIL ("OP_DAMAGE" / "encode_grenade_throw" / "encode_smoke_deployed" not found).

- [ ] **Step 3: Implement in `shared/net/protocol.gd`**

In the `Msg` enum, after `STRUCTURE_BASELINE = 11,`:
```gdscript
	GRENADE_THROW = 12,     ## client -> server: throw a grenade (type FRAG/SMOKE) in a look dir
	# DETONATION = 13       ## RESERVED (M7 frag VFX); not sent in the M4-P2 gate
	SMOKE_DEPLOYED = 14,    ## server -> clients: a smoke zone was created (pos/radius/expire)
```
After `const OP_REMOVE := 1`:
```gdscript
const OP_DAMAGE := 2   ## STRUCTURE_DELTA payload {id u16, bucket u8} — partial-health bucket drop
```
Replace `encode_structure_delta` / `decode_structure_delta` with the 3-op versions:
```gdscript
static func encode_structure_delta(op: int, rec: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.STRUCTURE_DELTA)
	buf.put_u8(op)
	if op == OP_PLACE:
		_put_record(buf, rec)
	elif op == OP_DAMAGE:
		buf.put_u16(int(rec["id"]))
		buf.put_u8(int(rec["bucket"]))
	else:
		buf.put_u16(int(rec["id"]))
	return buf.data_array


static func decode_structure_delta(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var op := r.get_u8()
	if op == OP_PLACE:
		return {"op": op, "rec": _get_record(r)}
	elif op == OP_DAMAGE:
		var id := r.get_u16()
		return {"op": op, "id": id, "bucket": r.get_u8()}
	return {"op": op, "id": r.get_u16()}
```
Add the grenade + smoke messages (after `decode_build_remove`):
```gdscript
static func encode_grenade_throw(dir: Vector3, type: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GRENADE_THROW)
	var d := dir.normalized()
	buf.put_16(roundi(d.x * 10000.0))
	buf.put_16(roundi(d.y * 10000.0))
	buf.put_16(roundi(d.z * 10000.0))
	buf.put_u8(type)
	return buf.data_array


static func decode_grenade_throw(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var x := float(r.get_16()) / 10000.0
	var y := float(r.get_16()) / 10000.0
	var z := float(r.get_16()) / 10000.0
	return {"dir": Vector3(x, y, z), "type": r.get_u8()}


static func encode_smoke_deployed(pos: Vector3, radius: float, expire_tick: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SMOKE_DEPLOYED)
	buf.put_16(roundi(pos.x)); buf.put_16(roundi(pos.y)); buf.put_16(roundi(pos.z))
	buf.put_u8(clampi(roundi(radius), 0, 255))
	buf.put_u16(clampi(expire_tick, 0, 65535))   # absolute tick (u16); fine for gate-length matches
	return buf.data_array


static func decode_smoke_deployed(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var pos := Vector3(r.get_16(), r.get_16(), r.get_16())
	return {"pos": pos, "radius": r.get_u8(), "expire_tick": r.get_u16()}
```

- [ ] **Step 4: Run to verify they pass**

Run: `godot --headless --path . -- --test --filter=protocol_test`
Expected: PASS (old protocol tests + 4 new).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M4-P2: protocol OP_DAMAGE + GRENADE_THROW(type) + SMOKE_DEPLOYED

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Bot structure mirror — handle `OP_DAMAGE` without erasing

**Files:**
- Modify: `bots/bot_driver.gd`
- Test: `tests/bot_mirror_test.gd`

> **Why this matters:** the current `_on_packet` `STRUCTURE_DELTA` branch does `bot["structs"].erase(d["id"])` for any op that isn't `OP_PLACE`. With the new `OP_DAMAGE` op that would **wrongly delete a damaged-but-alive piece** from the bot's mirror. Extract a pure 3-op handler and unit-test it.

- [ ] **Step 1: Write the failing test**

`tests/bot_mirror_test.gd`:
```gdscript
extends TestCase

const Bot := preload("res://bots/bot_driver.gd")

func test_place_damage_remove_mirror() -> void:
	var s := {}
	Bot.apply_structure_delta(s, {"op": Protocol.OP_PLACE, "rec": {"id": 5, "bucket": 3}})
	assert_eq(s.has(5), true)
	Bot.apply_structure_delta(s, {"op": Protocol.OP_DAMAGE, "id": 5, "bucket": 1})
	assert_eq(s.has(5), true)          # damage must NOT erase
	assert_eq(s[5]["bucket"], 1)
	Bot.apply_structure_delta(s, {"op": Protocol.OP_REMOVE, "id": 5})
	assert_eq(s.has(5), false)

func test_damage_on_unknown_id_is_noop() -> void:
	var s := {}
	Bot.apply_structure_delta(s, {"op": Protocol.OP_DAMAGE, "id": 9, "bucket": 0})
	assert_eq(s.has(9), false)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=bot_mirror`
Expected: FAIL ("Invalid call ... 'apply_structure_delta'").

- [ ] **Step 3: Implement in `bots/bot_driver.gd`**

Add the static helper (near the other static helpers, e.g. after `combat_button`):
```gdscript
## Apply a decoded STRUCTURE_DELTA to a bot's local mirror (id->record). PLACE inserts, DAMAGE
## updates the record's bucket in place (must NOT remove), REMOVE erases. Pure + unit-tested;
## the live path runs inside _on_packet. See docs/specs/destruction.md.
static func apply_structure_delta(structs: Dictionary, d: Dictionary) -> void:
	var op: int = d["op"]
	if op == Protocol.OP_PLACE:
		structs[d["rec"]["id"]] = d["rec"]
	elif op == Protocol.OP_DAMAGE:
		var id: int = d["id"]
		if structs.has(id):
			structs[id]["bucket"] = d["bucket"]
	else:
		structs.erase(d["id"])
```
Replace the `STRUCTURE_DELTA` case body in `_on_packet`:
```gdscript
		Protocol.Msg.STRUCTURE_DELTA:
			apply_structure_delta(bot["structs"], Protocol.decode_structure_delta(bytes))
			_note_sync(bot)
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=bot_mirror`
Expected: PASS (2 tests). Then full suite (`-- --test`) — all green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M4-P2: bot structure mirror handles OP_DAMAGE (no erroneous erase)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Server — bullet damage in `_fire_shot` + `_damage_structure` helper

**Files:**
- Modify: `server/server_main.gd` (state vars; `_fire_shot`; new `_damage_structure`)
- Test: `tests/structure_cover_test.gd` (a focused store-level behavior test)

> Server `_fire_shot` is not unit-testable directly; the math it calls (`apply_damage`) is covered by Task 1. We add a focused test proving repeated shots through cover destroy a wall, then verify the wiring in the smoke/gate.

- [ ] **Step 1: Add destruction state vars**

In `server/server_main.gd`, after line 58 (`var _shots_blocked := 0`), add:
```gdscript
var _dmg := 0                 # damage events applied this window
var _destroyed := 0           # pieces removed by damage/blast this window
var _nades := 0               # frag detonations this window
var _splash_kills := 0        # pawn deaths from blasts this window
var _smokes := 0              # smoke zones deployed this window
var _pending_removes: Array = []   # [{id, cell}] removes awaiting send (degradation queue)
var _dmg_touched := {}             # id -> true: pieces damaged (alive) this tick, for bucket diff
var _last_bucket := {}             # id -> last SENT bucket (missing => pristine bucket 3)
```
Add the constant near the top (after line 25, `MATCH_END_DRAIN_TICKS`):
```gdscript
const MAX_STRUCTURE_DELTAS_PER_TICK := 64   # graceful degradation: cap delta SENDS/tick
```

- [ ] **Step 2: Add the `_damage_structure` helper**

Add near `_emit_structure_delta` (around line 462):
```gdscript
## Apply damage to a piece and record the side effects for end-of-tick replication
## (_emit_structure_deltas). Destruction queues a remove + frees the cell (in apply_damage);
## a non-lethal hit marks the piece for a bucket-diff check.
func _damage_structure(id: int, amount: int) -> void:
	var cell := _cell_of_struct(id)       # capture BEFORE possible removal
	var res := _store.apply_damage(id, amount)
	if not res["hit"]:
		return
	_dmg += 1
	if res["destroyed"]:
		_destroyed += 1
		_pending_removes.append({"id": id, "cell": cell})
		_dmg_touched.erase(id)
		_last_bucket.erase(id)
	else:
		_dmg_touched[id] = true
```

- [ ] **Step 3: Apply damage on a blocked shot in `_fire_shot`**

Replace the cover block (current lines 226-239) with a version that captures the blocking id and damages it:
```gdscript
	var block_dist := INF
	var block_id := 0
	if _store.count() > 0:
		var march_max: float = best_t if best_victim != 0 else max_range
		var blocked := _store.march(ray["origin"], ray["dir"], march_max)
		if blocked["hit"]:
			block_dist = blocked["dist"]
			block_id = int(blocked["id"])
	if best_victim == 0 or block_dist < best_t:
		if block_id != 0:
			_shots_blocked += 1
			_damage_structure(block_id, int(Weapon.get_def(wid)["damage_body"]))
		return
	_hits += 1
```

- [ ] **Step 4: Add the focused store test**

Append to `tests/structure_cover_test.gd`:
```gdscript
func test_repeated_shots_destroy_wall() -> void:
	var store := StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	store.place(1, 0, Vector3i(2, 0, -1), 0, 99)        # wall health 350, between origin and +x
	var origin := Vector3(0.0, 1.5, -1.0)
	var dir := Vector3(1, 0, 0)
	# 25 dmg/shot * 14 = 350 -> destroyed; the march must miss afterwards.
	for i in 14:
		var hit := store.march(origin, dir, 50.0)
		assert_eq(hit["hit"], true, "wall still present at shot %d" % i)
		store.apply_damage(int(hit["id"]), 25)
	assert_eq(store.count(), 0)
	assert_eq(store.march(origin, dir, 50.0)["hit"], false)
```
> `CAT` in `structure_cover_test.gd` uses a single `wall` piece at type 0 — confirm the const at the top of that file; if `wall` is type 1 there, use `0` consistently with the existing tests in the file.

- [ ] **Step 5: Import + run to verify it passes**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test --filter=structure_cover`
Expected: PASS. Then full suite — all green. (The server itself is exercised in Task 12.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "M4-P2: blocked shots damage cover; _damage_structure + degradation queue

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Server — `_emit_structure_deltas` (bucket diff + send cap)

**Files:**
- Modify: `server/server_main.gd` (`_physics_process` order; new `_emit_structure_deltas`)

> Flushes per-tick destruction replication: removes first (bounded), then one bucket-drop delta per surviving damaged piece, all under `MAX_STRUCTURE_DELTAS_PER_TICK`. Overflow stays queued for next tick (state already authoritative).

- [ ] **Step 1: Add `_emit_structure_deltas`**

Add after `_damage_structure`:
```gdscript
## Flush queued removes + bucket drops to interested clients, bounded by
## MAX_STRUCTURE_DELTAS_PER_TICK (removes first; overflow carried to next tick). Authoritative
## state is already applied — only the SEND volume is throttled. See docs/specs/destruction.md.
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
		var max_health := _catalog.health_of(int(rec["type"]))
		var bucket := StructureStore.bucket_of(int(rec["health"]), max_health)
		if bucket < int(_last_bucket.get(id, 3)):
			_last_bucket[id] = bucket
			_emit_structure_delta(Protocol.OP_DAMAGE, {"id": id, "bucket": bucket}, rec["cell"])
		_dmg_touched.erase(id)
		budget -= 1
```

- [ ] **Step 2: Call it before snapshots in `_physics_process`**

Replace the `_track_and_broadcast_match_state()` → `var t_match` → `_send_snapshots()` → `var t_snap` sequence (lines 112-115) with:
```gdscript
	_track_and_broadcast_match_state()
	var t_match := Time.get_ticks_usec()
	_emit_structure_deltas()
	_send_snapshots()
	var t_snap := Time.get_ticks_usec()
```
(The `_emit_structure_deltas()` cost folds into the `snap` phase — small and bounded.)

- [ ] **Step 3: Reset the new counters each window**

In `_log_telemetry`, add to the reset block at line 519:
```gdscript
	_dmg = 0; _destroyed = 0; _nades = 0; _splash_kills = 0; _smokes = 0
```

- [ ] **Step 4: Verify it compiles + suite green**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test`
Expected: PASS (server_main still compiles).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M4-P2: _emit_structure_deltas — bucket diff + capped send w/ carry

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Server — grenade throw + `_step_grenades` (frag detonation)

**Files:**
- Modify: `server/server_main.gd` (state; client init; `_on_packet`; `_physics_process`; new `_handle_grenade_throw`, `_step_grenades`, `_detonate`)

> Server-side grenades, off the snapshot path. Throw validated + cooldown-gated; carries `type`; simulated as a ballistic arc; **frag** detonates at present-time with falloff area damage to structures (via `_damage_structure`) and pawns (FF-off, current positions). The **smoke** branch is added in Task 9.

- [ ] **Step 1: Add grenade state + constants**

After the destruction state vars (Task 6 Step 1), add:
```gdscript
var _grenades: Array = []     # [{owner, team, type, pos, vel, detonate_tick}] — server-side, not replicated
```
After `const MAX_STRUCTURE_DELTAS_PER_TICK` (Task 6 Step 1), add:
```gdscript
const GRENADE_FUSE_TICKS := 45        # 1.5s @30Hz
const GRENADE_COOLDOWN_TICKS := 300   # 10s between a player's throws (shared frag/smoke)
const BLAST_PAWN_RADIUS := 6.0        # m, sphere (current positions, FF-off)
const BLAST_STRUCT_RADIUS := 4.0      # m (~2 build cells)
const GRENADE_DAMAGE_PAWN := 100      # frag pawn splash at centre, linear falloff
const GRENADE_DAMAGE_STRUCT := 200    # frag structure splash at centre, linear falloff
```

- [ ] **Step 2: Init the per-client cooldown**

In `_handle_hello`, in the client dict literal (near line 396, alongside `"last_build_tick": -100000,`), add:
```gdscript
		"last_grenade_tick": -100000,
```

- [ ] **Step 3: Route the new message**

In `_on_packet`'s `match` (after the `BUILD_REMOVE` case, line 369):
```gdscript
		Protocol.Msg.GRENADE_THROW: _handle_grenade_throw(peer, bytes)
```

- [ ] **Step 4: Add the throw handler**

Add after `_handle_build_remove`:
```gdscript
func _handle_grenade_throw(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive: return
	if _sim.tick - int(c["last_grenade_tick"]) < GRENADE_COOLDOWN_TICKS: return
	var d := Protocol.decode_grenade_throw(bytes)
	var dir: Vector3 = d["dir"]
	if dir.length() < 0.001: return
	c["last_grenade_tick"] = _sim.tick
	_grenades.append({
		"owner": id, "team": p.team, "type": int(d["type"]),
		"pos": p.eye_position(), "vel": Grenade.launch_velocity(dir),
		"detonate_tick": _sim.tick + GRENADE_FUSE_TICKS,
	})
```

- [ ] **Step 5: Add the step + frag detonation**

Add after `_handle_grenade_throw`:
```gdscript
## Integrate live grenades; detonate on fuse or ground contact (v1). Detonation is present-time.
func _step_grenades() -> void:
	if _grenades.is_empty():
		return
	var still: Array = []
	for g in _grenades:
		if _sim.tick >= int(g["detonate_tick"]):
			_detonate(g)
			continue
		var s := Grenade.integrate(g["pos"], g["vel"], SimLoop.DT)
		g["pos"] = s["pos"]; g["vel"] = s["vel"]
		if g["pos"].y <= 0.0:
			g["pos"].y = 0.0
			_detonate(g)
		else:
			still.append(g)
	_grenades = still

## Frag: area damage at the grenade's current position — structures (cell radius) + pawns (sphere,
## current positions, FF-off incl. thrower). Removes/bucket-drops route through _damage_structure.
## (Smoke is handled by a branch added in Task 9.)
func _detonate(g: Dictionary) -> void:
	_nades += 1
	var center: Vector3 = g["pos"]
	for sid in _store.ids_in_radius(center, BLAST_STRUCT_RADIUS):
		var rec := _store.get_record(sid)
		if rec.is_empty(): continue
		var at := BuildGrid.cell_min(rec["cell"]) + Vector3.ONE * (BuildGrid.CELL_SIZE * 0.5)
		var sd := Grenade.falloff_damage(center, at, GRENADE_DAMAGE_STRUCT, BLAST_STRUCT_RADIUS)
		if sd > 0:
			_damage_structure(sid, sd)
	var owner: int = int(g["owner"])
	var team: int = int(g["team"])
	for pid in _sim.world.pawns:
		if pid == owner: continue
		var victim: Pawn = _sim.world.pawns[pid]
		if not victim.alive or victim.team == team: continue
		var pd := Grenade.falloff_damage(center, victim.pos, GRENADE_DAMAGE_PAWN, BLAST_PAWN_RADIUS)
		if pd <= 0: continue
		victim.health -= pd
		if victim.health <= 0:
			victim.health = 0
			victim.alive = false
			_clients[pid]["respawn_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
			_conquest.register_death(victim.team)
			_kills += 1
			_splash_kills += 1
			var ev := Protocol.encode_kill(pid, owner, 0, false)
			for cid in _clients:
				_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, ev, ENetPacketPeer.FLAG_RELIABLE)
```

- [ ] **Step 6: Step grenades in `_physics_process`**

Between `_resolve_fires()` (line 106) and `_handle_respawns()` (line 108), insert the grenade step so splash deaths are picked up by respawn handling + the conquest step:
```gdscript
	_resolve_fires()
	var t_fire := Time.get_ticks_usec()
	_step_grenades()
	_handle_respawns()
```
(The `_step_grenades()` cost folds into the `respawn` phase timer — small, bounded by the throw rate.)

- [ ] **Step 7: Verify it compiles + suite green**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test`
Expected: PASS (grenade math covered by Task 3; server compiles).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "M4-P2: server-side grenades — throw, ballistic step, frag present-time blast

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Server — smoke grenades (zone + `SMOKE_DEPLOYED` + expiry)

**Files:**
- Modify: `server/server_main.gd` (state; constants; `_detonate` branch; new `_deploy_smoke`, `_expire_smoke_zones`; `_physics_process`)

> Smoke shares the entire throw/arc/fuse path (Task 8). Only detonation differs: no damage; create a server-side smoke zone and broadcast `SMOKE_DEPLOYED`. Zone data is consumed by M7 LOS culling — here it just exists, replicates, and expires. No hard gate assertion (the destruction gate is frag-driven); a `smoke=` telemetry counter surfaces it.

- [ ] **Step 1: Add smoke state + constants**

After `var _grenades: Array = []` (Task 8 Step 1):
```gdscript
var _smoke_zones: Array = []  # [{pos, radius, expire_tick}] — server-side; M7 LOS culling consumes
```
After the grenade constants (Task 8 Step 1):
```gdscript
const SMOKE_DURATION_TICKS := 150     # 5s @30Hz — smoke zone lifetime
const SMOKE_RADIUS := 6.0             # m — smoke zone radius (matches blast radius)
```

- [ ] **Step 2: Branch `_detonate` on grenade type**

At the very top of `_detonate` (Task 8 Step 5), before `_nades += 1`, add the smoke short-circuit:
```gdscript
func _detonate(g: Dictionary) -> void:
	if int(g["type"]) == Grenade.SMOKE:
		_deploy_smoke(g)
		return
	_nades += 1
	# ... existing frag body unchanged ...
```

- [ ] **Step 3: Add `_deploy_smoke` + `_expire_smoke_zones`**

Add after `_detonate`:
```gdscript
## Smoke detonation: no damage. Record a server-side zone and broadcast it (low-frequency, like
## KILL — bounded by the throw cooldown). M7 LOS culling will read _smoke_zones; here it just
## replicates the zone so clients know it exists.
func _deploy_smoke(g: Dictionary) -> void:
	_smokes += 1
	var expire: int = _sim.tick + SMOKE_DURATION_TICKS
	_smoke_zones.append({"pos": g["pos"], "radius": SMOKE_RADIUS, "expire_tick": expire})
	var bytes := Protocol.encode_smoke_deployed(g["pos"], SMOKE_RADIUS, expire)
	for cid in _clients:
		_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

## Drop expired smoke zones (O(zones); negligible). Keeps _smoke_zones bounded for the M7 reader.
func _expire_smoke_zones() -> void:
	if _smoke_zones.is_empty():
		return
	var live: Array = []
	for z in _smoke_zones:
		if _sim.tick < int(z["expire_tick"]):
			live.append(z)
	_smoke_zones = live
```

- [ ] **Step 4: Expire smoke each tick**

Right after the `_step_grenades()` call in `_physics_process` (Task 8 Step 6):
```gdscript
	_step_grenades()
	_expire_smoke_zones()
	_handle_respawns()
```

- [ ] **Step 5: Verify it compiles + suite green**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test`
Expected: PASS (server compiles; smoke is server-side, covered end-to-end in the smoke run + gate).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "M4-P2: smoke grenades — server zone + SMOKE_DEPLOYED broadcast + expiry

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: Server — destruction telemetry

**Files:**
- Modify: `server/server_main.gd` (`_log_telemetry`)

- [ ] **Step 1: Extend the telemetry line**

In `_log_telemetry`, extend the `[telemetry]` format string + args (lines 510-511). Append `dmg=%d destroyed=%d nades=%d splash=%d smoke=%d` to the format and the matching args at the end:
```gdscript
	print("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d t0=%d t1=%d pts=%s cap_events=%d struct=%d bld=%d rmv=%d blk=%d dmg=%d destroyed=%d nades=%d splash=%d smoke=%d"
		% [n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit, _kills, _shots, hit_rate, _tele.starvation, _rewind_clamped, _conquest.tickets_int(0), _conquest.tickets_int(1), pts, _cap_events, _store.count(), _builds, _removes, _shots_blocked, _dmg, _destroyed, _nades, _splash_kills, _smokes])
```
(Per-window resets were added in Task 7 Step 3.)

- [ ] **Step 2: Verify it compiles + suite green**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "M4-P2: telemetry — dmg/destroyed/nades/splash/smoke counters

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: Bots — grenade heuristic (frag at cover + smoke on advance)

**Files:**
- Modify: `bots/bot_driver.gd` (constants; bot dict init; `_drive`; new `_maybe_grenade`, `_maybe_smoke`, `_cover_between`; `_on_packet`)

> Bullet destruction needs no new AI (bots already fire through cover → walls now break). Add: (a) a **frag** throw when an in-view enemy is behind cover — drives the blast/destruction gate; (b) a **smoke** throw when advancing on the objective with no target — exercises the smoke path. Both share the server throw cooldown; each has its own per-bot cap so frag (the gate-critical path) always fires.

- [ ] **Step 1: Add constants**

In `bots/bot_driver.gd`, after the `MAX_BOT_BUILDS` const block (around line 15):
```gdscript
const GRENADE_COOLDOWN_TICKS := 300   # match server GRENADE_COOLDOWN_TICKS (10s, shared frag/smoke)
const MAX_BOT_GRENADES := 1           # per-bot lifetime FRAG cap (convergence/over-destruction knob)
const MAX_BOT_SMOKES := 1             # per-bot lifetime SMOKE cap (exercises the smoke path)
```

- [ ] **Step 2: Init per-bot grenade state**

In `_spawn_bot`'s `bot` dict literal (line 50, alongside `"last_build_tick"...`), add:
```gdscript
		"last_grenade_tick": -100000, "nades_thrown": 0, "smokes_thrown": 0,
```

- [ ] **Step 3: Wire the two heuristics into `_drive`**

In `_drive`, inside the `if target != null:` branch, after the `var cb := combat_button(...)` lines (~line 110), add the frag attempt:
```gdscript
		_maybe_grenade(bot, me, target)
```
In the `else:` branch (no enemy in view — the bot marches to the objective), after `bot["yaw"] = atan2(move_x, move_y)` (~line 116), add the smoke attempt toward the objective:
```gdscript
		_maybe_smoke(bot, me, obj)
```

- [ ] **Step 4: Add the helpers**

Add after `_maybe_build` (around line 146):
```gdscript
## Throw a FRAG at an in-view enemy when a structure sits roughly on the line between us and them
## (so the blast clears cover) — shared cooldown + per-bot frag cap. Drives the blast/destruction gate.
func _maybe_grenade(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if int(bot["nades_thrown"]) >= MAX_BOT_GRENADES:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < GRENADE_COOLDOWN_TICKS:
		return
	if not _cover_between(bot, me.pos, target.pos):
		return
	var dir := target.pos - me.pos
	if dir.length() < 0.001:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), Grenade.FRAG), 0)
	bot["last_grenade_tick"] = st
	bot["nades_thrown"] = int(bot["nades_thrown"]) + 1

## Throw a SMOKE toward the objective while advancing (no target) — shared cooldown + per-bot smoke
## cap. No gameplay effect until M7 LOS culling; exercises the smoke replication path for the gate.
func _maybe_smoke(bot: Dictionary, me: EntityState, obj: Vector3) -> void:
	if int(bot["smokes_thrown"]) >= MAX_BOT_SMOKES:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < GRENADE_COOLDOWN_TICKS:
		return
	var dir := obj - me.pos
	if dir.length() < 0.001:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), Grenade.SMOKE), 0)
	bot["last_grenade_tick"] = st
	bot["smokes_thrown"] = int(bot["smokes_thrown"]) + 1

## True if any known structure's cell-centre lies near the segment from `a` to `b` (coarse: the
## bot only knows piece positions from its mirror, not exact AABBs). Bounds the throw to useful cases.
func _cover_between(bot: Dictionary, a: Vector3, b: Vector3) -> bool:
	var seg := b - a
	var seg_len := seg.length()
	if seg_len < 0.001:
		return false
	var n := seg / seg_len
	for id in bot["structs"]:
		var cell: Vector3i = bot["structs"][id]["cell"]
		var c := BuildGrid.cell_min(cell) + Vector3.ONE * (BuildGrid.CELL_SIZE * 0.5)
		var t := clampf((c - a).dot(n), 0.0, seg_len)
		if (a + n * t).distance_to(c) <= BuildGrid.CELL_SIZE:   # within ~one cell of the line
			return true
	return false
```

- [ ] **Step 5: Drain `SMOKE_DEPLOYED` on the bot (no-op for the gate)**

In `_on_packet`'s `match`, before the `_: pass` default, add an explicit no-op case (documents intent; smoke has no bot effect until M7):
```gdscript
		Protocol.Msg.SMOKE_DEPLOYED:
			pass   # no bot-side effect until M7 LOS culling; received reliably, nothing to do
```

- [ ] **Step 6: Verify it compiles + suite green**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test`
Expected: PASS (bot_driver compiles; `apply_structure_delta` test from Task 5 still green).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "M4-P2: bot grenade AI — frag at cover, smoke on advance (capped)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 12: Local smoke run (laptop, 48 bots)

**Files:** none (manual verification before the fleet gate)

> The laptop cannot run 128 bots (thermal throttle — HANDOVER). The 48-bot run proves the destruction loop end-to-end and lets you tune caps/blast constants before the fleet gate.

- [ ] **Step 1: Run the building gate at 48 bots (destruction now active)**

The building gate script also exercises destruction now (bullets damage cover; bots throw frag/smoke). Run it on the laptop:
```bash
GODOT=godot BOTS=48 MAX_WAIT=420 SERVER_CPUS=0-3 BOTS_CPUS=4-15 ci/m4_building_test.sh
```
Expected: `M4 GATE: PASS` (Phase-1 assertions still hold). Capture the server log and confirm the **new** destruction signals and a winner:
```bash
# the script logs to a mktemp; re-run capturing explicitly if needed:
#   ... ci/m4_building_test.sh ... ; then grep the printed server log path
grep -oE 'destroyed=[0-9]+|nades=[0-9]+|splash=[0-9]+|smoke=[0-9]+' <server_log>
```
Look for `destroyed=` and `nades=` rising above 0 (and `smoke=` ≥ 0; it may be 0 if all bots find cover-targets first — fine), plus a `[match] OVER winner=…` line. If `nades`/`destroyed` stay 0, the frag heuristic isn't firing — loosen `_cover_between` (e.g. `BuildGrid.CELL_SIZE * 1.5`) or lower `GRENADE_COOLDOWN_TICKS` for the smoke test.

- [ ] **Step 2: Confirm the loop still converges**

A match must still reach a winner well under `MAX_WAIT`. If destruction + splash over-accelerate or stall convergence, tune `MAX_BOT_GRENADES` (down to throttle) — the convergence knob mirroring `MAX_BOT_BUILDS`.

- [ ] **Step 3: No commit** (verification only). Record observed numbers for the milestone evidence (Task 13).

---

## Task 13: M4-P2 gate script + fleet gate + evidence

**Files:**
- Create: `ci/m4_destruction_test.sh`
- Modify: `docker/run-m4-gate.sh` (add P2 assertions) — or document running both
- Modify: `docs/milestones/M4-building-destruction.md` (Phase 2 evidence)

- [ ] **Step 1: Create `ci/m4_destruction_test.sh`**

Copy `ci/m4_building_test.sh` and add the destruction assertions. Full file:
```bash
#!/usr/bin/env bash
# M4 Phase-2 gate: server + bots play Conquest with building + DESTRUCTION enabled. Assert a
# winner is declared, pieces are destroyed and frags detonate, structures still replicate, and the
# peak-window server tick stays under budget. (Smoke is reported, not gated — destruction is the
# frag-driven path.) Exit non-zero on breach. 128 on the fleet; 48 on the dev laptop.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27242}"
BOTS="${BOTS:-128}"
TICKETS="${TICKETS:-80}"
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
SERVER_CPUS="${SERVER_CPUS:-0-3}"
BOTS_CPUS="${BOTS_CPUS:-4-15}"
if command -v taskset >/dev/null 2>&1; then
	SRV_PIN=(taskset -c "$SERVER_CPUS"); BOT_PIN=(taskset -c "$BOTS_CPUS")
	echo "[m4p2] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m4p2] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m4p2] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m4p2] $BOTS bots (building + destruction enabled)"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

waited=0; over_line=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over_line="$(grep -m1 '\[match\] OVER' "$server_log" || true)"
	[ -n "$over_line" ] && break
	sleep 3; waited=$((waited+3))
done

echo "--- match result ---"; echo "$over_line"
if [ -z "$over_line" ]; then echo "FAIL: no winner within ${MAX_WAIT}s"; exit 1; fi

winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"
destroyed_total="$(grep -oE 'destroyed=[0-9]+' "$server_log" | sed 's/destroyed=//' | awk '{s+=$1} END{print s+0}')"
nades_total="$(grep -oE 'nades=[0-9]+' "$server_log" | sed 's/nades=//' | awk '{s+=$1} END{print s+0}')"
splash_total="$(grep -oE 'splash=[0-9]+' "$server_log" | sed 's/splash=//' | awk '{s+=$1} END{print s+0}')"
smoke_total="$(grep -oE 'smoke=[0-9]+' "$server_log" | sed 's/smoke=//' | awk '{s+=$1} END{print s+0}')"
synced="$(grep -m1 'structures synced' "$bots_log" || true)"
echo "[m4p2] winner=${winner} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) destroyed=${destroyed_total} nades=${nades_total} splash=${splash_total} smoke=${smoke_total}"
echo "[m4p2] ${synced:-<no structures synced to bots>}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${destroyed_total:-0}" -ge 1 ] || { echo "FAIL: no pieces were destroyed"; ok=0; }
[ "${nades_total:-0}" -ge 1 ] || { echo "FAIL: no frags detonated"; ok=0; }
[ -n "$synced" ] || { echo "FAIL: structures did not replicate to bots"; ok=0; }
awk "BEGIN{exit !($peak_tick < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M4-P2 GATE: PASS"; exit 0; else echo "M4-P2 GATE: FAIL"; exit 1; fi
```
Make it executable: `chmod +x ci/m4_destruction_test.sh`.

> `splash` and `smoke` are reported but not hard-gated (a match can be won with structure destruction + bullet attrition before lethal splash; smoke is purely a replication path until M7). `destroyed>=1` and `nades>=1` are the destruction gates.

- [ ] **Step 2: Laptop smoke via the new script (48 bots)**

```bash
GODOT=godot BOTS=48 MAX_WAIT=420 SERVER_CPUS=0-3 BOTS_CPUS=4-15 ci/m4_destruction_test.sh
```
Expected: `M4-P2 GATE: PASS`. If `destroyed`/`nades` are 0, tune per Task 12 Step 1.

- [ ] **Step 3: Extend `docker/run-m4-gate.sh` for the P2 assertions**

Read `docker/run-m4-gate.sh` (it greps the compose `server`/`bots` logs for `struct/bld/blk` + `structures synced`). Add P2 assertions in the same style: parse `destroyed=`/`nades=` from the server log and assert each `>= 1`, plus the existing tick/winner/synced checks; report `splash=`/`smoke=`. Keep the M3 + P1 assertions intact. (If a separate `run-m4p2-gate.sh` is cleaner, create that instead — match the existing file's conventions either way.)

- [ ] **Step 4: Fleet gate (unraid W-2275 "SENET")**

Per AGENTS.md §8, stay confined to `/mnt/app/blockfire` on that host. Sync the branch tree and run the fleet gate:
```bash
# from the dev box: rsync the working tree to the fleet (see docker/README.md for the exact path)
rsync -a --delete ./ root@192.168.1.10:/mnt/app/blockfire/
# on the fleet:
ssh root@192.168.1.10 'cd /mnt/app/blockfire/docker && SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 ./run-m4-gate.sh'
```
Expected: PASS with `winner` valid, peak `tick_mean < 33.3`, `destroyed >= 1`, `nades >= 1`, structures synced. **Watch the peak tick** — Phase 1 was 30.89 ms; record how much destruction adds. If it breaches, apply graceful degradation: lower `MAX_STRUCTURE_DELTAS_PER_TICK`, `MAX_BOT_GRENADES`, or `BLAST_STRUCT_RADIUS`, and re-profile the `fire`/`respawn`/`snap` `[perf]` lines.

- [ ] **Step 5: Record evidence in the milestone doc**

Edit `docs/milestones/M4-building-destruction.md`: add a **Phase 2 (Destruction) — gate evidence** section mirroring the Phase-1 one (laptop-48 + fleet-128 blocks), pasting the real `winner/elapsed/peak tick/destroyed/nades/splash/smoke` lines and the `structures synced` line. State the Phase-2 verdict and that the M4 gate is fully closed.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "M4-P2: destruction gate script + fleet assertions + milestone evidence

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 14: Final verification + finish the branch

**Files:**
- Modify: `docs/TASKS.md`, `docs/HANDOVER.md`, `docs/milestones/M4-building-destruction.md` (status flips)

- [ ] **Step 1: Full unit suite green**

Run: `godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . -- --test`
Expected: PASS, zero failures, assertion count up from Phase 1 (new structure/grenade/protocol/bot-mirror tests). Record the count.

- [ ] **Step 2: Gate evidence present**

Confirm Task 13 recorded real laptop-48 + fleet-128 numbers in the milestone doc and both gates printed PASS. Do not claim the gate passed without the captured output (`verification-before-completion`).

- [ ] **Step 3: Flip statuses**

- `docs/TASKS.md` M4 row → `done ✅` with the Phase-2 gate one-liner (winner/elapsed/peak tick/destroyed/nades).
- `docs/milestones/M4-building-destruction.md` status header → both phases gate PASS; M4 closed.
- `docs/HANDOVER.md` M4 bullet + **Next** section → M4 done; next milestone is **M4.5 Combat Depth** (`docs/milestones/M4.5-combat-depth.md`; start with `brainstorming` → `docs/specs/combat-depth.md`). Note that frag + smoke grenades and the `Grenade` ballistic model already exist (M4.5 RPG reuses them; M4.5 Assault class wires frag/smoke into the gadget slots).

- [ ] **Step 4: Commit the doc flips**

```bash
git add -A
git commit -m "docs(M4): Phase 2 (Destruction) gate PASS — M4 closed; next is M4.5

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Finish the branch**

Invoke the `superpowers:finishing-a-development-branch` skill to merge `m4-destruction` → `master` and push (`git push origin master`), per the working agreement.

---

## Self-review notes (for the executor)

- **Spec coverage:** bullet damage (T6) · throttled buckets (T1 `bucket_of` + T7 emit) · frag explosives structures+pawns (T2, T3, T8) · present-time/no-rewind (T8 `_detonate`) · FF-off incl. self (T8 skip owner+team) · **smoke grenades** zone + `SMOKE_DEPLOYED` + expiry (T4 protocol, T9 server, T11 bot throw) · graceful degradation send-cap + carry (T6 queue + T7 budget) · protocol OP_DAMAGE/GRENADE_THROW(type)/SMOKE_DEPLOYED (T4) · bot mirror OP_DAMAGE fix (T5) · bot frag+smoke AI (T11) · telemetry incl. smoke (T10) · gate (T13). Spec §A–§I + §B.5 each map to a task.
- **Smoke vs gate:** the destruction gate is **frag-driven** (`destroyed>=1`, `nades>=1`); smoke is implemented + unit-tested (T4) + exercised by bots (T11) + reported in telemetry (T10) but not hard-gated, because it has no gameplay effect until M7 LOS culling. This matches spec §B.5 ("client VFX deferred to M7", "server zone data already present").
- **Shared throw cooldown:** server `last_grenade_tick` (T8) gates both frag + smoke per spec §B.5; bots mirror it with `GRENADE_COOLDOWN_TICKS` and separate per-bot caps (`MAX_BOT_GRENADES`, `MAX_BOT_SMOKES`) so the gate-critical frag path always fires.
- **Type consistency:** `apply_damage` → `{hit,destroyed,health,bucket}` (T1) consumed in T6/T8; `ids_in_radius` → `Array[int]` (T2) consumed in T8; `bucket_of` `static` on `StructureStore` (T1) called in T7; `encode/decode_structure_delta` OP_DAMAGE carries `{id,bucket}` (T4) produced T7 consumed T5; `encode_grenade_throw(dir, type)` (T4) called in T11; `Grenade.FRAG/SMOKE` (T3) used in T4/T8/T9/T11; `SMOKE_DEPLOYED` (T4) sent T9 drained T11; `_grenades`/`_smoke_zones`/`_damage_structure`/`_emit_structure_deltas`/`_pending_removes`/`_dmg_touched`/`_last_bucket`/`_detonate`/`_deploy_smoke`/`_expire_smoke_zones` names consistent across T6–T11.
- **Constants:** `DAMAGE_BUCKETS` in `StructureStore`; blast/fuse/cooldown/cap + `SMOKE_*` in `server_main.gd`; bot mirrors `GRENADE_COOLDOWN_TICKS` + `MAX_BOT_GRENADES`/`MAX_BOT_SMOKES`.
- **Naming drift vs spec:** spec sketch says `cells_in_radius`→cells; plan uses `ids_in_radius`→ids (caller-friendly; same intent). `apply_damage` omits the spec's `crossed` field — bucket-crossing is decided at emit time against `_last_bucket` (T7), which correctly coalesces multi-source damage and respects the send cap.
```
