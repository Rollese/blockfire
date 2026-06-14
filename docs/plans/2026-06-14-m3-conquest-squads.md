# M3 Conquest + Deploy/Respawn + Squads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete, winnable match loop on the M2 FPS core — a data-driven Conquest mode (capture points, ticket bleed, win condition), squads, server-authoritative deploy/respawn with point/squad spawns, and bots that path to objectives and capture them — at 128 bots within the 30 Hz budget.

**Architecture:** Server-authoritative. All match rules live in `shared/` (`MapDef`, `ConquestState`) so client and server can't diverge. The server steps the conquest state each tick from pawn positions (presence → neutralize-then-capture → ticket bleed → win), assigns squads within teams, and auto-selects spawns from valid sources (home base / owned points / squadmates). Bots read a periodic `MATCH_STATE` broadcast plus the shared map to pick the nearest non-owned point and march on it. The per-tick interest grid is reused to spatially pre-filter shot candidates (perf).

**Tech Stack:** Godot 4.6, GDScript, low-level ENet (from M1), `StreamPeerBuffer` wire encoding, JSON map data, custom headless test runner (`tests/`).

**Spec:** [`docs/specs/m3-conquest-squads.md`](../specs/m3-conquest-squads.md)

---

## File structure

| File | Responsibility | Status |
|---|---|---|
| `shared/sim/map_def.gd` | `MapDef`: parse + validate Conquest map JSON (points/bases) | new |
| `maps/conquest_proving_grounds.json` | v1 map: 5 neutral points + 2 home bases | new |
| `shared/sim/conquest.gd` | `ConquestState`: capture state machine + tickets + win + nearest-capturable | new |
| `shared/sim/entity_state.gd` | + `squad` field | modify |
| `shared/sim/pawn.gd` | + `squad` field; `to_state()` copies it | modify |
| `shared/net/snapshot.gd` | + `F_SQUAD` field bit | modify |
| `shared/net/protocol.gd` | + `Msg.MATCH_STATE` encode/decode | modify |
| `server/squads.gd` | `SquadManager`: within-team squad assignment + leader | new |
| `server/spawn_select.gd` | `SpawnSelect`: nearest valid source + jitter | new |
| `server/server_main.gd` | load map; squads; conquest step; spawn select; match-state broadcast; perf pre-filter; match end | modify |
| `bots/bot_driver.gd` | load map; cache match state; objective pathing | modify |
| `ci/m3_conquest_test.sh` | gate: 128 bots run start→win; winner + captures + tick budget | new |

Tests mirror each shared/server module under `tests/`.

**Conventions reused from M1/M2:** tests extend global `TestCase` (`assert_true/assert_eq/assert_almost_eq`; a test passes only if it ran ≥1 assertion and 0 failures); run `godot --headless --path . -- --test --filter=<substr>`; after adding any `class_name` script run `godot --headless --path . --import` once before tests; **never pipe `godot` through `tail`/`head`** (redirect to a file); GDScript 4.6 rejects `var x := <Dictionary access>` (Variant) — annotate the type explicitly; commit author `-c user.name="Claude" -c user.email="noreply@anthropic.com"` with trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; `git add -A` to include `.uid` sidecars. Work is on branch `m3-conquest-squads` (already created).

---

## Task 1: MapDef — JSON map parse + validation

**Files:** Create `shared/sim/map_def.gd`, `maps/conquest_proving_grounds.json`, `tests/map_def_test.gd`

- [ ] **Step 1: Write `tests/map_def_test.gd`**

```gdscript
extends TestCase

const VALID := '{"name":"t","world_half":1000,"points":[{"id":"A","pos":[1,0,2],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func test_loads_valid_map() -> void:
	var r := MapDef.from_json_string(VALID)
	assert_true(r["ok"], r["error"])
	var m: MapDef = r["map"]
	assert_eq(m.points.size(), 1)
	assert_eq(m.points[0]["pos"], Vector3(1, 0, 2))
	assert_almost_eq(m.points[0]["radius"], 30.0)
	assert_eq(m.base_for(1)["pos"], Vector3(900, 0, 0))

func test_rejects_empty_points() -> void:
	assert_eq(MapDef.from_json_string('{"points":[],"bases":[]}')["ok"], false)

func test_rejects_bad_radius() -> void:
	assert_eq(MapDef.from_json_string('{"points":[{"pos":[0,0,0],"radius":0}],"bases":[]}')["ok"], false)

func test_rejects_missing_team_base() -> void:
	var r := MapDef.from_json_string('{"points":[{"pos":[0,0,0],"radius":10}],"bases":[{"team":0,"pos":[0,0,0],"radius":10}]}')
	assert_eq(r["ok"], false)

func test_start_owner_defaults_neutral() -> void:
	var r := MapDef.from_json_string('{"points":[{"pos":[0,0,0],"radius":10}],"bases":[{"team":0,"pos":[0,0,0],"radius":1},{"team":1,"pos":[1,0,0],"radius":1}]}')
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].points[0]["start_owner"], -1)
```

- [ ] **Step 2: Run to verify it fails** — `godot --headless --path . -- --test --filter=map_def` → FAIL (`MapDef` not found).

- [ ] **Step 3: Write `shared/sim/map_def.gd`**

```gdscript
class_name MapDef
extends RefCounted
## Data-driven Conquest map: capture points + per-team home bases. Parsed from JSON in
## maps/ and validated; the server refuses to start on an invalid map. The single source
## of truth for point/base geometry shared by server and bots. See docs/specs/m3-conquest-squads.md.

var name: String = ""
var world_half: float = 1000.0
var points: Array = []   # [{id:String, pos:Vector3, radius:float, start_owner:int}]
var bases: Array = []    # [{team:int, pos:Vector3, radius:float}]

func base_for(team: int) -> Dictionary:
	for b in bases:
		if b["team"] == team:
			return b
	return {}

static func _vec3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

## Returns {"ok": bool, "map": MapDef, "error": String}.
static func from_json_string(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "map": null, "error": "root is not an object"}
	return from_dict(data)

static func from_dict(data: Dictionary) -> Dictionary:
	var m := MapDef.new()
	m.name = String(data.get("name", ""))
	m.world_half = float(data.get("world_half", 1000.0))
	var raw_points = data.get("points", [])
	if typeof(raw_points) != TYPE_ARRAY or raw_points.is_empty():
		return {"ok": false, "map": null, "error": "points must be a non-empty array"}
	for pt in raw_points:
		if not (pt is Dictionary) or not pt.has("pos") or not (pt["pos"] is Array) or pt["pos"].size() != 3:
			return {"ok": false, "map": null, "error": "each point needs a 3-number pos"}
		var radius := float(pt.get("radius", 0.0))
		if radius <= 0.0:
			return {"ok": false, "map": null, "error": "point radius must be > 0"}
		var so := int(pt.get("start_owner", -1))
		if so < -1 or so > 1:
			return {"ok": false, "map": null, "error": "start_owner must be -1, 0 or 1"}
		m.points.append({"id": String(pt.get("id", "")), "pos": _vec3(pt["pos"]), "radius": radius, "start_owner": so})
	var raw_bases = data.get("bases", [])
	if typeof(raw_bases) != TYPE_ARRAY:
		return {"ok": false, "map": null, "error": "bases must be an array"}
	for b in raw_bases:
		if not (b is Dictionary) or not b.has("pos") or not (b["pos"] is Array) or b["pos"].size() != 3:
			return {"ok": false, "map": null, "error": "each base needs a 3-number pos"}
		m.bases.append({"team": int(b.get("team", 0)), "pos": _vec3(b["pos"]), "radius": float(b.get("radius", 1.0))})
	if m.base_for(0).is_empty() or m.base_for(1).is_empty():
		return {"ok": false, "map": null, "error": "need one base per team {0,1}"}
	return {"ok": true, "map": m, "error": ""}

static func load_file(path: String) -> MapDef:
	if not FileAccess.file_exists(path):
		push_error("[map] not found: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var res := from_json_string(text)
	if not res["ok"]:
		push_error("[map] invalid %s: %s" % [path, res["error"]])
		return null
	return res["map"]
```

- [ ] **Step 4: Write `maps/conquest_proving_grounds.json`**

```json
{
  "name": "proving_grounds",
  "world_half": 1000.0,
  "points": [
    {"id": "A", "pos": [-600, 0, -400], "radius": 30.0, "start_owner": -1},
    {"id": "B", "pos": [-300, 0,  300], "radius": 30.0, "start_owner": -1},
    {"id": "C", "pos": [   0, 0,    0], "radius": 30.0, "start_owner": -1},
    {"id": "D", "pos": [ 300, 0, -300], "radius": 30.0, "start_owner": -1},
    {"id": "E", "pos": [ 600, 0,  400], "radius": 30.0, "start_owner": -1}
  ],
  "bases": [
    {"team": 0, "pos": [-900, 0, 0], "radius": 40.0},
    {"team": 1, "pos": [ 900, 0, 0], "radius": 40.0}
  ]
}
```

- [ ] **Step 5: Import + run** — `godot --headless --path . --import >/tmp/import.log 2>&1` then `--filter=map_def` → 5 PASS. Full suite `godot --headless --path . -- --test` → 0 failed.

- [ ] **Step 6: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: MapDef JSON parse/validate + proving_grounds map"
```

---

## Task 2: ConquestState — capture machine, tickets, win

**Files:** Create `shared/sim/conquest.gd`, `tests/conquest_test.gd`

- [ ] **Step 1: Write `tests/conquest_test.gd`**

```gdscript
extends TestCase

func _map_one_point(radius := 30.0, start_owner := -1) -> MapDef:
	var json := '{"points":[{"id":"A","pos":[0,0,0],"radius":%f,"start_owner":%d}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}' % [radius, start_owner]
	return MapDef.from_json_string(json)["map"]

func _world_with(team_positions: Array) -> World:
	# team_positions: Array of [team:int, pos:Vector3]
	var w := World.new()
	var id := 1
	for tp in team_positions:
		var p := w.spawn(id)
		p.team = tp[0]; p.pos = tp[1]; p.alive = true
		id += 1
	return w

func test_neutral_point_captured_in_one_phase() -> void:
	var c := ConquestState.new(_map_one_point())
	var w := _world_with([[0, Vector3.ZERO]])
	for i in 110: c.step(0.1, w)   # ~11s, base rate 0.10 -> captured by 10s
	assert_eq(c.points[0]["owner"], 0, "team 0 captured the neutral point")

func test_enemy_point_needs_neutralize_then_capture() -> void:
	var c := ConquestState.new(_map_one_point(30.0, 1))  # starts owned by team 1
	var w := _world_with([[0, Vector3.ZERO]])
	for i in 110: c.step(0.1, w)
	assert_eq(c.points[0]["owner"], -1, "neutralized first (not yet team 0)")
	for i in 110: c.step(0.1, w)
	assert_eq(c.points[0]["owner"], 0, "then captured")

func test_contested_freezes_progress() -> void:
	var c := ConquestState.new(_map_one_point())
	var w := _world_with([[0, Vector3.ZERO], [1, Vector3.ZERO]])
	for i in 200: c.step(0.1, w)
	assert_eq(c.points[0]["owner"], -1, "contested stays neutral")
	assert_almost_eq(c.points[0]["cap"], 0.0, 0.001)

func test_more_attackers_capture_faster() -> void:
	var c1 := ConquestState.new(_map_one_point())
	var c8 := ConquestState.new(_map_one_point())
	var many := []
	for i in 8: many.append([0, Vector3.ZERO])
	for i in 20:
		c1.step(0.1, _world_with([[0, Vector3.ZERO]]))
		c8.step(0.1, _world_with(many))
	assert_true(c8.points[0]["cap"] > c1.points[0]["cap"], "8 attackers progress faster")

func test_empty_point_decays() -> void:
	var c := ConquestState.new(_map_one_point())
	for i in 30: c.step(0.1, _world_with([[0, Vector3.ZERO]]))
	var mid: float = c.points[0]["cap"]
	assert_true(mid > 0.0)
	for i in 50: c.step(0.1, World.new())
	assert_true(c.points[0]["cap"] < mid, "decays when empty")

func test_bleed_by_flag_deficit() -> void:
	var c := ConquestState.new(_map_one_point(30.0, 0))  # team 0 owns the only point
	var t1_before: float = c.tickets[1]
	for i in 10: c.step(1.0, World.new())  # 10s, team 1 deficit = 1
	assert_true(c.tickets[1] < t1_before, "losing team bleeds")
	assert_almost_eq(c.tickets[0], float(ConquestState.TICKETS_START), 0.001, "winning team doesn't bleed")

func test_death_costs_ticket() -> void:
	var c := ConquestState.new(_map_one_point())
	c.register_death(1)
	assert_eq(c.tickets_int(1), ConquestState.TICKETS_START - 1)

func test_win_at_zero_tickets() -> void:
	var c := ConquestState.new(_map_one_point())
	c.tickets[1] = 0.5
	c.register_death(1)            # -> <= 0
	c.step(0.001, World.new())
	assert_true(c.match_over)
	assert_eq(c.winner, 0, "team 0 wins when team 1 hits 0")

func test_nearest_capturable_skips_owned() -> void:
	var json := '{"points":[{"pos":[0,0,0],"radius":10,"start_owner":0},{"pos":[100,0,0],"radius":10,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":1},{"team":1,"pos":[900,0,0],"radius":1}]}'
	var c := ConquestState.new(MapDef.from_json_string(json)["map"])
	assert_eq(c.nearest_capturable_index(0, Vector3(5, 0, 0)), 1, "skips the point team 0 already owns")
```

- [ ] **Step 2: Run to verify it fails** — `--filter=conquest` → FAIL (`ConquestState` not found).

- [ ] **Step 3: Write `shared/sim/conquest.gd`**

```gdscript
class_name ConquestState
extends RefCounted
## Authoritative Conquest mode: per-point capture (neutralize-then-take, pause on contest),
## ticket pool with flag-deficit bleed + per-death cost, and win condition. Steps each
## server tick from world pawn positions. All rules live here (shared) so server authority
## is single-source. See docs/specs/m3-conquest-squads.md.

const TICKETS_START := 250
const BLEED_PER_FLAG := 1.0
const DEATH_TICKET_COST := 1
const CAP_RATE_BASE := 0.10        # per-second cap gain, single attacker (~10s/phase)
const CAP_BONUS_PER := 0.20        # extra rate fraction per additional attacker
const CAP_MAX_ATTACKERS := 8
const CAP_DECAY_RATE := 0.05       # per-second cap decay when a point is empty
const MATCH_TIME_LIMIT := 1200.0   # fail-safe; on expiry, more tickets wins

var points: Array = []             # [{id, pos:Vector3, radius, owner:int, attacker:int, cap:float}]
var tickets: Array[float] = []
var time_limit: float = MATCH_TIME_LIMIT
var match_over: bool = false
var winner: int = -1
var elapsed: float = 0.0

func _init(map: MapDef = null) -> void:
	tickets = [float(TICKETS_START), float(TICKETS_START)]
	if map == null:
		return
	for pt in map.points:
		points.append({
			"id": pt["id"], "pos": pt["pos"], "radius": pt["radius"],
			"owner": int(pt["start_owner"]), "attacker": -1, "cap": 0.0,
		})

func owned_count(team: int) -> int:
	var n := 0
	for pt in points:
		if pt["owner"] == team:
			n += 1
	return n

func tickets_int(team: int) -> int:
	return int(ceil(tickets[team]))

func register_death(team: int) -> void:
	tickets[team] -= float(DEATH_TICKET_COST)

func nearest_capturable_index(team: int, from: Vector3) -> int:
	var best := -1
	var best_d := INF
	for i in points.size():
		if points[i]["owner"] == team:
			continue
		var d: float = from.distance_to(points[i]["pos"])
		if d < best_d:
			best_d = d; best = i
	return best

func step(dt: float, world: World) -> void:
	if match_over:
		return
	for pt in points:
		var n0 := 0
		var n1 := 0
		for id in world.pawns:
			var p: Pawn = world.pawns[id]
			if not p.alive:
				continue
			var dx: float = p.pos.x - pt["pos"].x
			var dz: float = p.pos.z - pt["pos"].z
			if dx * dx + dz * dz <= pt["radius"] * pt["radius"]:
				if p.team == 0: n0 += 1
				else: n1 += 1
		_resolve_point(pt, n0, n1, dt)
	for team in [0, 1]:
		var deficit := maxi(0, owned_count(1 - team) - owned_count(team))
		if deficit > 0:
			tickets[team] -= BLEED_PER_FLAG * float(deficit) * dt
	elapsed += dt
	if tickets[0] <= 0.0 and tickets[1] <= 0.0:
		_finish(0 if tickets[0] >= tickets[1] else 1)
	elif tickets[0] <= 0.0:
		_finish(1)
	elif tickets[1] <= 0.0:
		_finish(0)
	elif elapsed >= time_limit:
		_finish(0 if tickets[0] >= tickets[1] else 1)

func _finish(win_team: int) -> void:
	tickets[0] = maxf(tickets[0], 0.0)
	tickets[1] = maxf(tickets[1], 0.0)
	match_over = true
	winner = win_team

func _cap_rate(n: int) -> float:
	var c := mini(n, CAP_MAX_ATTACKERS)
	return CAP_RATE_BASE * (1.0 + CAP_BONUS_PER * float(c - 1))

func _resolve_point(pt: Dictionary, n0: int, n1: int, dt: float) -> void:
	var owner: int = pt["owner"]
	if n0 > 0 and n1 > 0:
		return  # contested: freeze
	if n0 == 0 and n1 == 0:
		if pt["attacker"] != -1:
			pt["cap"] = maxf(0.0, pt["cap"] - CAP_DECAY_RATE * dt)
			if pt["cap"] <= 0.0:
				pt["attacker"] = -1
		return
	var t := 0 if n0 > 0 else 1
	var n := n0 if t == 0 else n1
	if owner == t:
		pt["cap"] = 0.0
		pt["attacker"] = -1
		return
	if pt["attacker"] != t:
		pt["attacker"] = t
		pt["cap"] = 0.0
	pt["cap"] += _cap_rate(n) * dt
	if pt["cap"] >= 1.0:
		if owner != -1:
			pt["owner"] = -1      # neutralize done; same team keeps capturing next ticks
			pt["cap"] = 0.0
		else:
			pt["owner"] = t       # capture done
			pt["attacker"] = -1
			pt["cap"] = 0.0
```

- [ ] **Step 4: Run** — `--filter=conquest` → 10 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: ConquestState (capture machine, tickets, bleed, win)"
```

---

## Task 3: EntityState — replicate squad

**Files:** Modify `shared/sim/entity_state.gd`, `tests/entity_state_test.gd`

- [ ] **Step 1: Append to `tests/entity_state_test.gd`** (keep existing tests):

```gdscript
func test_clone_copies_squad() -> void:
	var a := EntityState.new()
	a.squad = 6
	var b := a.clone()
	assert_eq(b.squad, 6)
	b.squad = 1
	assert_eq(a.squad, 6, "clone independent")
```

- [ ] **Step 2: Run to verify it fails** — `--filter=entity_state` → FAIL (no `squad`).

- [ ] **Step 3: Modify `shared/sim/entity_state.gd`** — add the field and clone line. Add after the `health` var:

```gdscript
var squad: int = 0
```

and in `clone()` before `return e` add:

```gdscript
	e.squad = squad
```

- [ ] **Step 4: Run** — `--filter=entity_state` → PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: EntityState gains squad"
```

---

## Task 4: Pawn — squad field

**Files:** Modify `shared/sim/pawn.gd`, `tests/pawn_test.gd`

- [ ] **Step 1: Append to `tests/pawn_test.gd`**:

```gdscript
func test_to_state_copies_team_and_squad() -> void:
	var p := Pawn.new(1)
	p.team = 1; p.squad = 3
	var e := p.to_state()
	assert_eq(e.team, 1)
	assert_eq(e.squad, 3)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=pawn` → FAIL (no `squad`).

- [ ] **Step 3: Modify `shared/sim/pawn.gd`** — add the field after `var team: int = 0`:

```gdscript
var squad: int = 0
```

and in `to_state()` before `return e` add:

```gdscript
	e.squad = squad
```

- [ ] **Step 4: Run** — `--filter=pawn` → all PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: Pawn gains squad; to_state copies it"
```

---

## Task 5: Snapshot — F_SQUAD field

**Files:** Modify `shared/net/snapshot.gd`, `tests/snapshot_test.gd`

- [ ] **Step 1: Append to `tests/snapshot_test.gd`**:

```gdscript
func test_replicates_squad() -> void:
	var e := EntityState.new()
	e.pos = Vector3(1, 0, 2); e.squad = 5
	var bytes := Snapshot.encode(1, 1, 0, 0, {9: e}, {})
	var view := {}
	Snapshot.decode_apply(bytes, view)
	assert_eq(view[9].squad, 5)

func test_squad_change_is_a_delta() -> void:
	var base := EntityState.new(); base.squad = 1
	var cur := EntityState.new(); cur.squad = 4   # only squad changed
	var bytes := Snapshot.encode(2, 2, 1, 0, {5: cur}, {5: base})
	var view := {5: EntityState.new()}; view[5].squad = 1
	Snapshot.decode_apply(bytes, view)
	assert_eq(view[5].squad, 4)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=snapshot` → FAIL (squad not encoded).

- [ ] **Step 3: Modify `shared/net/snapshot.gd`** — four edits:

(a) After `const F_HEALTH := 64` add and update `F_ALL`:
```gdscript
const F_SQUAD := 128
const F_ALL := 255
```

(b) In `_diff_mask`, before `return m`, add:
```gdscript
	if a.squad != b.squad: m |= F_SQUAD
```

(c) In `_put_fields`, after the `F_HEALTH` line, add:
```gdscript
	if mask & F_SQUAD: buf.put_u8(e.squad & 0xFF)
```

(d) In `decode_apply`, after the `if mask & F_HEALTH: e.health = buf.get_u8()` line, add:
```gdscript
			if mask & F_SQUAD: e.squad = buf.get_u8()
```

- [ ] **Step 4: Run** — `--filter=snapshot` → all PASS (M1/M2 + 2 new). Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: Snapshot replicates squad (F_SQUAD)"
```

---

## Task 6: MATCH_STATE protocol message

**Files:** Modify `shared/net/protocol.gd`, `tests/protocol_test.gd`

- [ ] **Step 1: Append to `tests/protocol_test.gd`**:

```gdscript
func test_match_state_round_trip() -> void:
	var points := [{"owner": -1, "attacker": 0, "cap": 0.5}, {"owner": 1, "attacker": -1, "cap": 1.0}]
	var bytes := Protocol.encode_match_state(points, [250, 7], false, -1, 42)
	assert_eq(Protocol.msg_type(bytes), Protocol.Msg.MATCH_STATE)
	var d := Protocol.decode_match_state(bytes)
	assert_eq(d["points"].size(), 2)
	assert_eq(d["points"][0]["owner"], -1)
	assert_eq(d["points"][0]["attacker"], 0)
	assert_almost_eq(d["points"][0]["cap"], 0.5, 0.01)
	assert_eq(d["points"][1]["owner"], 1)
	assert_eq(d["tickets"][0], 250)
	assert_eq(d["tickets"][1], 7)
	assert_eq(d["match_over"], false)
	assert_eq(d["winner"], -1)
	assert_eq(d["elapsed"], 42)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=protocol` → FAIL (no `encode_match_state`).

- [ ] **Step 3: Modify `shared/net/protocol.gd`** — add `MATCH_STATE = 7` to the `Msg` enum (after `KILL = 6,`):

```gdscript
	MATCH_STATE = 7, ## server -> clients: conquest state (point owners/cap, tickets, win)
```

and append these methods at the end of the file:

```gdscript
static func encode_match_state(points: Array, tickets: Array, match_over: bool, winner: int, elapsed: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.MATCH_STATE)
	buf.put_u8(points.size())
	for pt in points:
		buf.put_8(int(pt["owner"]))
		buf.put_8(int(pt["attacker"]))
		buf.put_u8(clampi(roundi(float(pt["cap"]) * 255.0), 0, 255))
	buf.put_u16(clampi(int(tickets[0]), 0, 65535))
	buf.put_u16(clampi(int(tickets[1]), 0, 65535))
	buf.put_u8(1 if match_over else 0)
	buf.put_8(winner)
	buf.put_u16(clampi(elapsed, 0, 65535))
	return buf.data_array


static func decode_match_state(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var pts := []
	for i in n:
		pts.append({"owner": r.get_8(), "attacker": r.get_8(), "cap": float(r.get_u8()) / 255.0})
	var t0 := r.get_u16()
	var t1 := r.get_u16()
	var over := r.get_u8() == 1
	var win := r.get_8()
	var el := r.get_u16()
	return {"points": pts, "tickets": [t0, t1], "match_over": over, "winner": win, "elapsed": el}
```

- [ ] **Step 4: Run** — `--filter=protocol` → all PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: MATCH_STATE protocol message"
```

---

## Task 7: SquadManager — within-team squad assignment

**Files:** Create `server/squads.gd`, `tests/squads_test.gd`

- [ ] **Step 1: Write `tests/squads_test.gd`**

```gdscript
extends TestCase

func test_fills_first_squad_then_overflows() -> void:
	var sm := SquadManager.new()
	for i in SquadManager.SQUAD_SIZE:
		assert_eq(sm.assign(i, 0), 0, "first %d go to squad 0" % SquadManager.SQUAD_SIZE)
	assert_eq(sm.assign(99, 0), 1, "next opens squad 1")

func test_leader_is_first_member_and_promotes() -> void:
	var sm := SquadManager.new()
	sm.assign(10, 0); sm.assign(11, 0)
	assert_eq(sm.leader_of(0, 0), 10)
	sm.remove(10, 0)
	assert_eq(sm.leader_of(0, 0), 11, "next member promoted")

func test_reuses_freed_slot() -> void:
	var sm := SquadManager.new()
	for i in SquadManager.SQUAD_SIZE: sm.assign(i, 0)
	sm.remove(3, 0)
	assert_eq(sm.assign(50, 0), 0, "freed slot in squad 0 reused")

func test_teams_independent() -> void:
	var sm := SquadManager.new()
	assert_eq(sm.assign(1, 0), 0)
	assert_eq(sm.assign(2, 1), 0, "team 1 squad ids independent")

func test_members_lists_squadmates() -> void:
	var sm := SquadManager.new()
	sm.assign(1, 0); sm.assign(2, 0)
	var mem := sm.members(0, 0)
	assert_eq(mem.size(), 2)
	assert_true(1 in mem and 2 in mem)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=squads` → FAIL (`SquadManager` not found).

- [ ] **Step 3: Write `server/squads.gd`**

```gdscript
class_name SquadManager
extends RefCounted
## Per-team squad membership. Squads of SQUAD_SIZE, never spanning teams. First member is
## the leader; on removal the next member is promoted implicitly (leader = index 0). A
## freed slot is reused before opening a new squad. See docs/specs/m3-conquest-squads.md.

const SQUAD_SIZE := 8

var _squads := {0: {}, 1: {}}   # team -> {squad_id:int -> Array[int] member ids (leader first)}
var squad_of := {}              # client_id -> squad_id

func assign(client_id: int, team: int) -> int:
	var squads: Dictionary = _squads[team]
	var sid := -1
	var ids := squads.keys()
	ids.sort()
	for k in ids:
		if squads[k].size() < SQUAD_SIZE:
			sid = k; break
	if sid == -1:
		sid = squads.size()
		squads[sid] = []
	squads[sid].append(client_id)
	squad_of[client_id] = sid
	return sid

func remove(client_id: int, team: int) -> void:
	var sid: int = squad_of.get(client_id, -1)
	if sid == -1: return
	var arr: Array = _squads[team].get(sid, [])
	arr.erase(client_id)
	squad_of.erase(client_id)

func leader_of(team: int, squad_id: int) -> int:
	var arr: Array = _squads[team].get(squad_id, [])
	return arr[0] if arr.size() > 0 else 0

func members(team: int, squad_id: int) -> Array:
	return _squads[team].get(squad_id, [])
```

- [ ] **Step 4: Run** — `--filter=squads` → 5 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: SquadManager (within-team assignment + leader)"
```

---

## Task 8: SpawnSelect — nearest valid source + jitter

**Files:** Create `server/spawn_select.gd`, `tests/spawn_select_test.gd`

- [ ] **Step 1: Write `tests/spawn_select_test.gd`**

```gdscript
extends TestCase

func _map() -> MapDef:
	var json := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'
	return MapDef.from_json_string(json)["map"]

func test_spawns_at_home_base_when_no_points_owned() -> void:
	var m := _map()
	var pos := SpawnSelect.select(0, m, ConquestState.new(m), [], Vector3(100, 0, 0))
	assert_true(pos.distance_to(Vector3(-900, 0, 0)) <= SpawnSelect.JITTER * 1.5, "near home base")

func test_prefers_owned_point_near_objective() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	c.points[0]["owner"] = 0   # team 0 owns A at (100,0,0)
	var pos := SpawnSelect.select(0, m, c, [], Vector3(100, 0, 0))
	assert_true(pos.distance_to(Vector3(100, 0, 0)) <= SpawnSelect.JITTER * 1.5, "spawns on owned point near objective")

func test_never_spawns_on_enemy_point() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	c.points[0]["owner"] = 1   # enemy owns A
	var pos := SpawnSelect.select(0, m, c, [], Vector3(100, 0, 0))
	assert_true(pos.distance_to(Vector3(-900, 0, 0)) <= SpawnSelect.JITTER * 1.5, "falls back to home, never enemy point")

func test_spawns_on_squadmate() -> void:
	var m := _map()
	var pos := SpawnSelect.select(0, m, ConquestState.new(m), [Vector3(50, 0, 50)], Vector3(50, 0, 50))
	assert_true(pos.distance_to(Vector3(50, 0, 50)) <= SpawnSelect.JITTER * 1.5, "spawns near squadmate")

func test_jitter_within_bounds_and_grounded() -> void:
	var m := _map()
	var pos := SpawnSelect.select(0, m, ConquestState.new(m), [], Vector3(-900, 0, 0))
	assert_almost_eq(pos.y, 0.0, 0.001, "spawns grounded")
	assert_true(absf(pos.x - (-900.0)) <= SpawnSelect.JITTER, "x jitter bounded")
```

- [ ] **Step 2: Run to verify it fails** — `--filter=spawn_select` → FAIL (`SpawnSelect` not found).

- [ ] **Step 3: Write `server/spawn_select.gd`**

```gdscript
class_name SpawnSelect
extends Object
## Picks a spawn position for a (re)deploying player: the valid source nearest the
## objective, plus jitter to avoid stacking. Valid sources = home base, owned capture
## points, alive squadmates — never a neutral or enemy point. Deterministic except for
## the jitter. See docs/specs/m3-conquest-squads.md.

const JITTER := 6.0

## squadmate_positions: Array[Vector3] of alive same-squad teammates (may be empty).
## objective: where the player wants to go (capture target / map point).
static func select(team: int, map: MapDef, conquest: ConquestState,
		squadmate_positions: Array, objective: Vector3) -> Vector3:
	var sources: Array[Vector3] = []
	var base := map.base_for(team)
	if not base.is_empty():
		sources.append(base["pos"])
	for pt in conquest.points:
		if pt["owner"] == team:
			sources.append(pt["pos"])
	for sp in squadmate_positions:
		sources.append(sp)
	var chosen := sources[0] if sources.size() > 0 else Vector3.ZERO
	var best := INF
	for s in sources:
		var d: float = s.distance_to(objective)
		if d < best:
			best = d; chosen = s
	return Vector3(chosen.x + randf_range(-JITTER, JITTER), 0.0, chosen.z + randf_range(-JITTER, JITTER))
```

- [ ] **Step 4: Run** — `--filter=spawn_select` → 5 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: SpawnSelect (nearest valid source + jitter)"
```

---

## Task 9: Server integration — conquest, squads, deploy, match state, perf pre-filter

**Files:** Modify `server/server_main.gd`

This is the integration core and the largest task — **dispatch a review subagent after implementation** (two-stage review per subagent-driven-development). It wires the new modules into the tick loop: load + validate the map, assign squads on join, select spawns from valid sources, step the conquest state, broadcast `MATCH_STATE`, charge a ticket per death, pre-filter shot candidates with the interest grid, and exit shortly after a win. No new unit test (covered by the modules' tests + the Task 11 gate); verify by reading the file and running the full suite + a short smoke run.

- [ ] **Step 1: Replace `server/server_main.gd`** with the full file below.

```gdscript
extends Node
## Dedicated authoritative server. 30 Hz. Movement + hit-scan combat with lag comp,
## teams (FF off), Conquest mode (capture points, tickets, win), squads, deploy/respawn.
## See docs/specs/m3-conquest-squads.md.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128
const INTEREST_RADIUS := 250.0
const CELL_SIZE := 64.0
const MAX_HISTORY := 32
const RESPAWN_DELAY_TICKS := 150   # 5s @30Hz
const FIRE_CONE_DOT := 0.985       # broad-phase: target within ~10deg of ray
const FIRE_RANGE_MARGIN := 20.0    # grid broad-phase slack for lag-comp movement
const MAP_PATH := "res://maps/conquest_proving_grounds.json"
const MATCH_STATE_INTERVAL := 15   # ticks between match-state broadcasts (2 Hz)
const MATCH_END_DRAIN_TICKS := 60  # keep running ~2s after a win, then exit

var _net: NetHost
var _port := 27015
var _start_tickets := -1
var _time_limit := -1.0
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _lag := LagComp.new()
var _tele := Telemetry.new()
var _map: MapDef
var _conquest: ConquestState
var _squads := SquadManager.new()
var _next_id := 1
var _tele_accum := 0.0
var _team_counts := {0: 0, 1: 0}
var _positions := {}               # id -> Vector3, rebuilt each tick before fires

var _kills := 0
var _shots := 0
var _hits := 0
var _rewind_clamped := 0
var _cap_events := 0
var _prev_owners: Array = []
var _match_over_broadcast := false
var _match_end_tick := -1

var _clients := {}
var _peer_to_id := {}

func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))
	_start_tickets = int(args.get("tickets", -1))
	_time_limit = float(args.get("time-limit", -1.0))

func _ready() -> void:
	_map = MapDef.load_file(MAP_PATH)
	if _map == null:
		push_error("[server] failed to load map %s" % MAP_PATH); get_tree().quit(1); return
	_conquest = ConquestState.new(_map)
	if _start_tickets > 0:
		_conquest.tickets = [float(_start_tickets), float(_start_tickets)]
	if _time_limit > 0.0:
		_conquest.time_limit = _time_limit
	_prev_owners = _owner_snapshot()
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)]); get_tree().quit(1); return
	print("[server] listening on %d, tick=%dHz, max=%d map=%s" % [_port, TICK_RATE, MAX_PLAYERS, _map.name])

func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	_step_movement()
	_lag.record(_sim.tick, _sim.world)
	_build_interest()
	_resolve_fires()
	_handle_respawns()
	_conquest.step(SimLoop.DT, _sim.world)
	_track_and_broadcast_match_state()
	_send_snapshots()
	_tele.record_tick_ms(float(Time.get_ticks_usec() - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry(); _tele_accum = 0.0
	if _match_over_broadcast and _sim.tick >= _match_end_tick + MATCH_END_DRAIN_TICKS:
		print("[server] match complete, exiting"); get_tree().quit(0)

func _build_interest() -> void:
	_positions.clear()
	_grid.clear()
	for id in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[id]
		_positions[id] = p.pos
		_grid.insert(id, p.pos)

func _step_movement() -> void:
	var inputs := {}
	for id in _clients:
		var c = _clients[id]
		var inp = c["queued_input"]
		if inp == null:
			inp = c["last_input"]
			if inp != null: _tele.starvation += 1
		if inp != null:
			inputs[id] = inp
			c["last_input"] = inp
			c["last_input_tick"] = inp["client_tick"]
		c["queued_input"] = null
		if c["reloading"] and _sim.tick >= c["reload_done_tick"]:
			c["reloading"] = false
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
	_sim.step(inputs)

func _resolve_fires() -> void:
	for id in _clients:
		var c = _clients[id]
		var inp = c["last_input"]
		if inp == null: continue
		var shooter: Pawn = _sim.world.get_pawn(id)
		if shooter == null or not shooter.alive: continue
		var firing: bool = (inp["buttons"] & InputCommand.BTN_FIRE) != 0
		if not firing:
			c["shot_index"] = 0
			c["trigger_down"] = false
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and c["ammo"] < Weapon.get_def(c["weapon"])["mag_size"]:
				c["reloading"] = true
				c["reload_done_tick"] = _sim.tick + int(round(Weapon.get_def(c["weapon"])["reload_secs"] * TICK_RATE))
			continue
		var now := float(_sim.tick) * SimLoop.DT
		var ready: bool = now - c["last_fire_time"] >= Weapon.fire_interval(c["weapon"])
		var sprinting: bool = (inp["buttons"] & InputCommand.BTN_SPRINT) and shooter.stance == Stance.STAND
		if c["reloading"] or c["ammo"] <= 0 or not ready or sprinting:
			continue
		c["last_fire_time"] = now
		c["ammo"] -= 1
		var shot_index: int = c["shot_index"]
		c["shot_index"] = shot_index + 1
		c["trigger_down"] = true
		_shots += 1
		_fire_shot(id, shooter, inp, shot_index)

func _fire_shot(shooter_id: int, shooter: Pawn, inp: Dictionary, shot_index: int) -> void:
	var lean_sign := 0
	if shooter.lean == Stance.LEAN_LEFT: lean_sign = -1
	elif shooter.lean == Stance.LEAN_RIGHT: lean_sign = 1
	var moving: bool = absf(inp["move_x"]) + absf(inp["move_y"]) > 0.01
	var wid: int = _clients[shooter_id]["weapon"]
	var ray := Combat.reconstruct_ray(wid, shooter.eye_position(),
		inp["yaw"], inp["pitch"], lean_sign, shooter_id, _sim.tick, shot_index, moving)

	var view_tick: int = inp["view_server_tick"]
	if view_tick < _sim.tick - LagComp.MAX_REWIND or view_tick > _sim.tick:
		_rewind_clamped += 1
	var frame := _lag.rewind(view_tick)

	var max_range: float = Weapon.get_def(wid)["range_m"]
	# Broad-phase: only candidates near the shooter (current positions + lag-comp margin),
	# instead of scanning the whole rewound frame. Objective clustering raises density, so
	# this keeps per-shot cost bounded. Precise test still uses the rewound state.
	var candidates: Array = _grid.query(shooter.pos, max_range + FIRE_RANGE_MARGIN, _positions)
	var best_t := max_range + 1.0
	var best_victim := 0
	var best_head := false
	for tid in candidates:
		if tid == shooter_id: continue
		if not frame.has(tid): continue
		var st = frame[tid]
		if not st["alive"] or st["team"] == shooter.team: continue
		var to_target: Vector3 = st["pos"] - ray["origin"]
		if to_target.length() > max_range: continue
		if to_target.normalized().dot(ray["dir"]) < FIRE_CONE_DOT: continue
		var hit := Hitbox.raycast_pawn(ray["origin"], ray["dir"], st["pos"], st["stance"], max_range)
		if hit["hit"] and hit["t"] < best_t:
			best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]
	if best_victim == 0:
		return
	_hits += 1
	var dmg := Combat.damage_for(wid, best_head, best_t)
	var victim: Pawn = _sim.world.get_pawn(best_victim)
	if victim == null or not victim.alive: return
	victim.health -= dmg
	if victim.health <= 0:
		victim.health = 0
		victim.alive = false
		_clients[best_victim]["respawn_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
		_conquest.register_death(victim.team)
		_kills += 1
		var ev := Protocol.encode_kill(best_victim, shooter_id, wid, best_head)
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, ev, ENetPacketPeer.FLAG_RELIABLE)

func _handle_respawns() -> void:
	for id in _clients:
		var c = _clients[id]
		var p: Pawn = _sim.world.get_pawn(id)
		if p == null or p.alive: continue
		if c["respawn_tick"] > 0 and _sim.tick >= c["respawn_tick"]:
			p.pos = _select_spawn(id)
			p.velocity = Vector3.ZERO
			p.health = 100
			p.alive = true
			p.stamina = Pawn.STAMINA_MAX
			c["respawn_tick"] = 0
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
			c["reloading"] = false

func _select_spawn(id: int) -> Vector3:
	var c = _clients[id]
	var team: int = c["team"]
	var obj := _objective_for(team)
	var mates: Array = []
	for mid in _squads.members(team, c["squad"]):
		if mid == id: continue
		var mp: Pawn = _sim.world.get_pawn(mid)
		if mp != null and mp.alive: mates.append(mp.pos)
	return SpawnSelect.select(team, _map, _conquest, mates, obj)

func _objective_for(team: int) -> Vector3:
	var base := _map.base_for(team)
	var from: Vector3 = base["pos"] if not base.is_empty() else Vector3.ZERO
	var idx := _conquest.nearest_capturable_index(team, from)
	return _conquest.points[idx]["pos"] if idx >= 0 else from

func _owner_snapshot() -> Array:
	var a: Array = []
	for pt in _conquest.points: a.append(pt["owner"])
	return a

func _track_and_broadcast_match_state() -> void:
	var owners := _owner_snapshot()
	for i in owners.size():
		if i < _prev_owners.size() and owners[i] != _prev_owners[i]:
			_cap_events += 1
	_prev_owners = owners
	if _conquest.match_over and not _match_over_broadcast:
		_match_over_broadcast = true
		_match_end_tick = _sim.tick
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], true, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)
		print("[match] OVER winner=%d t0=%d t1=%d elapsed=%ds cap_events=%d"
			% [_conquest.winner, _conquest.tickets_int(0), _conquest.tickets_int(1), int(_conquest.elapsed), _cap_events])
	elif not _match_over_broadcast and _sim.tick % MATCH_STATE_INTERVAL == 0:
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], false, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)

func _send_snapshots() -> void:
	var state := _sim.world.state_map()
	for id in _clients:
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null: continue
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, _positions)
		var current := {}
		for vid in ids: current[vid] = state[vid]
		var baseline_seq: int = c["last_acked_seq"]
		var baseline = c["history"].get(baseline_seq)
		if baseline == null:
			baseline = {}; baseline_seq = 0
		var seq: int = c["next_seq"]
		var bytes := Snapshot.encode(_sim.tick, seq, baseline_seq, c["last_input_tick"], current, baseline)
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)
		c["history"][seq] = current
		c["next_seq"] = seq + 1
		var cutoff := seq - MAX_HISTORY
		for s in c["history"].keys():
			if s < cutoff: c["history"].erase(s)
		_tele.add_bytes(id, bytes.size())

func _on_packet(peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.HELLO: _handle_hello(peer, bytes)
		Protocol.Msg.INPUT: _handle_input(peer, bytes)
		_: pass

func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var r := Protocol.body_reader(bytes)
	var ver := r.get_u16()
	var pname := r.get_utf8_string()
	if ver != Protocol.VERSION:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("version mismatch"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later(); return
	if _clients.size() >= MAX_PLAYERS:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("server full"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later(); return
	var id := _next_id
	_next_id += 1
	var team: int = 0 if _team_counts[0] <= _team_counts[1] else 1
	_team_counts[team] += 1
	var cls := Loadout.random_class()
	var wid := Loadout.weapon_for(cls)
	var squad := _squads.assign(id, team)
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "queued_input": null, "last_input": null, "last_input_tick": 0,
		"last_acked_seq": 0, "next_seq": 1, "history": {},
		"team": team, "squad": squad, "class": cls, "weapon": wid, "ammo": Weapon.get_def(wid)["mag_size"],
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "trigger_down": false, "respawn_tick": 0,
	}
	var p := _sim.world.spawn(id)
	p.team = team
	p.squad = squad
	p.pos = _select_spawn(id)
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') team=%d squad=%d class=%d — %d peers" % [id, pname, team, squad, cls, _clients.size()])

func _handle_input(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var d := InputCommand.decode(bytes)
	var c = _clients[id]
	if c["queued_input"] != null and d["client_tick"] <= c["queued_input"]["client_tick"]: return
	c["queued_input"] = d
	var ack: int = d["ack_seq"]
	if ack > c["last_acked_seq"]:
		c["last_acked_seq"] = ack
		for s in c["history"].keys():
			if s < ack: c["history"].erase(s)

func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	_peer_to_id.erase(peer)
	if id != 0 and _clients.has(id):
		var team: int = _clients[id]["team"]
		_team_counts[team] -= 1
		_squads.remove(id, team)
		_clients.erase(id)
		_sim.world.despawn(id)
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])

func _log_telemetry() -> void:
	var n := _clients.size()
	var alive := 0
	for id in _sim.world.pawns:
		if _sim.world.pawns[id].alive: alive += 1
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	var hit_rate := 0.0 if _shots == 0 else float(_hits) / float(_shots)
	var pts := ""
	for pt in _conquest.points:
		pts += "." if pt["owner"] == -1 else str(pt["owner"])
	print("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d t0=%d t1=%d pts=%s cap_events=%d"
		% [n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit, _kills, _shots, hit_rate, _tele.starvation, _rewind_clamped, _conquest.tickets_int(0), _conquest.tickets_int(1), pts, _cap_events])
	_tele.reset_window()
	_kills = 0; _shots = 0; _hits = 0; _rewind_clamped = 0; _cap_events = 0
```

- [ ] **Step 2: Import + run the full suite** — `godot --headless --path . --import >/tmp/import.log 2>&1` then `godot --headless --path . -- --test >/tmp/test.log 2>&1`; open `/tmp/test.log` → 0 failed.

- [ ] **Step 3: Smoke run (4 bots, short)** — verify it boots, captures, and a `[match] OVER` eventually appears with tiny tickets:

```bash
godot --headless --path . -- --server --port=27241 --tickets=8 --time-limit=120 >/tmp/m3srv.log 2>&1 &
SRV=$!; sleep 2
godot --headless --path . -- --bots --bot-count=8 --port=27241 >/tmp/m3bots.log 2>&1 &
BOTS=$!; sleep 40
kill $BOTS $SRV 2>/dev/null
grep -E '\[telemetry\]|\[match\]' /tmp/m3srv.log | tail -5
```
Expected: telemetry lines show `pts=` changing from `.....` as points get captured, `t0`/`t1` decreasing, and (with tickets=8) a `[match] OVER winner=...` line. No errors/crashes.

- [ ] **Step 4: Dispatch a review subagent** (subagent-driven-development two-stage review) to check the integration against the spec: tick-loop ordering, grid pre-filter correctness (broad-phase margin), death ticket cost, spawn-source validity, match-end broadcast + exit, no regressions to M2 combat. Address any findings.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: server integration — conquest, squads, deploy spawns, match state, fire pre-filter"
```

---

## Task 10: Bot AI — objective pathing

**Files:** Modify `bots/bot_driver.gd`

Bots load the shared map, cache the latest `MATCH_STATE` owners, and march on the nearest non-owned point while engaging enemies within range. Gate-tested (no unit test — the bot is a live networked Node, as in M2).

- [ ] **Step 1: Add map + match-state state.** At the top of `bots/bot_driver.gd`, after the existing `const ENGAGE_RANGE` line, add:

```gdscript
const MAP_PATH := "res://maps/conquest_proving_grounds.json"

var _map: MapDef
var _match_points: Array = []   # array of {owner, attacker, cap}, index == map point index
```

- [ ] **Step 2: Load the map in `_ready`.** At the very start of `_ready()` (before the spawn loop), add:

```gdscript
	_map = MapDef.load_file(MAP_PATH)
	if _map == null:
		push_error("[bots] failed to load map %s" % MAP_PATH)
```

- [ ] **Step 3: Cache match state in `_on_packet`.** Add a case to the `match Protocol.msg_type(bytes):` block (alongside `WELCOME` / `SNAPSHOT`):

```gdscript
		Protocol.Msg.MATCH_STATE:
			_match_points = Protocol.decode_match_state(bytes)["points"]
```

- [ ] **Step 4: Add the objective helper.** Add this method to the file:

```gdscript
func _objective_pos(me: EntityState) -> Vector3:
	if _map == null or _map.points.is_empty():
		return me.pos
	var best := -1
	var best_d := INF
	for i in _map.points.size():
		var owner := -2
		if i < _match_points.size():
			owner = _match_points[i]["owner"]
		if owner == me.team:
			continue   # already ours — skip while capturable points remain
		var d: float = me.pos.distance_to(_map.points[i]["pos"])
		if d < best_d:
			best_d = d; best = i
	if best == -1:
		# team owns every point: defend the nearest one
		for i in _map.points.size():
			var d: float = me.pos.distance_to(_map.points[i]["pos"])
			if d < best_d:
				best_d = d; best = i
	return _map.points[best]["pos"] if best >= 0 else me.pos
```

- [ ] **Step 5: Rewrite the movement decision in `_drive`.** Replace the whole `if target != null: ... else: ...` block (the part that sets `move_x`/`move_y`/`bot["yaw"]` and the FIRE bit) with:

```gdscript
	var obj := _objective_pos(me)
	if target != null:
		var d := target.pos - me.pos
		var want_yaw := atan2(d.x, d.z)
		var want_pitch := clampf(asin(clampf(d.y / maxf(d.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
		bot["yaw"] = lerp_angle(bot["yaw"], want_yaw, 0.5) + randf_range(-0.003, 0.003)
		bot["pitch"] = lerpf(bot["pitch"], want_pitch, 0.5)
		# engage at close range; otherwise keep advancing on the objective
		var move_to: Vector3 = target.pos if best <= ENGAGE_RANGE else obj
		var flat := Vector2(move_to.x - me.pos.x, move_to.z - me.pos.z)
		if flat.length() > 0.001: flat = flat.normalized()
		move_x = flat.x; move_y = flat.y
		var yaw_ok := absf(angle_diff(bot["yaw"], want_yaw)) < AIM_TOLERANCE
		var pitch_ok := absf(want_pitch - bot["pitch"]) < AIM_TOLERANCE
		if best <= ENGAGE_RANGE and yaw_ok and pitch_ok:
			buttons |= InputCommand.BTN_FIRE
	else:
		# no enemy in view: march to the objective (capture/defend)
		var flat := Vector2(obj.x - me.pos.x, obj.z - me.pos.z)
		if flat.length() > 0.001: flat = flat.normalized()
		move_x = flat.x; move_y = flat.y
		bot["yaw"] = atan2(move_x, move_y)
```

(`best` is the existing nearest-enemy distance variable computed just above this block; `target` is the nearest enemy `EntityState`. Leave the acquire loop that computes them unchanged.)

- [ ] **Step 6: Import + run the full suite** — `godot --headless --path . --import >/tmp/import.log 2>&1` then `godot --headless --path . -- --test >/tmp/test.log 2>&1` → 0 failed (no test touches the bot, but this catches compile errors in `bot_driver.gd`).

- [ ] **Step 7: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: bot AI paths to nearest non-owned objective, engages en route"
```

---

## Task 11: Gate — 128-bot Conquest match to a win

**Files:** Create `ci/m3_conquest_test.sh`

- [ ] **Step 1: Write `ci/m3_conquest_test.sh`**

```bash
#!/usr/bin/env bash
# M3 gate: server + 128 bots (2 teams) play Conquest to a win. Assert a winner is
# declared, points were captured, peak server tick < budget, and the match ended via
# tickets (not the time fail-safe). Exit non-zero on breach.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27240}"
BOTS="${BOTS:-128}"
TICKETS="${TICKETS:-120}"          # shortened pool so the gate match completes promptly
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m3] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT)"
"$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m3] $BOTS bots"
"$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
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
elapsed="$(echo "$over_line" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over_line" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"
echo "[m3] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak-window mean tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
awk "BEGIN{exit !($peak_tick < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !($elapsed < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M3 GATE: PASS"; exit 0; else echo "M3 GATE: FAIL"; exit 1; fi
```

- [ ] **Step 2: Make executable + run the gate**

```bash
chmod +x ci/m3_conquest_test.sh
GODOT="${GODOT:-godot}" ./ci/m3_conquest_test.sh | tee /tmp/m3_gate.log
```
Expected final line: `M3 GATE: PASS`. The match should end via tickets (`elapsed < TIME_LIMIT`), with `cap_events >= 1` and `peak tick < 33.3 ms`.

- [ ] **Step 3: Tune if needed.** If the gate fails:
  - **No winner within MAX_WAIT / hit the time fail-safe** → the match is too slow: lower the gate `TICKETS` (e.g. 80), or in `shared/sim/conquest.gd` raise `BLEED_PER_FLAG` (e.g. 1.5). Re-run.
  - **No captures (`cap_events=0`)** → bots aren't reaching/holding points: check `_objective_pos` (owners indexing) and that `CAP_RATE_BASE` isn't too slow for the time bots spend on a point. Lower `CAP_RATE_BASE` denominator (raise it, e.g. 0.15) to capture faster.
  - **Tick over budget** → confirm the fire pre-filter is active (grid query, not full-frame scan) and interest density isn't pathological; capture the failing telemetry for the follow-up.
  Keep changes within the spec's model; commit any constant retune with the evidence.

- [ ] **Step 4: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: Conquest gate — 128-bot match to a win"
```

---

## Task 12: Record evidence + update docs

**Files:** Modify `docs/milestones/M3-conquest-squads.md`, `docs/TASKS.md`, `docs/HANDOVER.md`, `docs/specs/m3-conquest-squads.md`

- [ ] **Step 1: Paste the gate evidence** into `docs/milestones/M3-conquest-squads.md` — the `M3 GATE: PASS` line plus the `[match] OVER ...` line and the peak-window telemetry line from `/tmp/m3_gate.log` (winner, elapsed, cap_events, peak tick, final tickets/`pts`). Mark the milestone **done ✅** with the run date (2026-06-14).

- [ ] **Step 2: Update `docs/TASKS.md`** — set the M3 row to **done ✅** with the gate evidence summary (mirror the M2 row format), matching the milestone doc.

- [ ] **Step 3: Update `docs/HANDOVER.md`** — move M3 to ✅ with a one-line status; set **M4 (Building & destruction)** as NEXT; fold any new follow-ups discovered (e.g. interest-recompute staggering if density bit, conquest cost under load) into the tracked follow-ups section; note `MapDef`/`ConquestState`/`SquadManager`/`SpawnSelect`/`MATCH_STATE` in the architecture summary.

- [ ] **Step 4: Flip the spec status** — in `docs/specs/m3-conquest-squads.md` change `Status: approved-pending-review` to `approved`.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M3: record gate evidence; close milestone; docs handover to M4"
```

- [ ] **Step 6: Finish the branch** — invoke `superpowers:finishing-a-development-branch` to merge `m3-conquest-squads` into `master` and push (`git push origin master`), per the working agreement.

---

## Self-review notes (coverage check)

- **Spec §A Map** → Task 1 (`MapDef` + JSON, validation: empty points, bad radius, missing team base, start_owner default).
- **Spec §B Conquest machine** → Task 2 (neutral→capture, enemy→neutralize→capture, contest freeze, multi-attacker rate, empty decay, `nearest_capturable_index`).
- **Spec §C Tickets/win** → Task 2 (bleed by deficit, death cost, win at 0) + Task 9 (`register_death` on kill).
- **Spec §D Squads** → Task 7 (`SquadManager`) + Task 9 (assign on join, remove on disconnect, replicate via Tasks 3–5).
- **Spec §E Spawning** → Task 8 (`SpawnSelect`) + Task 9 (`_select_spawn`/`_objective_for`, respawn + join use it).
- **Spec §F Wire** → Task 3 (`EntityState.squad`), Task 5 (`F_SQUAD`), Task 6 (`MATCH_STATE`).
- **Spec §G Bot AI** → Task 10.
- **Spec §H Perf pre-filter** → Task 9 (`_build_interest` + grid broad-phase in `_fire_shot`).
- **Spec §I Gate** → Task 11; **§K testing** → per-module tests in Tasks 1–8; evidence in Task 12.

Type consistency: `MapDef.from_json_string` → `{ok,map,error}`; `ConquestState.new(map)`, `.points[i]{owner,attacker,cap,pos,radius}`, `.tickets`, `.tickets_int`, `.register_death`, `.nearest_capturable_index`, `.step(dt,world)`, `.time_limit`; `SquadManager.assign/remove/leader_of/members`, `SQUAD_SIZE`; `SpawnSelect.select(team,map,conquest,mates,objective)`, `JITTER`; `Protocol.encode_match_state(points,tickets,over,winner,elapsed)` / `decode_match_state` → `{points[{owner,attacker,cap}],tickets,match_over,winner,elapsed}`; snapshot `F_SQUAD`/`F_ALL=255`. Names match across Tasks 9–11.
```
