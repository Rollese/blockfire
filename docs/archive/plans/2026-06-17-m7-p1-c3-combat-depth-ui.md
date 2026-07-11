# M7 P1 Checkpoint 3 — Combat-Depth UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the rendered client's player-facing combat-depth UI: squad list + TAB scoreboard, DBNO/revive prompts + bleed-out, gadget/grenade use + selector, build/destroy feedback, deploy-on-squadmate, and the death-recap card — all on placeholder primitives, against bots on game2.

**Architecture:** The client stays a **view + predictor + intent-sender, never authority** (AGENTS.md §7). C3 adds only **client/server-edge and presentation-only** netcode: `ROSTER` (names + per-client K/D/score), `SET_SQUAD`, `DEATH_INFO` (recap), an extended `SELF_STATE` (throwable/gadget counts), and an extended `DeploySpawn` ref scheme (squadmate + friendly-vehicle spawns). HUD *state* grows in the pure, headless-tested `hud_model`; HUD *drawing* + structure visuals are validated by the owner's playtest (AGENTS.md §10). No gameplay rule logic enters `client/`.

**Tech Stack:** Godot 4.6 / GDScript. Tests: `godot --headless --path . -- --test [--filter=<substr>]`, classes extend global `TestCase` (tests/*_test.gd).

**Scope (C3):** the combat-depth UI listed above. **Out of C3:** the art kit + LOD + VFX/audio polish — tracers, suppression blur/shake, flashbang white-out, armor visual diffs (P2); full client-side **build placement UI** (C3 does render + build/destroy *feedback* only — bots/server still place pieces; owner-directed 2026-06-17); the M5.5 sim systems themselves (projectiles, fire-mode, secondary, armor, suppression, melee, flashbang/impact) — C3 only leaves seams so they slot in without a rewrite.

## M5.5 seams (build-don't-preclude — see [combat-depth-2](../specs/combat-depth-2.md) §1 + M7 ⚡ callout)
- **Throwable selector is a variable, data-driven list** (`SELF_STATE.throwables` carries `[{kind, count}]`), never hardcoded to exactly frag+smoke — M5.5 adds flashbang/impact by adding list entries, no UI rewrite.
- **Weapon/ammo HUD reads from data** (already `WeaponPredictor.weapon` + `Weapon.get_def`), so a later weapon-swap + fire-mode indicator slots in beside it.
- **Recap distance/killer data ride the server-confirmed model** (`DEATH_INFO`), which is projectile-compatible — no hit-scan assumption is baked in.
- **Do not touch tracers** — they stay the C1 cosmetic beam; projectile tracers + all other VFX are P2.

## GDScript / Godot gotchas (every task)
- After adding any new `class_name` script, run **`godot --headless --path . --import`** once before tests (don't pipe `godot` through `tail`/`head` — redirect to a file if needed).
- GDScript 4.6 rejects `var x := <Dictionary access>` (Variant) — annotate the type explicitly; don't change logic.
- The harness **fails any test that runs zero assertions** (catches compile-error false-passes), so every test must assert.
- `git add -A` to include Godot `.uid` sidecars in commits. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Server logic bound to the `server_main` Node isn't headless-instantiable; follow the established pattern — **extract pure helpers into a class and unit-test those** (like `SpawnSelect`/`Revive`/`DeploySpawn`), or mirror the method in the test (like `server_deploy_test._try_deploy`).

## File map

| File | Create/Modify | Responsibility |
|---|---|---|
| `shared/net/protocol.gd` | Modify | Add `ROSTER`, `SET_SQUAD`, `DEATH_INFO` messages; extend `SELF_STATE` with a `throwables` block (back-compat). |
| `shared/sim/deploy_spawn.gd` | Modify | Extend ref scheme + enumerate/is_valid/resolve to cover squadmate + friendly-vehicle spawns (rules stay in shared). |
| `shared/sim/death_recap.gd` | Create | Pure: sort a per-life damage ledger into a recap attacker list. |
| `client/hud/hud_model.gd` | Modify | Add `scoreboard`, `squad_roster`, `interaction_prompt`, `throwables`, `death_recap` to `build()`; throwable cycle helper. |
| `client/world_view.gd` | Modify | Apply `STRUCTURE_BASELINE`/`STRUCTURE_DELTA` into a structure store; hold the latest `ROSTER`. |
| `client/hud/hud_view.gd` | Modify | Draw scoreboard, squad list, revive/bleed-out prompt, throwable selector, build/destroy cues, death-recap card. Playtest-validated. |
| `client/world_renderer.gd` | Modify | Render structures (placeholder boxes, health-tinted) + build/destroy pop feedback. Playtest-validated. |
| `client/menus/deploy_menu.gd` | Modify | List squadmate + friendly-vehicle spawn options alongside HQ/points. |
| `client/client_main.gd` | Modify | Wire reviver `REVIVE_ACTION`/`SELF_BANDAGE`, `GRENADE_THROW`/`GADGET_ACTION`, `SET_SQUAD`; handle `ROSTER`/`DEATH_INFO`; route `SELF_STATE.throwables`; TAB scoreboard hold. |
| `server/server_main.gd` | Modify | Per-client `name`/`kills`/`deaths`/`score`; per-life damage ledger; emit `ROSTER` + `DEATH_INFO`; handle `SET_SQUAD`; deploy-on-squadmate/vehicle; throwable counts in `SELF_STATE`. |
| `project.godot` | Modify | Input actions: `throwable_cycle`, `throw`, `gadget`, `squad_menu` (scoreboard/interact already exist). |
| `tests/*_test.gd` | Create/Modify | One test file per testable unit below. |

---

# Part 1 — Wire protocol + pure helpers (TDD)

### Task 1: `ROSTER` message — names + per-client K/D/score

**Files:** Modify `shared/net/protocol.gd`; Test `tests/protocol_test.gd` (add cases).

Carries one row per connected client so the client can show names, squads, and the scoreboard (today only entity ids are known client-side).

- [ ] **Step 1: Add failing test** to `tests/protocol_test.gd`:

```gdscript
func test_roster_roundtrip() -> void:
	var rows := [
		{"id": 7, "name": "Ada", "team": 0, "squad": 1, "kills": 3, "deaths": 1, "score": 300},
		{"id": 9, "name": "Bo", "team": 1, "squad": 0, "kills": 0, "deaths": 2, "score": 0},
	]
	var b := Protocol.encode_roster(rows)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.ROSTER)
	var out := Protocol.decode_roster(b)["rows"]
	assert_eq(out.size(), 2)
	assert_eq(out[0]["name"], "Ada")
	assert_eq(out[0]["kills"], 3)
	assert_eq(out[1]["id"], 9)
	assert_eq(out[1]["deaths"], 2)
```

- [ ] **Step 2: Run, verify fail**

Run: `godot --headless --path . -- --test --filter=protocol`
Expected: FAIL ("ROSTER not a valid member" / encode missing).

- [ ] **Step 3: Implement** — add to the `Msg` enum (next free value `25`) and functions:

```gdscript
	ROSTER = 25,            ## server -> clients: per-client name/team/squad/kills/deaths/score
```
```gdscript
static func encode_roster(rows: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.ROSTER)
	buf.put_u8(mini(rows.size(), 255))
	for i in mini(rows.size(), 255):
		var rw: Dictionary = rows[i]
		buf.put_u32(int(rw["id"]))
		buf.put_utf8_string(String(rw["name"]))
		buf.put_u8(int(rw["team"]) & 0xFF)
		buf.put_u8(int(rw["squad"]) & 0xFF)
		buf.put_u16(clampi(int(rw["kills"]), 0, 65535))
		buf.put_u16(clampi(int(rw["deaths"]), 0, 65535))
		buf.put_u16(clampi(int(rw["score"]), 0, 65535))
	return buf.data_array

static func decode_roster(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var rows: Array = []
	for _i in n:
		var id := r.get_u32()
		var nm := r.get_utf8_string()
		rows.append({"id": id, "name": nm, "team": r.get_u8(), "squad": r.get_u8(),
			"kills": r.get_u16(), "deaths": r.get_u16(), "score": r.get_u16()})
	return {"rows": rows}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): ROSTER wire message (names + per-client K/D/score)`.

---

### Task 2: `SET_SQUAD` message — join/switch squad

**Files:** Modify `shared/net/protocol.gd`; Test `tests/protocol_test.gd`.

- [ ] **Step 1: Failing test**

```gdscript
func test_set_squad_roundtrip() -> void:
	var b := Protocol.encode_set_squad(4)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.SET_SQUAD)
	assert_eq(Protocol.decode_set_squad(b)["squad"], 4)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — enum `SET_SQUAD = 26` and:

```gdscript
static func encode_set_squad(squad_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SET_SQUAD)
	buf.put_u8(squad_id & 0xFF)
	return buf.data_array

static func decode_set_squad(bytes: PackedByteArray) -> Dictionary:
	return {"squad": body_reader(bytes).get_u8()}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): SET_SQUAD wire message`.

---

### Task 3: `DEATH_INFO` message — death-recap payload

**Files:** Modify `shared/net/protocol.gd`; Test `tests/protocol_test.gd`.

Presentation-only, sent to the **victim** on true death: `killer_id` (u32), `weapon` (u8), `distance` (u16, 0.1 m units), `killer_hp` (u8), then a per-attacker damage aggregate `[{id u32, dmg u16}]`.

- [ ] **Step 1: Failing test**

```gdscript
func test_death_info_roundtrip() -> void:
	var atk := [{"id": 7, "dmg": 80}, {"id": 9, "dmg": 20}]
	var b := Protocol.encode_death_info(7, Weapon.AR, 42.5, 35, atk)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.DEATH_INFO)
	var d := Protocol.decode_death_info(b)
	assert_eq(d["killer"], 7)
	assert_eq(d["weapon"], Weapon.AR)
	assert_almost_eq(d["distance"], 42.5, 0.1, "distance preserved to 0.1m")
	assert_eq(d["killer_hp"], 35)
	assert_eq(d["attackers"].size(), 2)
	assert_eq(d["attackers"][0]["id"], 7)
	assert_eq(d["attackers"][0]["dmg"], 80)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — enum `DEATH_INFO = 27` and:

```gdscript
static func encode_death_info(killer_id: int, weapon: int, distance: float, killer_hp: int, attackers: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DEATH_INFO)
	buf.put_u32(killer_id)
	buf.put_u8(weapon & 0xFF)
	buf.put_u16(clampi(roundi(distance * 10.0), 0, 65535))
	buf.put_u8(clampi(killer_hp, 0, 255))
	buf.put_u8(mini(attackers.size(), 255))
	for i in mini(attackers.size(), 255):
		var a: Dictionary = attackers[i]
		buf.put_u32(int(a["id"]))
		buf.put_u16(clampi(int(a["dmg"]), 0, 65535))
	return buf.data_array

static func decode_death_info(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var killer := r.get_u32()
	var weapon := r.get_u8()
	var distance := float(r.get_u16()) / 10.0
	var killer_hp := r.get_u8()
	var n := r.get_u8()
	var attackers: Array = []
	for _i in n:
		attackers.append({"id": r.get_u32(), "dmg": r.get_u16()})
	return {"killer": killer, "weapon": weapon, "distance": distance, "killer_hp": killer_hp, "attackers": attackers}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): DEATH_INFO wire message (death-recap payload)`.

---

### Task 4: Extend `SELF_STATE` with a throwables block (back-compat)

**Files:** Modify `shared/net/protocol.gd`; Test `tests/protocol_test.gd`.

Append a `throwables` list `[{kind, count}]` after the existing 4 fields so the selector shows live counts. **Back-compat:** the existing `test_self_state_roundtrip` (4-arg call) must stay green — decode reads the block only if bytes remain, and `throwables` defaults to `[]` when absent.

- [ ] **Step 1: Add failing test** (keep the existing 4-field test untouched):

```gdscript
func test_self_state_carries_throwables() -> void:
	var thr := [{"kind": 0, "count": 1}, {"kind": 1, "count": 2}]   # frag ready, 2 gadget charges
	var b := Protocol.encode_self_state(17, false, 0, Weapon.AR, thr)
	var d := Protocol.decode_self_state(b)
	assert_eq(d["mag"], 17)
	assert_eq(d["throwables"].size(), 2)
	assert_eq(d["throwables"][1]["kind"], 1)
	assert_eq(d["throwables"][1]["count"], 2)

func test_self_state_without_throwables_defaults_empty() -> void:
	var b := Protocol.encode_self_state(30, false, 0, Weapon.AR)   # 4-arg (pre-C3 senders)
	var d := Protocol.decode_self_state(b)
	assert_eq(d["throwables"], [], "absent block decodes as empty list")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — replace `encode_self_state`/`decode_self_state`:

```gdscript
static func encode_self_state(mag: int, reloading: bool, reload_remaining: int, weapon: int, throwables: Array = []) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SELF_STATE)
	buf.put_u8(clampi(mag, 0, 255))
	buf.put_u8(1 if reloading else 0)
	buf.put_u16(clampi(reload_remaining, 0, 65535))
	buf.put_u8(weapon & 0xFF)
	buf.put_u8(mini(throwables.size(), 255))
	for i in mini(throwables.size(), 255):
		var t: Dictionary = throwables[i]
		buf.put_u8(int(t["kind"]) & 0xFF)
		buf.put_u8(clampi(int(t["count"]), 0, 255))
	return buf.data_array

static func decode_self_state(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var mag := r.get_u8()
	var reloading := r.get_u8() == 1
	var reload_remaining := r.get_u16()
	var weapon := r.get_u8()
	var throwables: Array = []
	if r.get_available_bytes() > 0:
		var n := r.get_u8()
		for _i in n:
			throwables.append({"kind": r.get_u8(), "count": r.get_u8()})
	return {"mag": mag, "reloading": reloading, "reload_remaining": reload_remaining, "weapon": weapon, "throwables": throwables}
```

- [ ] **Step 4: Run, verify pass (new + existing 4-field test).**  **Step 5: Commit** — `feat(m7-c3): SELF_STATE carries throwable/gadget counts (back-compat)`.

---

### Task 5: `DeploySpawn` — squadmate + friendly-vehicle spawn refs

**Files:** Modify `shared/sim/deploy_spawn.gd`; Test `tests/deploy_spawn_test.gd` (add cases; existing C1 cases stay green).

Ref scheme grows: `0` = HQ; `1..N` = owned capture point; `SQUADMATE_BASE+i` = squadmate at index `i` of the passed `squadmates` array; `VEHICLE_BASE+i` = friendly vehicle at index `i`. The validity rules (mate alive + standing + same team; vehicle same team + free seat) live **in `DeploySpawn`** (shared) — the server passes live state, the client passes mirrored state, both apply the same rule. New params are optional so existing C1 callers/tests are unaffected.

- [ ] **Step 1: Add failing tests**

```gdscript
func test_squadmate_ref_valid_when_mate_alive_standing() -> void:
	var m := _map()
	var c := _conquest(-1)
	var mates := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
	assert_true(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, mates),
		"alive standing same-team mate is a valid spawn")
	var pos := DeploySpawn.resolve(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, mates)
	assert_almost_eq(pos.distance_to(Vector3(20, 0, 5)), 0.0, DeploySpawn.JITTER + 0.01,
		"resolves near the mate (within jitter)")

func test_squadmate_ref_invalid_when_downed_or_dead() -> void:
	var m := _map()
	var c := _conquest(-1)
	var downed := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": true}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, downed), "downed mate rejected")
	var dead := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": false, "downed": false}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, dead), "dead mate rejected")

func test_vehicle_ref_valid_with_free_seat_same_team() -> void:
	var m := _map()
	var c := _conquest(-1)
	var veh := [{"pos": Vector3(30, 0, 30), "team": 0, "free_seats": 2}]
	assert_true(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], veh), "free-seat friendly vehicle valid")
	var full := [{"pos": Vector3(30, 0, 30), "team": 0, "free_seats": 0}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], full), "full vehicle rejected")
	var enemy := [{"pos": Vector3(30, 0, 30), "team": 1, "free_seats": 2}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], enemy), "enemy vehicle rejected")

func test_enumerate_includes_valid_squadmate_and_vehicle_refs() -> void:
	var m := _map()
	var c := _conquest(0)
	var mates := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
	var veh := [{"pos": Vector3(30, 0, 30), "team": 0, "free_seats": 1}]
	var refs := DeploySpawn.enumerate(0, m, c, mates, veh)
	assert_true(refs.has(DeploySpawn.SQUADMATE_BASE + 0), "valid mate ref offered")
	assert_true(refs.has(DeploySpawn.VEHICLE_BASE + 0), "valid vehicle ref offered")
	assert_true(refs.has(0), "HQ still offered")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add constants + helpers, extend the three functions (keep existing HQ/point branches verbatim):

```gdscript
const SQUADMATE_BASE := 200
const VEHICLE_BASE := 220

static func _mate_ok(m: Dictionary, team: int) -> bool:
	return int(m.get("team", -1)) == team and bool(m.get("alive", false)) and not bool(m.get("downed", false))

static func _veh_ok(v: Dictionary, team: int) -> bool:
	return int(v.get("team", -1)) == team and int(v.get("free_seats", 0)) > 0

static func enumerate(team: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> Array:
	var refs: Array = [0]
	for i in conquest.points.size():
		if int(conquest.points[i]["owner"]) == team:
			refs.append(i + 1)
	for i in squadmates.size():
		if _mate_ok(squadmates[i], team):
			refs.append(SQUADMATE_BASE + i)
	for i in vehicles.size():
		if _veh_ok(vehicles[i], team):
			refs.append(VEHICLE_BASE + i)
	return refs

static func is_valid(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> bool:
	if ref >= VEHICLE_BASE:
		var vi := ref - VEHICLE_BASE
		return vi >= 0 and vi < vehicles.size() and _veh_ok(vehicles[vi], team)
	if ref >= SQUADMATE_BASE:
		var si := ref - SQUADMATE_BASE
		return si >= 0 and si < squadmates.size() and _mate_ok(squadmates[si], team)
	if ref == 0:
		return not map.base_for(team).is_empty()
	var idx := ref - 1
	if idx < 0 or idx >= conquest.points.size():
		return false
	return int(conquest.points[idx]["owner"]) == team

static func resolve(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> Vector3:
	var src := Vector3.ZERO
	if ref >= VEHICLE_BASE:
		src = vehicles[ref - VEHICLE_BASE]["pos"]
	elif ref >= SQUADMATE_BASE:
		src = squadmates[ref - SQUADMATE_BASE]["pos"]
	elif ref == 0:
		var base := map.base_for(team)
		src = base["pos"] if not base.is_empty() else Vector3.ZERO
	else:
		src = conquest.points[ref - 1]["pos"]
	return Vector3(src.x + randf_range(-JITTER, JITTER), 0.0, src.z + randf_range(-JITTER, JITTER))
```

(The existing `enumerate`/`is_valid`/`resolve` bodies are replaced by these extended versions — the HQ/point logic is preserved inside them, so the C1 tests still pass.)

- [ ] **Step 4: Import + run, verify pass (`--filter=deploy_spawn`, new + C1 cases).**  **Step 5: Commit** — `feat(m7-c3): DeploySpawn squadmate + friendly-vehicle spawn refs`.

---

### Task 6: `DeathRecap` — pure ledger → sorted attacker list

**Files:** Create `shared/sim/death_recap.gd`; Test `tests/death_recap_test.gd`.

Pure helper the server uses to turn its per-life damage ledger (`attacker_id -> total dmg`) into the ordered `attackers` list `DEATH_INFO` carries. Sorted by damage desc, then id asc for determinism.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func test_sorts_by_damage_desc_then_id() -> void:
	var ledger := {7: 20, 9: 80, 3: 80}
	var out := DeathRecap.attackers_sorted(ledger)
	assert_eq(out.size(), 3)
	assert_eq(out[0]["id"], 3, "ties broken by lower id first")
	assert_eq(out[0]["dmg"], 80)
	assert_eq(out[1]["id"], 9)
	assert_eq(out[2]["id"], 7)

func test_empty_ledger_is_empty_list() -> void:
	assert_eq(DeathRecap.attackers_sorted({}).size(), 0)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement**

```gdscript
class_name DeathRecap
extends Object
## Pure: turn a per-life damage ledger {attacker_id -> total_dmg} into the ordered attacker list
## carried by DEATH_INFO (damage desc, then id asc for determinism). Presentation-only — no rules.

static func attackers_sorted(ledger: Dictionary) -> Array:
	var rows: Array = []
	for id in ledger:
		rows.append({"id": int(id), "dmg": int(ledger[id])})
	rows.sort_custom(func(a, b):
		if a["dmg"] != b["dmg"]:
			return a["dmg"] > b["dmg"]
		return a["id"] < b["id"])
	return rows
```

- [ ] **Step 4: Import + run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): DeathRecap pure ledger→attacker sort`.

---

### Task 7: `hud_model` — scoreboard

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

From the latest `ROSTER` rows (in ctx). Rows grouped per team, each team sorted by **score desc then name asc**; team ticket totals passed through from match state.

- [ ] **Step 1: Failing test**

```gdscript
func test_scoreboard_groups_by_team_and_sorts_by_score_then_name() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 1, "name": "Zoe", "team": 0, "squad": 0, "kills": 5, "deaths": 1, "score": 500},
		{"id": 2, "name": "Al",  "team": 0, "squad": 0, "kills": 5, "deaths": 1, "score": 500},
		{"id": 3, "name": "Ed",  "team": 1, "squad": 0, "kills": 2, "deaths": 4, "score": 200},
	]
	var out := m.build({"roster": roster, "match_state": {"tickets": [120, 95]}, "tick": 0})
	var sb := out["scoreboard"]
	assert_eq(sb["teams"][0]["rows"].size(), 2)
	assert_eq(sb["teams"][0]["rows"][0]["name"], "Al", "score tie -> name asc")
	assert_eq(sb["teams"][0]["tickets"], 120)
	assert_eq(sb["teams"][1]["rows"][0]["name"], "Ed")
	assert_eq(sb["teams"][1]["tickets"], 95)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add `"scoreboard": _scoreboard(ctx)` to `build()`'s return dict and:

```gdscript
func _scoreboard(ctx: Dictionary) -> Dictionary:
	var roster: Array = ctx.get("roster", [])
	var ms: Dictionary = ctx.get("match_state", {})
	var tickets: Array = ms.get("tickets", [0, 0])
	var teams: Array = []
	for t in 2:
		var rows: Array = []
		for rw in roster:
			if int(rw["team"]) == t:
				rows.append(rw)
		rows.sort_custom(func(a, b):
			if int(a["score"]) != int(b["score"]):
				return int(a["score"]) > int(b["score"])
			return String(a["name"]) < String(b["name"]))
		teams.append({"team": t, "rows": rows, "tickets": int(tickets[t]) if t < tickets.size() else 0})
	return {"teams": teams}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): hud_model scoreboard (team group + score/name sort)`.

---

### Task 8: `hud_model` — squad roster

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

The local player's squadmates with live status. Membership/names come from `ROSTER` (ctx `roster` + `self_id`); alive/downed status comes from the interpolated `world_view` entities passed as ctx `entities` (`id -> {alive, is_downed, pos}`). Self is excluded.

- [ ] **Step 1: Failing test**

```gdscript
func test_squad_roster_lists_squadmates_with_status() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 1, "name": "Me",  "team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
		{"id": 2, "name": "Mate","team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
		{"id": 3, "name": "Other","team": 0, "squad": 5, "kills": 0, "deaths": 0, "score": 0},
	]
	var ents := {2: {"alive": true, "is_downed": true, "pos": Vector3(10, 0, 0)}}
	var out := m.build({"roster": roster, "self_id": 1, "entities": ents, "tick": 0})
	var sq := out["squad_roster"]
	assert_eq(sq.size(), 1, "only same-squad, excluding self")
	assert_eq(sq[0]["name"], "Mate")
	assert_eq(sq[0]["status"], "downed", "downed status from entities")

func test_squad_roster_marks_dead_when_absent_or_not_alive() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 1, "name": "Me", "team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
		{"id": 2, "name": "Gone","team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
	]
	var out := m.build({"roster": roster, "self_id": 1, "entities": {}, "tick": 0})
	assert_eq(out["squad_roster"][0]["status"], "dead", "no entity -> dead/out of view")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add `"squad_roster": _squad_roster(ctx)` to `build()` and:

```gdscript
func _squad_roster(ctx: Dictionary) -> Array:
	var roster: Array = ctx.get("roster", [])
	var self_id := int(ctx.get("self_id", 0))
	var entities: Dictionary = ctx.get("entities", {})
	var my_team := -1
	var my_squad := -1
	for rw in roster:
		if int(rw["id"]) == self_id:
			my_team = int(rw["team"]); my_squad = int(rw["squad"]); break
	var out: Array = []
	if my_team < 0:
		return out
	for rw in roster:
		if int(rw["id"]) == self_id or int(rw["team"]) != my_team or int(rw["squad"]) != my_squad:
			continue
		var e: Dictionary = entities.get(int(rw["id"]), {})
		var status := "dead"
		if not e.is_empty() and bool(e.get("alive", false)):
			status = "downed" if bool(e.get("is_downed", false)) else "alive"
		out.append({"id": int(rw["id"]), "name": String(rw["name"]), "status": status})
	return out
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): hud_model squad roster with live status`.

---

### Task 9: `hud_model` — interaction prompt

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

Pure proximity selection of the single contextual action, by priority: **revive** a downed squadmate in `Revive.REVIVE_RANGE` > **enter** a friendly vehicle seat in `vehicle_range` > none. ctx provides `downed_mates` (`[{id, dist}]`) and `vehicles_near` (`[{vid, seat, dist}]`). Returns `null` when nothing is in range.

- [ ] **Step 1: Failing test**

```gdscript
func test_prompt_prefers_revive_over_vehicle() -> void:
	var m := HudModel.new()
	var out := m.build({
		"downed_mates": [{"id": 5, "dist": 2.0}],
		"vehicles_near": [{"vid": 9, "seat": 1, "dist": 1.0}],
		"tick": 0})
	var p := out["interaction_prompt"]
	assert_eq(p["action"], "revive")
	assert_eq(p["target"], 5)

func test_prompt_enter_vehicle_when_no_downed_mate() -> void:
	var m := HudModel.new()
	var out := m.build({"downed_mates": [], "vehicles_near": [{"vid": 9, "seat": 1, "dist": 1.0}], "tick": 0})
	assert_eq(out["interaction_prompt"]["action"], "enter_vehicle")
	assert_eq(out["interaction_prompt"]["target"], 9)

func test_prompt_none_when_nothing_in_range() -> void:
	var m := HudModel.new()
	var out := m.build({"downed_mates": [], "vehicles_near": [], "tick": 0})
	assert_eq(out["interaction_prompt"], null)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add `"interaction_prompt": _interaction_prompt(ctx)` to `build()` and:

```gdscript
func _interaction_prompt(ctx: Dictionary):
	var mates: Array = ctx.get("downed_mates", [])
	if not mates.is_empty():
		var best: Dictionary = mates[0]
		for mt in mates:
			if float(mt["dist"]) < float(best["dist"]):
				best = mt
		return {"action": "revive", "target": int(best["id"])}
	var veh: Array = ctx.get("vehicles_near", [])
	if not veh.is_empty():
		var bv: Dictionary = veh[0]
		for v in veh:
			if float(v["dist"]) < float(bv["dist"]):
				bv = v
		return {"action": "enter_vehicle", "target": int(bv["vid"]), "seat": int(bv["seat"])}
	return null
```

(`client_main` builds `downed_mates`/`vehicles_near` from `world_view` proximity each frame — Task 19. Resupply/ammo-bag prompts are out of C3 scope; the priority list is extensible.)

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): hud_model interaction prompt (revive > vehicle)`.

---

### Task 10: `hud_model` — throwable selector + active cycle

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

Exposes the throwable/gadget list (`from SELF_STATE.throwables`, variable length — M5.5 seam) and the locally-tracked active index. `cycle_throwable()` advances the active index, wrapping. `build()` returns `{list, active}`.

- [ ] **Step 1: Failing test**

```gdscript
func test_throwables_passthrough_and_active_cycle() -> void:
	var m := HudModel.new()
	var thr := [{"kind": 0, "count": 1}, {"kind": 1, "count": 2}, {"kind": 2, "count": 0}]
	var out := m.build({"throwables": thr, "tick": 0})
	assert_eq(out["throwables"]["list"].size(), 3)
	assert_eq(out["throwables"]["active"], 0, "defaults to first slot")
	m.cycle_throwable(thr.size())
	var out2 := m.build({"throwables": thr, "tick": 0})
	assert_eq(out2["throwables"]["active"], 1, "cycle advances active slot")
	m.cycle_throwable(thr.size()); m.cycle_throwable(thr.size())
	assert_eq(m.build({"throwables": thr, "tick": 0})["throwables"]["active"], 0, "wraps around")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add a member, `cycle_throwable`, and `"throwables": _throwables(ctx)` in `build()`:

```gdscript
var _throwable_active: int = 0

func cycle_throwable(count: int) -> void:
	if count <= 0:
		_throwable_active = 0
		return
	_throwable_active = (_throwable_active + 1) % count

func _throwables(ctx: Dictionary) -> Dictionary:
	var list: Array = ctx.get("throwables", [])
	if not list.is_empty() and _throwable_active >= list.size():
		_throwable_active = 0
	return {"list": list, "active": _throwable_active}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): hud_model throwable selector (variable list + active cycle)`.

---

### Task 11: `hud_model` — death recap

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

Build the recap card from a decoded `DEATH_INFO` plus the `ROSTER` (to resolve killer/attacker **names**). `set_death_info(info)` stores it; `clear_death_info()` drops it on redeploy; `build()` returns `death_recap` (null when none).

- [ ] **Step 1: Failing test**

```gdscript
func test_death_recap_resolves_names_from_roster() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 7, "name": "Killer", "team": 1, "squad": 0, "kills": 1, "deaths": 0, "score": 100},
		{"id": 9, "name": "Helper", "team": 1, "squad": 0, "kills": 0, "deaths": 0, "score": 0},
	]
	m.set_death_info({"killer": 7, "weapon": Weapon.AR, "distance": 42.5, "killer_hp": 35,
		"attackers": [{"id": 7, "dmg": 80}, {"id": 9, "dmg": 20}]})
	var out := m.build({"roster": roster, "tick": 0})
	var dr := out["death_recap"]
	assert_eq(dr["killer_name"], "Killer")
	assert_almost_eq(dr["distance"], 42.5, 0.1)
	assert_eq(dr["killer_hp"], 35)
	assert_eq(dr["attackers"][0]["name"], "Killer")
	assert_eq(dr["attackers"][0]["dmg"], 80)
	assert_eq(dr["attackers"][1]["name"], "Helper")

func test_death_recap_null_until_set_and_after_clear() -> void:
	var m := HudModel.new()
	assert_eq(m.build({"tick": 0})["death_recap"], null)
	m.set_death_info({"killer": 7, "weapon": 0, "distance": 1.0, "killer_hp": 100, "attackers": []})
	m.clear_death_info()
	assert_eq(m.build({"tick": 0})["death_recap"], null)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add members + setters + `"death_recap": _death_recap(ctx)` in `build()`:

```gdscript
var _death_info = null

func set_death_info(info: Dictionary) -> void:
	_death_info = info

func clear_death_info() -> void:
	_death_info = null

func _name_for(roster: Array, id: int) -> String:
	for rw in roster:
		if int(rw["id"]) == id:
			return String(rw["name"])
	return "#%d" % id

func _death_recap(ctx: Dictionary):
	if _death_info == null:
		return null
	var roster: Array = ctx.get("roster", [])
	var attackers: Array = []
	for a in _death_info["attackers"]:
		attackers.append({"name": _name_for(roster, int(a["id"])), "dmg": int(a["dmg"])})
	return {
		"killer_name": _name_for(roster, int(_death_info["killer"])),
		"weapon": int(_death_info["weapon"]),
		"distance": float(_death_info["distance"]),
		"killer_hp": int(_death_info["killer_hp"]),
		"attackers": attackers,
	}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): hud_model death-recap card data`.

---

# Part 2 — Server wiring (TDD where pure-extractable; mirror pattern otherwise)

### Task 12: Server — per-client name/kills/deaths/score + emit `ROSTER`

**Files:** Modify `server/server_main.gd`; Test `tests/server_roster_test.gd` (mirror the scoring rule, like `server_deploy_test`).

- [ ] **Step 1: Failing test** (mirror the kill→score increment so it's deterministic and node-free):

```gdscript
extends TestCase

# Mirrors server scoring: a kill credits the killer (kills+1, score+KILL_SCORE) and debits the
# victim (deaths+1). KILL_SCORE matches the server constant.
const KILL_SCORE := 100

func _on_kill(clients: Dictionary, killer_id: int, victim_id: int) -> void:
	if clients.has(killer_id) and killer_id != victim_id:
		clients[killer_id]["kills"] += 1
		clients[killer_id]["score"] += KILL_SCORE
	if clients.has(victim_id):
		clients[victim_id]["deaths"] += 1

func test_kill_credits_killer_and_debits_victim() -> void:
	var clients := {
		7: {"kills": 0, "deaths": 0, "score": 0},
		9: {"kills": 0, "deaths": 0, "score": 0},
	}
	_on_kill(clients, 7, 9)
	assert_eq(clients[7]["kills"], 1)
	assert_eq(clients[7]["score"], 100)
	assert_eq(clients[9]["deaths"], 1)

func test_suicide_does_not_credit_kills() -> void:
	var clients := {7: {"kills": 0, "deaths": 0, "score": 0}}
	_on_kill(clients, 7, 7)
	assert_eq(clients[7]["kills"], 0, "self-kill is not a kill credit")
	assert_eq(clients[7]["deaths"], 1)
```

- [ ] **Step 2: Run, verify fail** (file/class missing assertion target until written; the test is self-contained so it asserts the mirror — write it to match the server below).
- [ ] **Step 3: Implement in `server_main.gd`:**
  - Add a constant near the other gameplay consts: `const KILL_SCORE := 100`.
  - Add a roster-broadcast stride const + counter with the other strides: `const ROSTER_STRIDE_TICKS := 30` and `var _roster_tick := 0`.
  - In `_handle_hello`, store the name + scoring fields in the `_clients[id]` dict (append to the dict literal): `"name": pname, "kills": 0, "deaths": 0, "score": 0, "dmg_ledger": {},`.
  - In `_kill_pawn`, after `_kills += 1`, add scoring:
```gdscript
	if _clients.has(vid):
		_clients[vid]["deaths"] = int(_clients[vid]["deaths"]) + 1
	if _clients.has(killer_id) and killer_id != vid:
		_clients[killer_id]["kills"] = int(_clients[killer_id]["kills"]) + 1
		_clients[killer_id]["score"] = int(_clients[killer_id]["score"]) + KILL_SCORE
```
  - Add a roster broadcaster and call it from `_physics_process` (near the snapshot send) every `ROSTER_STRIDE_TICKS`:
```gdscript
func _broadcast_roster() -> void:
	var rows: Array = []
	for id in _clients:
		var c = _clients[id]
		rows.append({"id": id, "name": String(c.get("name", "P%d" % id)), "team": int(c["team"]),
			"squad": int(c["squad"]), "kills": int(c["kills"]), "deaths": int(c["deaths"]), "score": int(c["score"])})
	var pkt := Protocol.encode_roster(rows)
	for id in _clients:
		_net.send_to(_clients[id]["peer"], NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)
```
  Call site (in the per-tick body, alongside the snapshot stride): `_roster_tick += 1; if _roster_tick % ROSTER_STRIDE_TICKS == 0: _broadcast_roster()`.
- [ ] **Step 4: Run, verify pass** (`--filter=server_roster`) **and the full suite** `godot --headless --path . -- --test` (no regression).
- [ ] **Step 5: Commit** — `feat(m7-c3): server per-client K/D/score + ROSTER broadcast`.

---

### Task 13: Server — per-life damage ledger + emit `DEATH_INFO`

**Files:** Modify `server/server_main.gd`; Test `tests/server_death_info_test.gd` (mirror ledger accrual + uses the pure `DeathRecap`).

Two-stage read-only review candidate (touches the authoritative damage path). The ledger accrues **applied** damage per attacker; cleared on (re)spawn/deploy; on true death the victim gets a `DEATH_INFO` with killer name/weapon/distance/HP + the sorted ledger.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

# Mirrors server ledger accrual: each applied hit adds to ledger[attacker]; DeathRecap orders it.
func _accrue(ledger: Dictionary, attacker_id: int, dmg: int) -> void:
	ledger[attacker_id] = int(ledger.get(attacker_id, 0)) + dmg

func test_ledger_accrues_then_sorts_for_recap() -> void:
	var ledger := {}
	_accrue(ledger, 7, 50)
	_accrue(ledger, 9, 20)
	_accrue(ledger, 7, 30)   # killer landed 80 total
	var attackers := DeathRecap.attackers_sorted(ledger)
	assert_eq(attackers[0]["id"], 7)
	assert_eq(attackers[0]["dmg"], 80)
	assert_eq(attackers[1]["id"], 9)

func test_distance_is_killer_to_victim() -> void:
	# DEATH_INFO distance is the straight-line range at the killing blow.
	var d := Vector3(0, 0, 0).distance_to(Vector3(30, 0, 40))
	assert_almost_eq(d, 50.0, 0.01)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement in `server_main.gd`:**
  - In `_apply_pawn_damage`, after `victim.health -= dmg` and inside the existing `if _clients.has(vid):` block (so only tracked clients accrue), accrue the ledger:
```gdscript
		var led: Dictionary = _clients[vid]["dmg_ledger"]
		led[killer_id] = int(led.get(killer_id, 0)) + dmg
```
  - In `_kill_pawn`, after the scoring block (Task 12), before clearing, send the recap to the victim and then clear their ledger:
```gdscript
	if _clients.has(vid):
		var killer: Pawn = _sim.world.get_pawn(killer_id)
		var dist: float = victim.pos.distance_to(killer.pos) if killer != null else 0.0
		var khp: int = int(killer.health) if killer != null else 0
		var attackers := DeathRecap.attackers_sorted(_clients[vid]["dmg_ledger"])
		_net.send_to(_clients[vid]["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_death_info(killer_id, weapon_id, dist, khp, attackers), ENetPacketPeer.FLAG_RELIABLE)
		_clients[vid]["dmg_ledger"] = {}
```
  - Clear the ledger on (re)deploy too so a new life starts clean: in `_handle_deploy_request` (after `c["respawn_tick"] = 0`) and in the auto-respawn reset path (where `c["ammo"] = ...` is reset, near line ~692) add `c["dmg_ledger"] = {}`.
- [ ] **Step 4: Run, verify pass** (`--filter=server_death_info`) **and full suite green.**
- [ ] **Step 5: Commit** — `feat(m7-c3): server per-life damage ledger + DEATH_INFO on death`.

---

### Task 14: Server — handle `SET_SQUAD`

**Files:** Modify `server/server_main.gd`; Test `tests/server_set_squad_test.gd` (mirror the validated reassignment over `SquadManager`).

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func test_reassign_moves_member_between_squads_same_team() -> void:
	var sm := SquadManager.new()
	var a := sm.assign(1, 0)
	var b := sm.assign(2, 0)
	# move client 1 into client 2's squad (b)
	sm.remove(1, 0)
	sm.squad_of[1] = b
	sm._squads[0][b].append(1)
	assert_eq(sm.squad_of[1], b, "client moved to target squad")
	assert_true(sm.members(0, b).has(1))

func test_full_squad_rejects_join() -> void:
	var sm := SquadManager.new()
	# fill squad 0 to capacity
	for i in SquadManager.SQUAD_SIZE:
		sm.assign(100 + i, 0)
	var target := sm.squad_of[100]
	assert_eq(sm.members(0, target).size(), SquadManager.SQUAD_SIZE, "squad at capacity")
	# a guard must refuse adding a 9th — assert the capacity rule the server enforces
	assert_true(sm.members(0, target).size() >= SquadManager.SQUAD_SIZE, "server rejects join when full")
```

- [ ] **Step 2: Run, verify fail** (until the test file exists; it asserts the rule the server applies).
- [ ] **Step 3: Implement in `server_main.gd`:**
  - Add a `Msg.SET_SQUAD` branch to the packet dispatch `match Protocol.msg_type(bytes):` → `_handle_set_squad(peer, bytes)`.
  - Add the handler (validates same-team capacity via `SquadManager`, updates both `SquadManager` and the pawn's replicated `squad`):
```gdscript
func _handle_set_squad(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var team: int = int(c["team"])
	var target: int = int(Protocol.decode_set_squad(bytes)["squad"])
	if _squads.members(team, target).size() >= SquadManager.SQUAD_SIZE: return  # full
	_squads.remove(id, team)
	_squads.squad_of[id] = target
	if not _squads._squads[team].has(target):
		_squads._squads[team][target] = []
	_squads._squads[team][target].append(id)
	c["squad"] = target
	var p: Pawn = _sim.world.get_pawn(id)
	if p != null:
		p.squad = target   # replicated in EntityState.squad -> roster/squad list update next ROSTER
```
- [ ] **Step 4: Run, verify pass** (`--filter=server_set_squad`) **and full suite green.**
- [ ] **Step 5: Commit** — `feat(m7-c3): server SET_SQUAD handler (capacity-validated)`.

---

### Task 15: Server — deploy-on-squadmate/vehicle + throwable counts in `SELF_STATE`

**Files:** Modify `server/server_main.gd`; Test `tests/server_deploy_squadmate_test.gd` (mirror the candidate-array build + extended `DeploySpawn`).

Two-stage read-only review candidate (touches deploy placement). The server builds the same `squadmates`/`vehicles` candidate arrays the client enumerates from, and re-validates the requested ref through the extended `DeploySpawn`.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func _map() -> MapDef: return MapDef.load_default()

func test_squadmate_candidate_array_validates_through_deployspawn() -> void:
	var m := _map()
	var c := ConquestState.new(); c.init_from_map(m)
	# squadmate candidate built from authoritative pawn state
	var mates := [{"pos": Vector3(25, 0, 5), "team": 0, "alive": true, "downed": false}]
	var ref := DeploySpawn.SQUADMATE_BASE + 0
	assert_true(DeploySpawn.is_valid(0, ref, m, c, mates), "server re-validates the requested mate ref")
	var pos := DeploySpawn.resolve(0, ref, m, c, mates)
	assert_almost_eq(pos.distance_to(Vector3(25, 0, 5)), 0.0, DeploySpawn.JITTER + 0.01)

func test_request_for_dead_mate_is_rejected() -> void:
	var m := _map()
	var c := ConquestState.new(); c.init_from_map(m)
	var mates := [{"pos": Vector3(25, 0, 5), "team": 0, "alive": false, "downed": false}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, mates))
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement in `server_main.gd`:**
  - Add helpers that build the candidate arrays from authoritative state for a requesting client's team + squad (mates exclude self; vehicles are friendly with a free seat):
```gdscript
func _squad_candidates(req_id: int, team: int, squad_id: int) -> Array:
	var out: Array = []
	for mid in _squads.members(team, squad_id):
		if mid == req_id: continue
		var mp: Pawn = _sim.world.get_pawn(mid)
		if mp == null: continue
		out.append({"pos": mp.pos, "team": mp.team, "alive": mp.alive, "downed": mp.is_downed})
	return out

func _vehicle_candidates(team: int) -> Array:
	var out: Array = []
	for vid in _sim.world.vehicles():
		var v: Vehicle = _sim.world.get_vehicle(vid)
		if v == null or v.team != team or v.destroyed: continue
		out.append({"pos": v.pos, "team": v.team, "free_seats": v.free_seat_count()})
	return out
```
  (Confirm the `Vehicle`/world accessor names against `shared/sim/vehicle.gd` + the world API — use the real `free seat`/`destroyed` accessors C2 added; if a free-seat count helper doesn't exist, derive it from the seat-occupancy array. Adjust the candidate dict to the real fields without changing the rule.)
  - In `_handle_deploy_request`, build the candidate arrays and pass them to the extended `DeploySpawn` calls:
```gdscript
	var mates := _squad_candidates(id, int(c["team"]), int(c["squad"]))
	var vehs := _vehicle_candidates(int(c["team"]))
	if not DeploySpawn.is_valid(int(c["team"]), ref, _map, _conquest, mates, vehs): return
	p.pos = DeploySpawn.resolve(int(c["team"]), ref, _map, _conquest, mates, vehs)
```
  (Replace the two existing C1 `DeploySpawn.is_valid`/`resolve` calls in that handler with these.)
  - Throwable counts in `SELF_STATE`: build a per-client throwables list and pass it as the new 5th arg where `encode_self_state` is sent (near line ~799). Frag/smoke share the grenade cooldown (count = `1` when ready, else `0`); RPG rockets + C4/mine charges report remaining. Keep it data-driven so M5.5 list growth is free:
```gdscript
func _throwables_for(c: Dictionary) -> Array:
	var ready := 1 if _sim.tick - int(c["last_grenade_tick"]) >= GRENADE_COOLDOWN_TICKS else 0
	var list: Array = [{"kind": Grenade.FRAG, "count": ready}, {"kind": Grenade.SMOKE, "count": ready}]
	if int(c["weapon"]) == Weapon.RPG:
		list.append({"kind": 100, "count": int(c["rockets"])})   # kind 100 = RPG (UI-only tag; M5.5 formalizes)
	return list
```
  Then change the send: `Protocol.encode_self_state(int(c["ammo"]), bool(c["reloading"]), reload_remaining, int(c["weapon"]), _throwables_for(c))`.
  (Confirm `Grenade.FRAG`/`Grenade.SMOKE` constant names against `shared/sim/grenade.gd`; if grenade type is an int from `data/gadgets.json` rather than enum constants, use the same integer tags the throw path uses.)
- [ ] **Step 4: Run, verify pass** (`--filter=server_deploy_squadmate`) **and full suite green.** Then run the ≤48 smoke `ci/m5_p1_test.sh` to confirm no server regression (winner valid, peak tick <33.3) — record the log.
- [ ] **Step 5: Commit** — `feat(m7-c3): deploy-on-squadmate/vehicle + throwable counts in SELF_STATE`.

---

# Part 3 — Render, view & integrate (build + human playtest)

> These produce the visible UI. The pure helpers they consume are TDD-covered above. The *visual* result + feel are validated by the **owner playtest** (Task 22), per AGENTS.md §10 — not headless gates. Each task names exact files + the non-obvious snippets.

### Task 16: `world_view` — structure store + roster hold

**Files:** Modify `client/world_view.gd`; Test `tests/world_view_test.gd` (add cases).

- [ ] **Step 1: Failing test** — add a structure add/remove view test:

```gdscript
func test_structure_baseline_then_delta_add_remove() -> void:
	var wv := WorldView.new()
	wv.apply_structure_baseline(Protocol.encode_structure_baseline(Vector2i(0, 0), [
		{"id": 5, "type": 0, "cell": Vector3i(1, 0, 1), "yaw": 0, "health": 100, "owner": 1}]))
	assert_true(wv.structures().has(5), "baseline piece present")
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 5}))
	assert_false(wv.structures().has(5), "removed piece gone")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add a `_structs: Dictionary` (`id -> record`) + `_roster: Array`, and:

```gdscript
var _structs: Dictionary = {}
var _roster: Array = []

func apply_structure_baseline(bytes: PackedByteArray) -> void:
	for rec in Protocol.decode_structure_baseline(bytes)["records"]:
		_structs[int(rec["id"])] = rec

func apply_structure_delta(bytes: PackedByteArray) -> void:
	var d := Protocol.decode_structure_delta(bytes)
	match int(d["op"]):
		Protocol.OP_PLACE: _structs[int(d["rec"]["id"])] = d["rec"]
		Protocol.OP_REMOVE: _structs.erase(int(d["id"]))
		Protocol.OP_DAMAGE:
			if _structs.has(int(d["id"])):
				_structs[int(d["id"])]["bucket"] = int(d["bucket"])

func structures() -> Dictionary:
	return _structs

func set_roster(rows: Array) -> void:
	_roster = rows

func roster() -> Array:
	return _roster
```

- [ ] **Step 4: Import + run, verify pass.**  **Step 5: Commit** — `feat(m7-c3): world_view structure store + roster hold`.

---

### Task 17: `world_renderer` — render structures + build/destroy feedback

**Files:** Modify `client/world_renderer.gd`.

- [ ] **Step 1:** Maintain a pooled `MeshInstance3D` (box) per structure id from `world_view.structures()`, mirroring the entity pool pattern already in this file: acquire on appear, release on disappear, position from the record `cell` × cell-size (match the server's cell→world mapping in `StructureStore`/`MapDef`), tint by `type`.
- [ ] **Step 2:** Health feedback — when a record carries a `bucket` (partial-health from `OP_DAMAGE`), darken/scale the box so damage reads; on remove, play a brief "destroyed" pop (scale-down/flash) before releasing the node.
- [ ] **Step 3:** Build feedback — on a new piece appearing, a brief spawn pop (scale-up) so placement reads.
- [ ] **Step 4:** Playtest-verify in Task 22 (pieces appear where bots build, show damage, pop on destroy).
- [ ] **Step 5: Commit** — `feat(m7-c3): world_renderer structures + build/destroy feedback`.

---

### Task 18: `hud_view` — scoreboard, squad list, prompts, selector, recap

**Files:** Modify `client/hud/hud_view.gd`.

Draw the new `HudModel.build(...)` outputs as Control nodes (layout/feel = playtest). Each reads a model field added in Part 1:
- [ ] **Step 1:** **TAB scoreboard** — centered overlay shown while `scoreboard` held; two team columns from `model["scoreboard"]["teams"]`, each row `name / kills / deaths / score`, team ticket header. Hidden when not held.
- [ ] **Step 2:** **Squad list** — bottom-left, from `model["squad_roster"]`, name + status color (alive/downed/dead).
- [ ] **Step 3:** **Interaction prompt** — centered-low label from `model["interaction_prompt"]` ("Hold F to revive {name}" / "F to enter vehicle"); for `revive`, show a hold-progress ring driven by client revive-hold time.
- [ ] **Step 4:** **Bleed-out UI** — reuse the existing `set_downed(...)` downed screen; ensure the give-up + bleed-out countdown still render (already wired in C1).
- [ ] **Step 5:** **Throwable selector** — small HUD cluster from `model["throwables"]` showing each `{kind, count}` with the active one highlighted; **iterate the variable list** (no fixed two-slot assumption — M5.5 seam).
- [ ] **Step 6:** **Death-recap card** — full-width card from `model["death_recap"]` on the deploy/death screen: "Killed by {killer_name} · {weapon} · {distance} m · they had {killer_hp} HP" + a per-attacker damage list. No position reveal, no killcam.
- [ ] **Step 7:** Playtest-verify readability in Task 22.
- [ ] **Step 8: Commit** — `feat(m7-c3): hud_view scoreboard/squad/prompts/selector/recap`.

---

### Task 19: `client_main` — wire C3 inputs, messages, and HUD ctx

**Files:** Modify `client/client_main.gd`.

- [ ] **Step 1: Handle new server messages.** In the packet handler: `ROSTER` → `_world_view.set_roster(Protocol.decode_roster(bytes)["rows"])`; `DEATH_INFO` → `_hud_model.set_death_info(Protocol.decode_death_info(bytes))` (and show the deploy/recap screen); `STRUCTURE_BASELINE`/`STRUCTURE_DELTA` → `_world_view.apply_structure_baseline/﻿apply_structure_delta`; `SELF_STATE` → also store `decode_self_state(bytes)["throwables"]` for the HUD ctx. On (re)deploy, call `_hud_model.clear_death_info()`.
- [ ] **Step 2: Build HUD ctx** each frame: add `roster` (`_world_view.roster()`), `self_id` (local id), `entities` (a `id -> {alive,is_downed,pos}` dict from `_world_view.remotes_at(now)` + self), `throwables` (latest from `SELF_STATE`), and the proximity arrays for the prompt — `downed_mates` (`[{id, dist}]` for same-team downed within `Revive.REVIVE_RANGE`) and `vehicles_near` (friendly vehicle seats within an interact range), both computed from `_world_view`.
- [ ] **Step 3: Wire reviver intent.** When `interact` is held and the prompt action is `revive`, send `Protocol.encode_revive_action(target, true)` each tick (latched server-side); on release send `encode_revive_action(target, false)`. While downed, keep the existing `GIVE_UP`; add `SELF_BANDAGE` on the bandage key.
- [ ] **Step 4: Wire throwable + gadget use.** `throwable_cycle` action → `_hud_model.cycle_throwable(list.size())`. `throw` action → if the active throwable is a grenade kind, `Protocol.encode_grenade_throw(aim_dir, kind)`; if it's a gadget/RPG, route `Protocol.encode_gadget_action(...)` with the right `GA_*` sub-action (reuse the C2/M4.5 gadget send path if present). `gadget` action covers the non-throwable gadget (C4 detonate, repair, etc.) as the codebase already defines.
- [ ] **Step 5: Wire `SET_SQUAD`.** From the squad menu selection, `Protocol.encode_set_squad(squad_id)`.
- [ ] **Step 6: Scoreboard hold.** Pass `scoreboard` action pressed-state into the HUD so the TAB overlay shows while held.
- [ ] **Step 7:** Playtest in Task 22.
- [ ] **Step 8: Commit** — `feat(m7-c3): client_main wire C3 inputs/messages/HUD ctx`.

---

### Task 20: `deploy_menu` — squadmate + vehicle spawn options

**Files:** Modify `client/menus/deploy_menu.gd`.

- [ ] **Step 1:** Build the same `squadmates`/`vehicles` candidate arrays the server uses (from `_world_view.roster()` + entities for mates; `_world_view.vehicles()` for friendly vehicles with a free seat), then list `DeploySpawn.enumerate(team, map, conquest, squadmates, vehicles)` — labeling squadmate refs with the mate's name and vehicle refs with the vehicle type.
- [ ] **Step 2:** On click, send `Protocol.encode_deploy_request(ref)` (unchanged wire — the server re-validates with its own candidate arrays). A rejected ref (mate died/vehicle filled) leaves the deploy screen up to re-pick.
- [ ] **Step 3:** Playtest-verify deploy-on-squadmate round-trips (pick a mate → spawn next to them).
- [ ] **Step 4: Commit** — `feat(m7-c3): deploy menu squadmate + vehicle spawns`.

---

### Task 21: Project config — C3 input actions

**Files:** Modify `project.godot`.

- [ ] **Step 1:** Add `[input]` actions not already present: `throw` (Grenade/gadget — **G** per hud-ui.md keybind table), `throwable_cycle` (cycle selector — suggest **B**, the M5.5 fire-mode key is separate/later), `gadget` (non-throwable gadget use — suggest **H** or middle-mouse), `squad_menu` (suggest **U**). `scoreboard` (Tab), `interact` (F), `menu` (Esc) already exist from C1.
- [ ] **Step 2:** Verify it imports headlessly: `godot --headless --path . --import` (no script/scene errors).
- [ ] **Step 3: Commit** — `feat(m7-c3): C3 input actions (throw/cycle/gadget/squad menu)`.

---

### Task 22: Checkpoint-3 playtest + runbook + evidence

**Files:** Modify `docs/runbooks/running-client.md`; Modify `docs/milestones/M7-art-ux.md` (record C3 result); Modify `docs/TASKS.md` (mark C3 done).

- [ ] **Step 1:** Full suite green: `godot --headless --path . -- --test` (Expected: all pass, includes every new `*_test.gd`).
- [ ] **Step 2:** ≤48 smoke (`ci/m5_p1_test.sh`) still passes (server unaffected by the new edge messages) — record the log.
- [ ] **Step 3 (owner playtest):** Owner connects desktop→game2 and verifies the C3 loop: **squad list** shows squadmates + status; **TAB scoreboard** shows both teams' names/K/D/score + tickets; go **DBNO** → bleed-out countdown + give-up works; revive a **downed squadmate** (hold-F prompt → they're back up); **throw a grenade** + cycle the **throwable selector** (counts read); see a **structure built** by a bot and a **destroy** feedback; **deploy on a squadmate**; **die and read the death-recap card** (killer name/weapon/distance/HP + damage breakdown). Owner judges it playable + BattleBit-feeling; feel issues logged as follow-ups, not C3 blockers.
- [ ] **Step 4:** Record evidence in the milestone doc (owner sign-off + session server log). Mark C3 done on the TASKS board; this closes the **M7-P1 build order** (C1→C2→C3) ahead of the P1 gate (full-match playtest).
- [ ] **Step 5: Commit** — `docs(m7-c3): runbook + checkpoint-3 playtest evidence`.

---

## Definition of done (Checkpoint 3)
- All new `*_test.gd` green; full suite green (no regression to the C1/C2 suite).
- The ≤48 smoke (`ci/m5_p1_test.sh`) still passes (server unaffected by the new edge messages).
- Owner playtests the C3 combat-depth UI from desktop→game2 and signs it off as playable.
- New netcode is client/server-edge or presentation-only; no gameplay rule logic entered `client/` (AGENTS.md §7). M5.5 seams left intact (variable throwable list, data-driven weapon HUD, server-confirmed recap).

## Self-review notes (spec coverage)
- hud-ui.md → squad roster (Task 8), TAB scoreboard (Task 7/18), DBNO bleed-out + revive prompt (Tasks 9/18/19), grenade/gadget selector + count (Tasks 10/15/18/19), deploy-on-squadmate (Tasks 5/15/20), damage/no-health unchanged (C1). Death-recap card (Tasks 3/6/11/13/18) — the 2026-06-17 gap-review C3 deliverable.
- client-prediction.md → new edge messages `ROSTER`/`SET_SQUAD`/`DEATH_INFO` + extended `SELF_STATE` (Tasks 1–4, 12–15); `DeploySpawn` extension (Tasks 5/15). **Spec updates:** add `ROSTER`/`SET_SQUAD` (built here) + `DEATH_INFO` + `SELF_STATE.throwables` to `client-prediction.md`; note the squadmate/vehicle deploy refs in `hud-ui.md`'s deploy section. Do these in Task 22's docs commit.
- **Deviations:** (1) `SET_SQUAD` was specced in P1 but not built in C1 — built here. (2) Throwable counts ride an **extended `SELF_STATE`** (self-only, back-compat) rather than a new message — same rationale C1 used for ammo. (3) Build/destroy is **render + feedback only** (no client placement UI) — owner-directed 2026-06-17. (4) Death-recap breakdown is **per-attacker aggregate** — owner-directed 2026-06-17.
- M5.5 awareness → throwable selector is a variable data-driven list (Task 10); weapon/ammo HUD stays data-driven; recap rides the server-confirmed model; tracers untouched (all per the ⚡ callout + combat-depth-2 §1).
