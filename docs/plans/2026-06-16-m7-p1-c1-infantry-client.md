# M7 P1 Checkpoint 1 — Core Infantry Rendered Client — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the headless client stub into a *rendered, predicted first-person infantry client* you can deploy, move, shoot/reload (predicted ammo), die/respawn, and capture with — against bots on game2, on placeholder primitives, with the core HUD.

**Architecture:** The client stays a **view + predictor + intent-sender, never authority** (AGENTS.md §7). It predicts the local pawn/ammo by re-running the **shared** sim, interpolates remotes from snapshots, renders placeholder primitives behind swappable node interfaces, and sends intent. New netcode is added at the client/server edge only: `DEPLOY_REQUEST`, `DAMAGE_EVENT`, `SELF_STATE`, and a `HELLO.auto_deploy` flag. Spec: [`docs/specs/client-prediction.md`](../specs/client-prediction.md), [`docs/specs/hud-ui.md`](../specs/hud-ui.md). Renderer: [ADR-0005](../adr/0005-client-renderer.md).

**Tech Stack:** Godot 4.6 / GDScript. Forward+ (Vulkan) renderer with GL Compatibility fallback. Tests: `godot --headless --path . -- --test [--filter=<substr>]`, classes extend global `TestCase` (tests/*_test.gd).

**Scope (C1):** infantry only. **Out of C1:** vehicles (Checkpoint 2), DBNO/revive UI, gadgets/grenades/building UI, squad list, TAB scoreboard (Checkpoint 3), the art kit (P2). Reserve-ammo remains the sim's current "reload refills full mag, infinite reserve" — finite reserve is a later combat-depth item, not invented here.

## GDScript / Godot gotchas (every task)
- After adding any new `class_name` script, run **`godot --headless --path . --import`** once before tests (don't pipe `godot` through `tail`/`head` — redirect to a file if needed).
- GDScript 4.6 rejects `var x := <Dictionary access>` (Variant) — annotate the type explicitly; don't change logic.
- The harness **fails any test that runs zero assertions** (catches compile-error false-passes), so every test must assert.
- `git add -A` to include Godot `.uid` sidecars in commits. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Server logic bound to the `server_main` Node isn't headless-instantiable; follow the established pattern — **extract pure helpers into a class and unit-test those** (like `SpawnSelect`/`Revive`), or mirror the method in the test (like `server_dbno_test._apply`).

## File map

| File | Create/Modify | Responsibility |
|---|---|---|
| `shared/sim/deploy_spawn.gd` | Create | Pure: enumerate valid spawn refs (HQ + owned points) + resolve/validate a ref → pos. Used by server (validate+place) and client deploy menu (list). |
| `shared/net/protocol.gd` | Modify | Add `DEPLOY_REQUEST`, `DAMAGE_EVENT`, `SELF_STATE` messages + `HELLO.auto_deploy` flag. |
| `shared/net/input_command.gd` | (unchanged) | Already encodes move/look/buttons. |
| `client/prediction.gd` | Modify | Add full-command record + pitch reconcile (additive; keeps existing API/tests green). |
| `client/weapon_predictor.gd` | Create | Predict mag/reload mirroring server fire-gating; reconcile to `SELF_STATE`. |
| `client/world_view.gd` | Create | Apply snapshots, hold interpolated remotes, expose read-only view. |
| `client/input_map.gd` | Create | Pure key-state → `InputCommand` button bitmask. |
| `client/stance_pose.gd` | Create | Pure (stance/lean/downed/climbing) → render pose (capsule height/offset/tilt). |
| `client/settings.gd` | Create | Load/save sensitivity/FOV/volume/invert/renderer to a config file. |
| `client/hud/hud_model.gd` | Create | Pure HUD data: ammo, compass+objectives, tickets/capture, killfeed, damage arcs/vignette. |
| `client/hud/hud_view.gd` | Create | Draw `hud_model` (Control nodes). Playtest-validated. |
| `client/input_controller.gd` | Create | Godot `Input` → `InputCommand` (mouse look + keys) using `input_map` + settings. |
| `client/world_renderer.gd` | Create | 3D scene: world from `MapDef`, pooled entity nodes (via `stance_pose`), camera, viewmodel, tracer/muzzle. Playtest-validated. |
| `client/menus/deploy_menu.gd` | Create | Spawn-select screen; emits `DEPLOY_REQUEST` over `DeploySpawn` options. |
| `client/menus/settings_menu.gd` | Create | Settings screen over `settings.gd`. |
| `client/client_main.gd` | Modify | Composition root: wire net/predict/render/HUD/menus per frame. |
| `client/client.tscn` | Create | Client scene root (Node3D world + Camera + HUD CanvasLayer). |
| `server/server_main.gd` | Modify | Honor `auto_deploy`, handle `DEPLOY_REQUEST`, emit `DAMAGE_EVENT`, send `SELF_STATE`. |
| `bots/bot_driver.gd` | Modify | Send `HELLO.auto_deploy=true` (keep auto-deploy; one-line, preserves the fleet). |
| `project.godot` | Modify | Renderer method + fallback; input actions; client main scene. |
| `tests/*_test.gd` | Create | One test file per testable unit below. |

---

# Part 1 — Deterministic foundation (TDD)

### Task 1: `DeploySpawn` — enumerate + resolve spawn refs

**Files:**
- Create: `shared/sim/deploy_spawn.gd`
- Test: `tests/deploy_spawn_test.gd`

Spawn-ref encoding (C1): `0` = team base/HQ; `1..N` = capture-point index `i-1` (valid only if owned by the requesting team). Squadmate/vehicle refs are Checkpoint 3.

- [ ] **Step 1: Write the failing test**

```gdscript
extends TestCase

func _map() -> MapDef:
	return MapDef.load_default()

func _conquest(owner0_pt: int) -> ConquestState:
	var c := ConquestState.new()
	c.init_from_map(_map())
	if owner0_pt >= 0:
		c.points[owner0_pt]["owner"] = 0
	return c

func test_hq_ref_is_always_valid_and_resolves_to_base() -> void:
	var m := _map()
	var c := _conquest(-1)
	assert_true(DeploySpawn.is_valid(0, 0, m, c), "HQ ref valid for team 0")
	var pos := DeploySpawn.resolve(0, 0, m, c)
	var base := m.base_for(0)
	assert_almost_eq(pos.x, base["pos"].x, 12.0, "HQ resolves near team base (within jitter)")

func test_owned_point_ref_valid_enemy_point_invalid() -> void:
	var m := _map()
	var c := _conquest(0)   # point index 0 owned by team 0
	assert_true(DeploySpawn.is_valid(0, 1, m, c), "owned point ref valid")
	assert_false(DeploySpawn.is_valid(1, 1, m, c), "team 1 cannot spawn on a team-0 point")

func test_enumerate_lists_hq_plus_owned_points() -> void:
	var m := _map()
	var c := _conquest(0)
	var refs := DeploySpawn.enumerate(0, m, c)
	assert_true(refs.has(0), "HQ always offered")
	assert_true(refs.has(1), "owned point offered")
	assert_false(refs.has(2), "non-owned point not offered")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=deploy_spawn`
Expected: FAIL ("DeploySpawn not declared" / class missing).

- [ ] **Step 3: Implement**

```gdscript
class_name DeploySpawn
extends Object
## Pure spawn-ref resolution for human deploy. ref 0 = team base/HQ; ref i>=1 = capture point
## index (i-1), valid only if owned by the team. Server validates+places; client enumerates for
## the deploy screen. Position uses the same jitter as SpawnSelect to avoid stacking.

const JITTER := 6.0

static func enumerate(team: int, map: MapDef, conquest: ConquestState) -> Array:
	var refs: Array = [0]
	for i in conquest.points.size():
		if int(conquest.points[i]["owner"]) == team:
			refs.append(i + 1)
	return refs

static func is_valid(team: int, ref: int, map: MapDef, conquest: ConquestState) -> bool:
	if ref == 0:
		return not map.base_for(team).is_empty()
	var idx := ref - 1
	if idx < 0 or idx >= conquest.points.size():
		return false
	return int(conquest.points[idx]["owner"]) == team

static func resolve(team: int, ref: int, map: MapDef, conquest: ConquestState) -> Vector3:
	var src := Vector3.ZERO
	if ref == 0:
		var base := map.base_for(team)
		src = base["pos"] if not base.is_empty() else Vector3.ZERO
	else:
		src = conquest.points[ref - 1]["pos"]
	return Vector3(src.x + randf_range(-JITTER, JITTER), 0.0, src.z + randf_range(-JITTER, JITTER))
```

Confirm `MapDef.load_default()` / `ConquestState.init_from_map()` names against `shared/sim/map_def.gd` + `conquest.gd`; if they differ, use the real constructors (the test must build a real map+conquest the same way `conquest_test.gd` does).

- [ ] **Step 4: Import + run to verify pass**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=deploy_spawn`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(m7-c1): DeploySpawn pure spawn-ref enumerate/validate/resolve

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Protocol `DEPLOY_REQUEST`

**Files:**
- Modify: `shared/net/protocol.gd` (add to `Msg` enum + encode/decode)
- Test: `tests/protocol_test.gd` (add cases)

- [ ] **Step 1: Add failing test cases** to `tests/protocol_test.gd`:

```gdscript
func test_deploy_request_roundtrip() -> void:
	var b := Protocol.encode_deploy_request(3)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.DEPLOY_REQUEST)
	assert_eq(Protocol.decode_deploy_request(b)["spawn_ref"], 3)
```

- [ ] **Step 2: Run to verify fail**

Run: `godot --headless --path . -- --test --filter=protocol`
Expected: FAIL ("DEPLOY_REQUEST not a valid member" / encode missing).

- [ ] **Step 3: Implement** — add to the `Msg` enum (next free value `20`) and add functions:

```gdscript
	DEPLOY_REQUEST = 20,    ## client -> server: deploy me at spawn_ref (see DeploySpawn)
```
```gdscript
static func encode_deploy_request(spawn_ref: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DEPLOY_REQUEST)
	buf.put_u8(spawn_ref & 0xFF)
	return buf.data_array

static func decode_deploy_request(bytes: PackedByteArray) -> Dictionary:
	return {"spawn_ref": body_reader(bytes).get_u8()}
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(m7-c1): DEPLOY_REQUEST wire message`.

---

### Task 3: Protocol `DAMAGE_EVENT`

**Files:** Modify `shared/net/protocol.gd`; Test `tests/protocol_test.gd`.

Carries a **world-space bearing toward the damage source** (u16 angle) + amount (u8). The HUD rotates it relative to the local yaw.

- [ ] **Step 1: Failing test**

```gdscript
func test_damage_event_roundtrip() -> void:
	var b := Protocol.encode_damage_event(1.2, 25)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.DAMAGE_EVENT)
	var d := Protocol.decode_damage_event(b)
	assert_almost_eq(d["bearing"], 1.2, 0.01, "world bearing preserved")
	assert_eq(d["amount"], 25)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — enum `DAMAGE_EVENT = 21` and:

```gdscript
static func encode_damage_event(bearing: float, amount: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DAMAGE_EVENT)
	buf.put_u16(Quantize.enc_angle(bearing))
	buf.put_u8(clampi(amount, 0, 255))
	return buf.data_array

static func decode_damage_event(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"bearing": Quantize.dec_angle(r.get_u16()), "amount": r.get_u8()}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): DAMAGE_EVENT wire message`.

---

### Task 4: Protocol `SELF_STATE`

**Files:** Modify `shared/net/protocol.gd`; Test `tests/protocol_test.gd`.

Authoritative own-weapon state for ammo reconciliation: `mag` (u8), `reloading` (u8), `reload_remaining` ticks (u16), `weapon` (u8).

- [ ] **Step 1: Failing test**

```gdscript
func test_self_state_roundtrip() -> void:
	var b := Protocol.encode_self_state(17, true, 40, Weapon.AR)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.SELF_STATE)
	var d := Protocol.decode_self_state(b)
	assert_eq(d["mag"], 17)
	assert_true(d["reloading"])
	assert_eq(d["reload_remaining"], 40)
	assert_eq(d["weapon"], Weapon.AR)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — enum `SELF_STATE = 22` and:

```gdscript
static func encode_self_state(mag: int, reloading: bool, reload_remaining: int, weapon: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SELF_STATE)
	buf.put_u8(clampi(mag, 0, 255))
	buf.put_u8(1 if reloading else 0)
	buf.put_u16(clampi(reload_remaining, 0, 65535))
	buf.put_u8(weapon & 0xFF)
	return buf.data_array

static func decode_self_state(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"mag": r.get_u8(), "reloading": r.get_u8() == 1, "reload_remaining": r.get_u16(), "weapon": r.get_u8()}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): SELF_STATE wire message`.

---

### Task 5: `HELLO.auto_deploy` flag

**Files:** Modify `shared/net/protocol.gd` (`encode_hello`); Test `tests/protocol_test.gd`.

Default `true` (back-compat: bots/old clients keep auto-deploy). The rendered client sends `false`.

- [ ] **Step 1: Failing test**

```gdscript
func test_hello_carries_auto_deploy_default_true() -> void:
	var b := Protocol.encode_hello("Bot")
	var r := Protocol.body_reader(b)
	assert_eq(r.get_u16(), Protocol.VERSION)
	assert_eq(r.get_utf8_string(), "Bot")
	assert_eq(r.get_u8(), 1, "auto_deploy defaults to 1 (true)")

func test_hello_auto_deploy_false_for_rendered_client() -> void:
	var b := Protocol.encode_hello("Player", false)
	var r := Protocol.body_reader(b)
	r.get_u16(); r.get_utf8_string()
	assert_eq(r.get_u8(), 0, "rendered client requests manual deploy")
```

- [ ] **Step 2: Run, verify fail** (current `encode_hello` writes no trailing byte).
- [ ] **Step 3: Implement** — change `encode_hello`:

```gdscript
static func encode_hello(player_name: String, auto_deploy: bool = true) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.HELLO)
	buf.put_u16(VERSION)
	buf.put_utf8_string(player_name)
	buf.put_u8(1 if auto_deploy else 0)
	return buf.data_array
```

The server reads it in Task 16 (`_handle_hello` appends `var auto := r.get_u8()` after the name; guard with `r.get_available_bytes() > 0` so a pre-flag HELLO still parses as auto-deploy).

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): HELLO.auto_deploy flag (default true)`.

---

### Task 6: `WeaponPredictor` — predicted mag/reload + reconcile

**Files:** Create `client/weapon_predictor.gd`; Test `tests/weapon_predictor_test.gd`.

Mirrors the server fire-gating from `server_main._resolve_fires` so the predicted mag matches authoritative deterministically. Time is tracked in **ticks** (DT-based) to match the predictor loop.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func _wp() -> WeaponPredictor:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)   # mag_size 30
	return wp

func test_fire_decrements_mag_respecting_cadence() -> void:
	var wp := _wp()
	# one fire on tick 0 consumes a round; a fire on the very next tick is gated by cadence.
	assert_true(wp.step(0, true, false, false), "first shot fires")
	assert_eq(wp.mag, 29)
	assert_false(wp.step(1, true, false, false), "next-tick shot gated by RPM cadence")
	assert_eq(wp.mag, 29)

func test_no_fire_while_sprinting_or_empty() -> void:
	var wp := _wp()
	assert_false(wp.step(0, true, true, false), "sprint blocks fire")
	wp.mag = 0
	assert_false(wp.step(100, true, false, false), "empty mag blocks fire")

func test_reload_refills_after_duration() -> void:
	var wp := _wp(); wp.mag = 5
	wp.begin_reload(0)
	assert_true(wp.reloading)
	var done := int(round(Weapon.get_def(Weapon.AR)["reload_secs"] / SimLoop.DT))
	wp.step(done, false, false, false)   # tick at/after completion
	assert_false(wp.reloading)
	assert_eq(wp.mag, Weapon.get_def(Weapon.AR)["mag_size"])

func test_reconcile_snaps_to_authoritative() -> void:
	var wp := _wp(); wp.mag = 29
	wp.reconcile(20, false, 0)
	assert_eq(wp.mag, 20, "predicted mag snaps to SELF_STATE mag")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement**

```gdscript
class_name WeaponPredictor
extends RefCounted
## Client-side predicted weapon state (mag + reload) mirroring server _resolve_fires gating, so
## the HUD ammo matches authority deterministically. reconcile() snaps to SELF_STATE. C1: mag only
## (sim reload refills full mag; finite reserve is a later combat-depth item).

var weapon: int = Weapon.AR
var mag: int = 30
var reloading: bool = false
var _reload_done_tick: int = 0
var _last_fire_tick: int = -100000

func set_weapon(w: int) -> void:
	weapon = w
	mag = int(Weapon.get_def(w)["mag_size"])

## Returns true if a shot fired this tick. Mirrors server gating (cadence, mag, reload, sprint).
func step(tick: int, firing: bool, sprinting: bool, drop_shoot: bool) -> bool:
	if reloading and tick >= _reload_done_tick:
		reloading = false
		mag = int(Weapon.get_def(weapon)["mag_size"])
	if not firing or reloading or mag <= 0 or sprinting or drop_shoot:
		return false
	var interval_ticks := Weapon.fire_interval(weapon) / SimLoop.DT
	if float(tick - _last_fire_tick) < interval_ticks:
		return false
	_last_fire_tick = tick
	mag -= 1
	return true

func begin_reload(tick: int) -> void:
	if reloading or mag >= int(Weapon.get_def(weapon)["mag_size"]):
		return
	reloading = true
	_reload_done_tick = tick + int(round(float(Weapon.get_def(weapon)["reload_secs"]) / SimLoop.DT))

func reload_remaining(tick: int) -> int:
	return maxi(0, _reload_done_tick - tick) if reloading else 0

func reconcile(auth_mag: int, auth_reloading: bool, auth_reload_remaining: int) -> void:
	mag = auth_mag
	reloading = auth_reloading
```

- [ ] **Step 4: Import + run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): WeaponPredictor (predicted mag/reload + reconcile)`.

---

### Task 7: Extend `Prediction` for full command + pitch reconcile

**Files:** Modify `client/prediction.gd`; Test `tests/prediction_test.gd` (add cases; existing cases must stay green).

Additive: keep `record_input`/`reconcile` (existing tests use them); add `record_cmd(tick, cmd)` and `reconcile_full(pos, yaw, pitch, last_input_tick)`.

- [ ] **Step 1: Add failing tests**

```gdscript
func test_record_cmd_steps_with_buttons_and_pitch() -> void:
	var pred := Prediction.new()
	pred.record_cmd(1, {"move_x": 0.0, "move_y": 1.0, "yaw": 0.5, "pitch": -0.2,
		"buttons": InputCommand.BTN_CROUCH})
	assert_eq(pred.predicted.stance, Stance.CROUCH, "crouch button applied via shared Pawn.step")
	assert_almost_eq(pred.predicted.pitch, -0.2, 0.001)

func test_reconcile_full_sets_pitch_and_replays() -> void:
	var pred := Prediction.new()
	pred.record_cmd(1, {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.0, "buttons": 0})
	pred.record_cmd(2, {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.3, "buttons": 0})
	pred.reconcile_full(Vector3(0.1, 0, 0), 0.0, 0.0, 1)
	assert_eq(pred.pending.size(), 1, "tick 2 replayed")
	assert_almost_eq(pred.predicted.pitch, 0.3, 0.001, "pitch from replayed cmd")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — append to `prediction.gd`:

```gdscript
func record_cmd(client_tick: int, cmd: Dictionary) -> void:
	predicted.step(SimLoop.DT, cmd)
	pending.append({"tick": client_tick, "cmd": cmd})

func reconcile_full(auth_pos: Vector3, auth_yaw: float, auth_pitch: float, last_input_tick: int) -> void:
	var kept: Array = []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	predicted.pitch = auth_pitch
	for inp in pending:
		if inp.has("cmd"):
			predicted.step(SimLoop.DT, inp["cmd"])
		else:
			predicted.step(SimLoop.DT, {"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]})
```

(`pending` now holds either old `{tick,move_x,move_y,yaw}` or new `{tick,cmd}` entries; both `reconcile` paths handle both. Keep the existing `reconcile` for the old-format tests.)

- [ ] **Step 4: Run, verify pass (old + new).**  **Step 5: Commit** — `feat(m7-c1): full-command prediction + pitch reconcile`.

---

### Task 8: `hud_model` — ammo + reload

**Files:** Create `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

`hud_model` is a pure builder of a data dict from inputs (no nodes). C1 fields grow across Tasks 8–12.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func test_ammo_from_weapon_predictor() -> void:
	var wp := WeaponPredictor.new(); wp.set_weapon(Weapon.AR); wp.mag = 7
	var m := HudModel.new()
	var out := m.build({"weapon_predictor": wp, "tick": 0})
	assert_eq(out["ammo"]["mag"], 7)
	assert_false(out["ammo"]["reloading"])
	assert_true(out["ammo"]["low"], "7 of 30 is low ammo")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement**

```gdscript
class_name HudModel
extends RefCounted
## Pure HUD data builder. build(ctx) returns a plain Dictionary the view draws. No nodes, no
## drawing — headless-testable. ctx keys are filled in by client_main each frame.

const LOW_AMMO_FRAC := 0.34

func build(ctx: Dictionary) -> Dictionary:
	return {"ammo": _ammo(ctx)}

func _ammo(ctx: Dictionary) -> Dictionary:
	var wp: WeaponPredictor = ctx.get("weapon_predictor")
	if wp == null:
		return {"mag": 0, "reloading": false, "low": false}
	var mag_size := int(Weapon.get_def(wp.weapon)["mag_size"])
	return {
		"mag": wp.mag,
		"reloading": wp.reloading,
		"reload_remaining": wp.reload_remaining(int(ctx.get("tick", 0))),
		"low": wp.mag <= int(ceil(mag_size * LOW_AMMO_FRAC)),
	}
```

- [ ] **Step 4: Import + run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): hud_model ammo`.

---

### Task 9: `hud_model` — compass bearing + objective markers

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

Compass shows the local heading and the **relative** bearing of each objective (so flags appear on the strip). World yaw 0 = +Z (forward); bearing increases clockwise. Use `atan2(dx, dz)` for world bearing to a target, then subtract local yaw and wrap to (-π, π].

- [ ] **Step 1: Failing test**

```gdscript
func test_compass_relative_bearing_to_objective() -> void:
	var m := HudModel.new()
	# local at origin facing +Z (yaw 0); objective due +X (right) -> +90 deg relative.
	var out := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0,
		"objectives": [{"pos": Vector3(10, 0, 0), "owner": -1}], "tick": 0})
	assert_almost_eq(rad_to_deg(out["compass"]["heading"]), 0.0, 0.5)
	assert_almost_eq(rad_to_deg(out["compass"]["markers"][0]["rel_bearing"]), 90.0, 1.0)

func test_compass_bearing_wraps_behind() -> void:
	var m := HudModel.new()
	# objective due -Z (behind) -> ±180 deg.
	var out := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0,
		"objectives": [{"pos": Vector3(0, 0, -10), "owner": -1}], "tick": 0})
	assert_almost_eq(absf(rad_to_deg(out["compass"]["markers"][0]["rel_bearing"])), 180.0, 1.0)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add to `build`'s return `"compass": _compass(ctx)` and:

```gdscript
func _compass(ctx: Dictionary) -> Dictionary:
	var yaw := float(ctx.get("self_yaw", 0.0))
	var sp: Vector3 = ctx.get("self_pos", Vector3.ZERO)
	var markers: Array = []
	for o in ctx.get("objectives", []):
		var d: Vector3 = o["pos"] - sp
		var world_bearing := atan2(d.x, d.z)
		markers.append({"rel_bearing": wrapf(world_bearing - yaw, -PI, PI), "owner": int(o["owner"])})
	return {"heading": wrapf(yaw, -PI, PI), "markers": markers}
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): hud_model compass + objective markers`.

---

### Task 10: `hud_model` — tickets + capture status

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

From decoded `MATCH_STATE` (`{points:[{owner,attacker,cap}], tickets:[t0,t1], ...}`). Capture-progress is reported for the point the local pawn currently stands in (within a fixed radius); otherwise null.

- [ ] **Step 1: Failing test**

```gdscript
func test_tickets_passthrough_and_capture_when_on_point() -> void:
	var m := HudModel.new()
	var ms := {"points": [{"owner": -1, "attacker": 0, "cap": 0.4}], "tickets": [120, 95]}
	var out := m.build({"match_state": ms, "self_pos": Vector3(5, 0, 5),
		"point_positions": [Vector3(6, 0, 6)], "capture_radius": 8.0, "tick": 0})
	assert_eq(out["tickets"], [120, 95])
	assert_almost_eq(out["capture"]["cap"], 0.4, 0.001, "on the point -> progress shown")

func test_no_capture_when_off_point() -> void:
	var m := HudModel.new()
	var ms := {"points": [{"owner": -1, "attacker": 0, "cap": 0.4}], "tickets": [120, 95]}
	var out := m.build({"match_state": ms, "self_pos": Vector3(500, 0, 500),
		"point_positions": [Vector3(6, 0, 6)], "capture_radius": 8.0, "tick": 0})
	assert_eq(out["capture"], null, "off point -> no capture readout")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add `"tickets"` + `"capture"` to `build`:

```gdscript
func _tickets(ctx: Dictionary) -> Array:
	var ms: Dictionary = ctx.get("match_state", {})
	return ms.get("tickets", [0, 0])

func _capture(ctx: Dictionary):
	var ms: Dictionary = ctx.get("match_state", {})
	var pts: Array = ms.get("points", [])
	var positions: Array = ctx.get("point_positions", [])
	var sp: Vector3 = ctx.get("self_pos", Vector3.ZERO)
	var radius := float(ctx.get("capture_radius", 8.0))
	for i in mini(pts.size(), positions.size()):
		if sp.distance_to(positions[i]) <= radius:
			return {"index": i, "cap": float(pts[i]["cap"]), "owner": int(pts[i]["owner"]),
				"attacker": int(pts[i]["attacker"])}
	return null
```

Wire both into `build`'s return dict (`"tickets": _tickets(ctx), "capture": _capture(ctx)`).

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): hud_model tickets + capture status`.

---

### Task 11: `hud_model` — killfeed

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

The model owns a decaying killfeed list; `push_kill()` adds an entry, `build()` drops entries older than `KILLFEED_TTL` seconds (driven by a `now` seconds value in ctx).

- [ ] **Step 1: Failing test**

```gdscript
func test_killfeed_entries_decay_out() -> void:
	var m := HudModel.new()
	m.push_kill({"killer": 1, "victim": 2, "headshot": true, "weapon": Weapon.AR}, 10.0)
	var out := m.build({"now": 10.5, "tick": 0})
	assert_eq(out["killfeed"].size(), 1, "fresh entry present")
	assert_true(out["killfeed"][0]["headshot"])
	var out2 := m.build({"now": 10.0 + HudModel.KILLFEED_TTL + 0.1, "tick": 0})
	assert_eq(out2["killfeed"].size(), 0, "expired entry dropped")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add member + methods, wire `"killfeed"` into `build`:

```gdscript
const KILLFEED_TTL := 6.0
var _killfeed: Array = []   # [{killer,victim,headshot,weapon,t}]

func push_kill(ev: Dictionary, now: float) -> void:
	_killfeed.append({"killer": int(ev["killer"]), "victim": int(ev["victim"]),
		"headshot": bool(ev["headshot"]), "weapon": int(ev["weapon"]), "t": now})

func _killfeed_current(ctx: Dictionary) -> Array:
	var now := float(ctx.get("now", 0.0))
	var kept: Array = []
	for e in _killfeed:
		if now - e["t"] <= KILLFEED_TTL:
			kept.append(e)
	_killfeed = kept
	return kept
```

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): hud_model killfeed with decay`.

---

### Task 12: `hud_model` — damage arcs + vignette

**Files:** Modify `client/hud/hud_model.gd`; Test `tests/hud_model_test.gd`.

`push_damage(world_bearing, amount, now)` records an arc; `build()` returns arcs **relative to local yaw** with a fade factor, plus an aggregate `vignette` intensity that decays.

- [ ] **Step 1: Failing test**

```gdscript
func test_damage_arc_relative_and_fades() -> void:
	var m := HudModel.new()
	# damage from due-south in world (bearing PI); local facing +Z (yaw 0) -> arc at 180 deg.
	m.push_damage(PI, 25, 10.0)
	var out := m.build({"self_yaw": 0.0, "now": 10.0, "tick": 0})
	assert_eq(out["damage_arcs"].size(), 1)
	assert_almost_eq(absf(rad_to_deg(out["damage_arcs"][0]["rel_bearing"])), 180.0, 1.0)
	assert_true(out["vignette"] > 0.0, "fresh damage raises vignette")
	var faded := m.build({"self_yaw": 0.0, "now": 10.0 + HudModel.DAMAGE_TTL + 0.1, "tick": 0})
	assert_eq(faded["damage_arcs"].size(), 0, "arc expired")
	assert_almost_eq(faded["vignette"], 0.0, 0.01, "vignette decayed to ~0")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add members/methods, wire `"damage_arcs"` + `"vignette"` into `build`:

```gdscript
const DAMAGE_TTL := 1.5
var _damages: Array = []   # [{bearing,amount,t}]

func push_damage(world_bearing: float, amount: int, now: float) -> void:
	_damages.append({"bearing": world_bearing, "amount": amount, "t": now})

func _damage(ctx: Dictionary) -> Dictionary:
	var now := float(ctx.get("now", 0.0))
	var yaw := float(ctx.get("self_yaw", 0.0))
	var arcs: Array = []
	var vignette := 0.0
	var kept: Array = []
	for d in _damages:
		var age := now - d["t"]
		if age > DAMAGE_TTL:
			continue
		kept.append(d)
		var fade := 1.0 - age / DAMAGE_TTL
		arcs.append({"rel_bearing": wrapf(d["bearing"] - yaw, -PI, PI), "fade": fade})
		vignette = maxf(vignette, fade * clampf(float(d["amount"]) / 50.0, 0.0, 1.0))
	_damages = kept
	return {"arcs": arcs, "vignette": vignette}
```

(`build` calls `_damage(ctx)` once and splits into `"damage_arcs"` + `"vignette"`.)

- [ ] **Step 4: Run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): hud_model damage arcs + vignette`.

---

### Task 13: `input_map` — key state → button bitmask (pure)

**Files:** Create `client/input_map.gd`; Test `tests/input_map_test.gd`.

Pure function from a set of pressed Godot action names (strings) to the `InputCommand` bitmask, so the mapping is testable without the `Input` singleton.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func test_maps_actions_to_button_bits() -> void:
	var bits := InputMap2.buttons_from({"sprint": true, "jump": true, "fire": true})
	assert_true(bits & InputCommand.BTN_SPRINT)
	assert_true(bits & InputCommand.BTN_JUMP)
	assert_true(bits & InputCommand.BTN_FIRE)
	assert_false(bits & InputCommand.BTN_PRONE)

func test_empty_is_zero() -> void:
	assert_eq(InputMap2.buttons_from({}), 0)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** (class named `InputMap2` to avoid clashing with Godot's `InputMap` singleton):

```gdscript
class_name InputMap2
extends Object
## Pure mapping from pressed action names to the InputCommand button bitmask. Kept pure so the
## mapping is unit-testable without the Input singleton (input_controller reads real Input).

const _BITS := {
	"jump": InputCommand.BTN_JUMP, "crouch": InputCommand.BTN_CROUCH,
	"prone": InputCommand.BTN_PRONE, "sprint": InputCommand.BTN_SPRINT,
	"lean_left": InputCommand.BTN_LEAN_L, "lean_right": InputCommand.BTN_LEAN_R,
	"fire": InputCommand.BTN_FIRE, "reload": InputCommand.BTN_RELOAD,
}

static func buttons_from(pressed: Dictionary) -> int:
	var b := 0
	for action in _BITS:
		if pressed.get(action, false):
			b |= int(_BITS[action])
	return b
```

- [ ] **Step 4: Import + run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): input_map pure key->button mapping`.

---

### Task 14: `stance_pose` — render pose mapping (pure)

**Files:** Create `client/stance_pose.gd`; Test `tests/stance_pose_test.gd`.

Maps replicated state → capsule render pose (height, y-offset, lean tilt) so the renderer stays dumb. Uses `Stance.eye_height`/heights already in `shared/sim/stance.gd`.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func test_prone_is_shorter_than_stand() -> void:
	var stand := StancePose.of(Stance.STAND, Stance.LEAN_NONE, false, false)
	var prone := StancePose.of(Stance.PRONE, Stance.LEAN_NONE, false, false)
	assert_true(prone["height"] < stand["height"], "prone capsule is shorter")

func test_lean_applies_tilt_sign() -> void:
	var l := StancePose.of(Stance.STAND, Stance.LEAN_LEFT, false, false)
	var r := StancePose.of(Stance.STAND, Stance.LEAN_RIGHT, false, false)
	assert_true(l["tilt"] > 0.0 and r["tilt"] < 0.0, "lean tilts opposite directions")

func test_downed_is_prone_height() -> void:
	var d := StancePose.of(Stance.STAND, Stance.LEAN_NONE, true, false)
	var prone := StancePose.of(Stance.PRONE, Stance.LEAN_NONE, false, false)
	assert_almost_eq(d["height"], prone["height"], 0.01, "downed renders prone")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement**

```gdscript
class_name StancePose
extends Object
## Pure: replicated entity state -> placeholder-capsule render pose. The renderer applies this; no
## gameplay logic. Heights track Stance so the capsule matches the sim's stance.

const LEAN_TILT := 0.18   # radians

static func of(stance: int, lean: int, downed: bool, climbing: bool) -> Dictionary:
	var s := Stance.PRONE if downed else stance
	var h := Stance.height(s) if Stance.has_method("height") else _fallback_height(s)
	var tilt := 0.0
	if lean == Stance.LEAN_LEFT: tilt = LEAN_TILT
	elif lean == Stance.LEAN_RIGHT: tilt = -LEAN_TILT
	return {"height": h, "y_offset": h * 0.5, "tilt": tilt, "climbing": climbing}

static func _fallback_height(s: int) -> float:
	match s:
		Stance.PRONE: return 0.6
		Stance.CROUCH: return 1.2
		_: return 1.8
```

Confirm against `shared/sim/stance.gd`: if it exposes capsule heights use them; otherwise the fallback stands. Adjust the test's exact numbers to the real `Stance` API if needed (the *relationships* asserted — prone<stand, lean sign, downed==prone — are the contract).

- [ ] **Step 4: Import + run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): stance_pose render-pose mapping`.

---

### Task 15: `settings` — load/save round-trip

**Files:** Create `client/settings.gd`; Test `tests/settings_test.gd`.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func test_save_then_load_roundtrips() -> void:
	var path := "user://test_settings_%d.cfg" % (Time.get_ticks_usec())
	var s := ClientSettings.new()
	s.sensitivity = 0.27; s.fov = 95.0; s.master_volume = 0.6; s.invert_y = true
	s.save_to(path)
	var s2 := ClientSettings.new()
	s2.load_from(path)
	assert_almost_eq(s2.sensitivity, 0.27, 0.0001)
	assert_almost_eq(s2.fov, 95.0, 0.0001)
	assert_almost_eq(s2.master_volume, 0.6, 0.0001)
	assert_true(s2.invert_y)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_defaults_when_file_missing() -> void:
	var s := ClientSettings.new()
	s.load_from("user://does_not_exist_%d.cfg" % Time.get_ticks_usec())
	assert_true(s.fov > 0.0 and s.sensitivity > 0.0, "sane defaults")
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement**

```gdscript
class_name ClientSettings
extends RefCounted
## Player settings persisted to a ConfigFile. Defaults are BattleBit-ish; renderer toggle is read
## at boot (ADR-0005).

var sensitivity: float = 0.25
var fov: float = 90.0
var master_volume: float = 0.8
var invert_y: bool = false
var renderer_fallback: bool = false   # true -> request GL Compatibility

func save_to(path: String = "user://settings.cfg") -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "sensitivity", sensitivity)
	cf.set_value("input", "invert_y", invert_y)
	cf.set_value("video", "fov", fov)
	cf.set_value("video", "renderer_fallback", renderer_fallback)
	cf.set_value("audio", "master_volume", master_volume)
	cf.save(path)

func load_from(path: String = "user://settings.cfg") -> void:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return   # keep defaults
	sensitivity = float(cf.get_value("input", "sensitivity", sensitivity))
	invert_y = bool(cf.get_value("input", "invert_y", invert_y))
	fov = float(cf.get_value("video", "fov", fov))
	renderer_fallback = bool(cf.get_value("video", "renderer_fallback", renderer_fallback))
	master_volume = float(cf.get_value("audio", "master_volume", master_volume))
```

- [ ] **Step 4: Import + run, verify pass.**  **Step 5: Commit** — `feat(m7-c1): client settings load/save`.

---

# Part 2 — Server wiring

### Task 16: Server honors `auto_deploy` + handles `DEPLOY_REQUEST`

**Files:** Modify `server/server_main.gd`; Test `tests/server_deploy_test.gd` (mirror pattern + `DeploySpawn`).

Behavior:
- `_handle_hello` reads the `auto_deploy` byte (guard `r.get_available_bytes() > 0` for old senders → default true). Store `c["auto_deploy"]`.
- If `auto_deploy` is **false**: spawn the pawn but set `p.alive = false` and `c["respawn_tick"] = 0` (awaiting). `_handle_respawns` already only revives when `respawn_tick > 0`, so an awaiting pawn stays down. On death, for `auto_deploy=false` clients, **do not** set a respawn_tick (leave at 0) → they return to the deploy screen.
- `DEPLOY_REQUEST` handler: validate `spawn_ref` via `DeploySpawn.is_valid`; if valid, place the pawn (`pos = DeploySpawn.resolve(...)`, reset health/ammo/alive exactly like `_handle_respawns` does), else ignore (client re-prompts).

- [ ] **Step 1: Failing test** (mirror the deploy transition with pure pieces, like `server_dbno_test`):

```gdscript
extends TestCase

# Mirrors server deploy placement: an awaiting pawn (alive=false) becomes alive at a valid
# spawn ref; an invalid ref leaves it awaiting.
func _try_deploy(p: Pawn, team: int, ref: int, map: MapDef, conquest: ConquestState) -> void:
	if not DeploySpawn.is_valid(team, ref, map, conquest):
		return
	p.pos = DeploySpawn.resolve(team, ref, map, conquest)
	p.alive = true
	p.health = 100

func test_valid_ref_deploys_awaiting_pawn() -> void:
	var m := MapDef.load_default()
	var c := ConquestState.new(); c.init_from_map(m)
	var p := Pawn.new(1); p.team = 0; p.alive = false
	_try_deploy(p, 0, 0, m, c)   # HQ
	assert_true(p.alive, "valid HQ ref deploys")
	assert_eq(p.health, 100)

func test_invalid_ref_leaves_pawn_awaiting() -> void:
	var m := MapDef.load_default()
	var c := ConquestState.new(); c.init_from_map(m)
	var p := Pawn.new(1); p.team = 1; p.alive = false
	_try_deploy(p, 1, 1, m, c)   # point 0 not owned by team 1
	assert_false(p.alive, "invalid ref does not deploy")
```

- [ ] **Step 2: Run, verify fail** (uses `DeploySpawn` from Task 1; if Task 1 landed this compiles but asserts the mirror logic — write the mirror to match the server you implement in Step 3).
- [ ] **Step 3: Implement in `server_main.gd`:**
  - In `_handle_hello` after `pname`: `var auto := r.get_u8() == 1 if r.get_available_bytes() > 0 else true`; add `"auto_deploy": auto,` to the `_clients[id]` dict; after spawning the pawn, `if not auto: p.alive = false`.
  - In `_kill_pawn`: only set `respawn_tick` when `_clients[vid].get("auto_deploy", true)` (humans return to deploy screen with `respawn_tick = 0`).
  - Add a `Msg.DEPLOY_REQUEST` branch to the packet handler calling a new `_handle_deploy_request(peer, bytes)`:
```gdscript
func _handle_deploy_request(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or p.alive: return    # already deployed
	var ref := int(Protocol.decode_deploy_request(bytes)["spawn_ref"])
	if not DeploySpawn.is_valid(int(c["team"]), ref, _map, _conquest): return
	p.pos = DeploySpawn.resolve(int(c["team"]), ref, _map, _conquest)
	p.velocity = Vector3.ZERO
	p.health = 100
	p.alive = true
	p.stamina = Pawn.STAMINA_MAX
	p.is_downed = false
	c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
	c["reloading"] = false
	c["respawn_tick"] = 0
```
  Find the packet dispatch `match Protocol.msg_type(bytes):` and add the `DEPLOY_REQUEST` case routing to it.
- [ ] **Step 4: Import + run, verify pass** (`--filter=server_deploy`). Also run the **full suite** to confirm no regression: `godot --headless --path . -- --test`.
- [ ] **Step 5: Commit** — `feat(m7-c1): server auto_deploy hold + DEPLOY_REQUEST handler`.

---

### Task 17: Server emits `DAMAGE_EVENT` (with a pure bearing helper)

**Files:** Modify `server/server_main.gd`; Create `shared/sim/damage_dir.gd`; Test `tests/damage_dir_test.gd`.

Extract the bearing math into a pure helper so it's unit-tested; the server calls it in `_apply_pawn_damage`.

- [ ] **Step 1: Failing test**

```gdscript
extends TestCase

func test_bearing_points_from_victim_toward_source() -> void:
	# source due +X of victim -> world bearing atan2(dx,dz) = +90 deg.
	var b := DamageDir.bearing(Vector3(0,0,0), Vector3(10,0,0))
	assert_almost_eq(rad_to_deg(b), 90.0, 1.0)

func test_bearing_behind_is_180() -> void:
	var b := DamageDir.bearing(Vector3(0,0,0), Vector3(0,0,-10))
	assert_almost_eq(absf(rad_to_deg(b)), 180.0, 1.0)
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** `shared/sim/damage_dir.gd`:

```gdscript
class_name DamageDir
extends Object
## Pure: world-space bearing (radians) from a victim toward a damage source, matching the
## atan2(dx,dz) convention HudModel uses for compass/arc bearings.

static func bearing(victim_pos: Vector3, source_pos: Vector3) -> float:
	var d := source_pos - victim_pos
	if absf(d.x) < 0.0001 and absf(d.z) < 0.0001:
		return 0.0
	return atan2(d.x, d.z)
```
  Then in `_apply_pawn_damage`, after `victim.health -= dmg` (only for `auto_deploy` clients that are human — or simply for every client; bots ignore it), send to the victim's peer:
```gdscript
	if _clients.has(vid):
		var src := _sim.world.get_pawn(killer_id)
		var bearing := DamageDir.bearing(victim.pos, src.pos) if src != null else 0.0
		_net.send_to(_clients[vid]["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_damage_event(bearing, dmg), 0)
```
  (Unreliable channel/flags `0` — it's transient feedback; a dropped one just means a missed flash.)
- [ ] **Step 4: Import + run, verify pass** (`--filter=damage_dir`) and full suite green.
- [ ] **Step 5: Commit** — `feat(m7-c1): server emits DAMAGE_EVENT (pure DamageDir helper)`.

---

### Task 18: Server sends `SELF_STATE` to each client

**Files:** Modify `server/server_main.gd` (in `_send_snapshots`, same stride/clients loop). No new test (codec covered Task 4; reconcile covered Task 6) — verified by the full suite staying green + the C1 playtest ammo readout.

- [ ] **Step 1:** In `_send_snapshots`, inside the `for id in _clients:` loop, after the snapshot `send_to`, add:

```gdscript
		var reload_remaining := maxi(0, int(c["reload_done_tick"]) - _sim.tick) if c["reloading"] else 0
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_self_state(int(c["ammo"]), bool(c["reloading"]), reload_remaining, int(c["weapon"])), 0)
```
- [ ] **Step 2:** Run the full suite: `godot --headless --path . -- --test` — Expected: all green (309+ prior tests + new).
- [ ] **Step 3:** Run the ≤48 smoke to confirm no server regression: `cd docker && SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=8 BOT_COUNT=6 ./run-m5-p1-gate.sh` is overkill here — instead run `ci/m5_p1_test.sh` (≤48 smoke) and confirm it still passes (winner valid, peak tick <33.3). Record the log.
- [ ] **Step 4: Commit** — `feat(m7-c1): server sends SELF_STATE for ammo reconciliation`.

---

# Part 3 — Render & integrate (build + human playtest)

> These tasks produce the visible client. Pure helpers they use are already TDD-covered (Tasks 13–15). The *visual* result is validated by the **human playtest** (Task 26), per AGENTS.md §10 — not by headless gates.

### Task 19: Project config — renderer, input actions, client scene

**Files:** Modify `project.godot`; Create `client/client.tscn`.

- [ ] **Step 1:** Set renderer (ADR-0005) in `project.godot` `[rendering]`:
```
renderer/rendering_method="forward_plus"
renderer/rendering_method.mobile="gl_compatibility"
```
- [ ] **Step 2:** Add `[input]` actions: `move_fwd/back/left/right`, `jump`(Space), `crouch`(Ctrl), `prone`(X), `sprint`(Shift), `lean_left`(Q), `lean_right`(E), `fire`(MouseLeft), `aim`(MouseRight), `reload`(R), `interact`(F), `scoreboard`(Tab), `menu`(Esc). (Mouse-look is read from relative motion, not an action.)
- [ ] **Step 3:** Create `client/client.tscn`: root `Node3D` (name `ClientWorld`) with a `Camera3D`, a `DirectionalLight3D`, a `WorldEnvironment` (simple sky), and a `CanvasLayer` named `HUD`. This is the scene `world_renderer`/`hud_view` populate.
- [ ] **Step 4:** Verify it imports/opens headlessly without error: `godot --headless --path . --import` (Expected: no script/scene errors).
- [ ] **Step 5: Commit** — `feat(m7-c1): renderer config + input actions + client scene`.

### Task 20: `input_controller` — Input → InputCommand

**Files:** Create `client/input_controller.gd`.

Reads real `Input` each tick: mouse relative motion → yaw/pitch (× sensitivity, clamp pitch to `Pawn.MAX_PITCH`, optional invert), action states → `InputMap2.buttons_from`, movement axes → `move_x/move_y`. Produces a command dict for the predictor + the fields for `InputCommand.encode`.

- [ ] **Step 1:** Implement `gather(settings) -> Dictionary` returning `{move_x, move_y, yaw, pitch, buttons}` (capture `_input` mouse motion into accumulated yaw/pitch; `Input.is_action_pressed` for buttons; `Input.get_axis` for movement). Mouse mode set to `MOUSE_MODE_CAPTURED` while in-match. **Gotcha:** `Pawn.step` treats `move_x/move_y` as **world-space** (`velocity.x = move_x*speed`, `velocity.z = move_y*speed` — *not* yaw-rotated). So rotate the raw WASD axes by the current `yaw` into world space before returning them (e.g. `var f := Vector2(local_x, local_z).rotated(yaw)` → `move_x = f.x, move_y = f.y`), so forward follows where the camera looks. Verify the yaw sign/axis basis matches the compass convention (`atan2(dx,dz)`, yaw 0 = +Z) during playtest.
- [ ] **Step 2:** Manually sanity-check in the running client (Task 26): look/move respond; pitch clamps; Esc releases mouse.
- [ ] **Step 3: Commit** — `feat(m7-c1): input_controller (mouse-look + keys)`.

### Task 21: `world_view` — snapshots + interpolation + self/remote split

**Files:** Create `client/world_view.gd`; Test `tests/world_view_test.gd`.

Wraps `Snapshot.decode_apply` + `Interpolation`, exposing `remotes_at(now)` (interpolated, excluding self) and `self_state()` (latest authoritative for reconcile). Mostly a refactor of logic already in `client_main`.

- [ ] **Step 1:** Failing test: push two snapshots (via `Snapshot.encode`) for a remote id, assert `remotes_at` lerps between them (mirror `interpolation_test` style) and that the local id is excluded from `remotes_at`.
- [ ] **Step 2:** Run, verify fail. **Step 3:** Implement. **Step 4:** Import + run, verify pass.
- [ ] **Step 5: Commit** — `feat(m7-c1): world_view (apply snapshots + interpolate remotes)`.

### Task 22: `world_renderer` — scene from MapDef + pooled entities + camera

**Files:** Create `client/world_renderer.gd`.

- [ ] **Step 1:** Build static world from `MapDef` (ground plane, capture-point markers, base markers) once on init.
- [ ] **Step 2:** Maintain a pooled `MeshInstance3D` (capsule) per entity id from `world_view.remotes_at(now)`; acquire on enter, release on leave; team-tint material; apply `StancePose.of(...)` for height/offset/tilt. Box mesh placeholder is fine.
- [ ] **Step 3:** Parent the `Camera3D` to the predicted local pawn eye position (`predictor.predicted.eye_position()`), apply yaw/pitch each frame; set FOV from settings. Add a placeholder box viewmodel with simple recoil kick on predicted fire and a tracer/muzzle flash.
- [ ] **Step 4:** Playtest-verify in Task 26 (entities appear/disappear correctly; stances read; camera follows).
- [ ] **Step 5: Commit** — `feat(m7-c1): world_renderer (placeholder primitives + camera + viewmodel)`.

### Task 23: `hud_view` — draw the HUD model

**Files:** Create `client/hud/hud_view.gd`.

- [ ] **Step 1:** Control-node tree drawing `HudModel.build(...)` output: crosshair, ammo (mag + reload/low cue, bottom-right), compass strip (heading + objective markers, top-center), tickets + capture bar, killfeed (top-right), hitmarker on server hit-confirm, damage vignette (full-screen red `ColorRect` modulated by `vignette`) + directional arcs (rotated by `rel_bearing`). Interaction prompt label (centered-low). No health, no minimap.
- [ ] **Step 2:** Playtest-verify readability in Task 26.
- [ ] **Step 3: Commit** — `feat(m7-c1): hud_view (BattleBit-style core HUD)`.

### Task 24: `deploy_menu` + `settings_menu`

**Files:** Create `client/menus/deploy_menu.gd`, `client/menus/settings_menu.gd`.

- [ ] **Step 1:** `deploy_menu` lists `DeploySpawn.enumerate(team, map, conquest)` as buttons (HQ + owned points, labeled), and on click sends `Protocol.encode_deploy_request(ref)`; shown on join + after death (when un-deployed). Shows an await state until the snapshot reports the local pawn alive.
- [ ] **Step 2:** `settings_menu` edits a `ClientSettings`, calls `save_to()`, applies sensitivity/FOV/volume live (Esc toggles it in-match).
- [ ] **Step 3:** Playtest-verify deploy round-trips (you pick a spawn → you appear there).
- [ ] **Step 4: Commit** — `feat(m7-c1): deploy + settings menus`.

### Task 25: `client_main` composition root

**Files:** Modify `client/client_main.gd`; (uses `client.tscn`).

- [ ] **Step 1:** Send `encode_hello(name, false)` (request manual deploy). On `WELCOME`, instantiate `client.tscn`, create `world_renderer`, `hud_view`, `deploy_menu`, `settings_menu`, `ClientSettings.load_from()`.
- [ ] **Step 2:** Each `_physics_process`: if deployed, `input_controller.gather()` → `predictor.record_cmd` + `weapon_predictor.step` (begin_reload on reload button) → `InputCommand.encode(...)` send. Handle packets: `SNAPSHOT` → `world_view` + `predictor.reconcile_full(self_state...)`; `SELF_STATE` → `weapon_predictor.reconcile`; `DAMAGE_EVENT` → `hud_model.push_damage`; `KILL` → `hud_model.push_kill` + hitmarker/kill-confirm if local; `MATCH_STATE` → store for HUD.
- [ ] **Step 3:** Each `_process(frame)`: `world_renderer.update(world_view, predictor, now)`; `hud_view.render(hud_model.build(ctx))`; toggle deploy/settings menus.
- [ ] **Step 4:** Playtest in Task 26.
- [ ] **Step 5: Commit** — `feat(m7-c1): client_main composition root wiring`.

### Task 26: Checkpoint-1 playtest + runbook + evidence

**Files:** Create `docs/runbooks/running-client.md`; Modify `docs/milestones/M7-art-ux.md` (record C1 result).

- [ ] **Step 1:** Write `docs/runbooks/running-client.md`: on game2 start the server + bots headless (`godot --headless --path . -- --server` + `--bots --bot-count=N --connect=127.0.0.1`); on the **desktop**, run a checkout with `godot --path . -- --connect=<game2-LAN-ip>`. Note Forward+/GL fallback toggle.
- [ ] **Step 2:** Full suite green: `godot --headless --path . -- --test` (Expected: all pass, includes every new `*_test.gd`).
- [ ] **Step 3 (owner playtest):** Owner connects from desktop to game2; verifies the C1 loop: **deploy** (pick a spawn) → **move** (walk/sprint/jump/crouch/prone/lean) → **look** (mouse) → **fire/reload** (ammo counts down + reloads, recoil/tracer) → **kill a bot** (hitmarker/kill-confirm) → **take damage** (vignette + directional arc) → **die → redeploy** → stand on a point and **see capture progress + tickets** → compass shows flag bearings. Owner judges it playable + BattleBit-feeling, notes feel issues (logged as follow-ups, not C1 blockers).
- [ ] **Step 4:** Record evidence in the milestone doc: owner sign-off + the server log of the session. Mark C1 done on the TASKS board.
- [ ] **Step 5: Commit** — `docs(m7-c1): client runbook + checkpoint-1 playtest evidence`.

---

## Definition of done (Checkpoint 1)
- All new `*_test.gd` green; full suite green (no regression to the 309+ existing tests).
- The ≤48 smoke (`ci/m5_p1_test.sh`) still passes (server unaffected by the new edge messages).
- Owner playtests the full C1 infantry loop from desktop→game2 and signs it off as playable.
- Steam/L3 untouched (deferred). Vehicles + combat-depth UI are Checkpoints 2 & 3 (separate plans).

## Self-review notes (spec coverage)
- client-prediction.md → module split (Tasks 21–25), local-pawn prediction (Task 7), ammo/fire/reload prediction (Tasks 6, 25), `DEPLOY_REQUEST`/`DAMAGE_EVENT`/`SELF_STATE` (Tasks 2–4, 16–18), interpolation/view (Task 21), rendering data-feed (Tasks 14, 22). **Deviation from spec:** ammo is transported via a dedicated `SELF_STATE` message (self-only by construction) instead of an `EntityState.ammo` field, because the entity delta `field_mask` is a full 8-bit byte — cleaner and avoids widening the hot codec. (Update client-prediction.md §"EntityState.ammo" to reflect this.)
- hud-ui.md → model/view split (Tasks 8–12 model, Task 23 view), no-health damage feedback (Tasks 12, 23), compass+objectives (Task 9), tickets/capture (Task 10), killfeed (Task 11), deploy/settings menus + keybind defaults (Tasks 15, 19, 24). Squad list + TAB scoreboard + DBNO/gadget UI are **Checkpoint 3** (out of C1, noted in hud-ui.md as combat-depth UI).
- Vehicle prediction (client-prediction.md) → **Checkpoint 2** (separate plan).
