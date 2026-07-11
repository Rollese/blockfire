# M2 Core FPS Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the playable shooter loop on the M1 netcode core — full movement, hit-scan gunplay with lag-compensated head/body hit registration, health/death/respawn, 2 teams (friendly fire off), minimal classes, and combat-capable bots — holding 30 Hz with 128 bots.

**Architecture:** Server-authoritative. All gameplay rules live in `shared/` so client prediction and server authority can't diverge. The server records a per-pawn position history each tick; on a fire command it reconstructs the shot ray deterministically (never trusting a client ray), rewinds candidate enemies to the client's `view_server_tick`, and resolves head/body hits. Spread/recoil are seeded deterministically for prediction-consistency and cheat-resistance.

**Tech Stack:** Godot 4.6, GDScript, low-level ENet (from M1), `StreamPeerBuffer` wire encoding, custom headless test runner (`tests/`).

**Spec:** [`docs/specs/m2-core-fps-loop.md`](../specs/m2-core-fps-loop.md)

---

## File structure

| File | Responsibility | Status |
|---|---|---|
| `shared/sim/stance.gd` | Stance enum + per-stance params (speed, eye/body height, hitbox dims) | new |
| `shared/net/input_command.gd` | + button bit constants, `view_server_tick` field | modify |
| `shared/sim/entity_state.gd` | + pitch, stance, lean, team, alive, health | modify |
| `shared/sim/pawn.gd` | + vertical/jump/gravity, stances, lean, stamina, health, alive, team; `step(dt,cmd)` | modify |
| `shared/sim/sim_loop.gd` | pass full command dicts; skip dead pawns | modify |
| `client/prediction.gd` | predict movement via command dict (same public signature) | modify |
| `shared/net/snapshot.gd` | + F_PITCH/F_STATE/F_HEALTH fields (packed state byte) | modify |
| `shared/sim/weapon.gd` | data-driven weapon registry (hit-scan stats) | new |
| `shared/sim/hitbox.gd` | head sphere + body capsule ray tests from a pawn state | new |
| `shared/sim/combat.gd` | deterministic ray reconstruction + damage math | new |
| `shared/sim/loadout.gd` | class enum → weapon id | new |
| `server/lag_comp.gd` | per-pawn history ring + `rewind(server_tick)` | new |
| `shared/net/protocol.gd` | + `Msg.KILL` event encode/decode | modify |
| `server/server_main.gd` | lag-comp capture, fire resolution, death/respawn, teams, KILL, telemetry | modify |
| `client/client_main.gd` | send buttons/pitch/view tick; predict ammo; apply health/alive | modify |
| `bots/bot_driver.gd` | decode view; combat AI (acquire/aim/fire/reload/respawn) | modify |
| `ci/m2_load_test.sh` | 128-bot 2-team gate: tick < 33.3 ms AND kills > 0 | new |

Tests mirror each shared module under `tests/`.

**Conventions reused from M1:** tests extend global `TestCase` (`assert_true/assert_eq/assert_almost_eq`); run `godot --headless --path . -- --test --filter=<substr>`; after adding a `class_name` script run `godot --headless --path . --import` once; never pipe `godot` through `tail` (redirect to a file); commit author `-c user.name="Claude" -c user.email="noreply@anthropic.com"` with trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; `git add -A` to include `.uid` sidecars.

---

## Task 1: Stance parameters

**Files:** Create `shared/sim/stance.gd`, `tests/stance_test.gd`

- [ ] **Step 1: Write `tests/stance_test.gd`**

```gdscript
extends TestCase

func test_stance_speeds_descend() -> void:
	assert_almost_eq(Stance.speed(Stance.STAND), 6.0)
	assert_almost_eq(Stance.speed(Stance.CROUCH), 3.0)
	assert_almost_eq(Stance.speed(Stance.PRONE), 1.2)

func test_heights_present_for_each_stance() -> void:
	for s in [Stance.STAND, Stance.CROUCH, Stance.PRONE]:
		assert_true(Stance.eye_height(s) > 0.0, "eye height")
		assert_true(Stance.body_height(s) > 0.0, "body height")
		assert_true(Stance.head_center(s) > 0.0, "head center")
```

- [ ] **Step 2: Run to verify it fails** — `godot --headless --path . -- --test --filter=stance` → FAIL (`Stance` not found).

- [ ] **Step 3: Write `shared/sim/stance.gd`**

```gdscript
class_name Stance
extends Object
## Stance + lean enums and per-stance geometry/movement params. See M2 spec.

enum { STAND = 0, CROUCH = 1, PRONE = 2 }
enum { LEAN_NONE = 0, LEAN_LEFT = 1, LEAN_RIGHT = 2 }

const BODY_RADIUS := 0.35
const HEAD_RADIUS := 0.15
const LEAN_OFFSET := 0.4   # metres the shot origin shifts when leaning

static func speed(stance: int) -> float:
	match stance:
		CROUCH: return 3.0
		PRONE: return 1.2
		_: return 6.0

static func eye_height(stance: int) -> float:
	match stance:
		CROUCH: return 1.1
		PRONE: return 0.45
		_: return 1.6

static func body_height(stance: int) -> float:
	match stance:
		CROUCH: return 1.2
		PRONE: return 0.5
		_: return 1.8

static func head_center(stance: int) -> float:
	match stance:
		CROUCH: return 1.15
		PRONE: return 0.45
		_: return 1.70
```

- [ ] **Step 4: Run to verify it passes** — `--filter=stance` → 2 PASS, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: Stance params (speeds, heights, hitbox dims)"
```

---

## Task 2: InputCommand — buttons + view_server_tick

**Files:** Modify `shared/net/input_command.gd`, `tests/input_command_test.gd`

- [ ] **Step 1: Replace `tests/input_command_test.gd`** with:

```gdscript
extends TestCase

func test_input_round_trip_with_view_tick_and_buttons() -> void:
	var buttons := InputCommand.BTN_FIRE | InputCommand.BTN_SPRINT
	var bytes := InputCommand.encode(123, 45, 1.0, -0.5, 1.2, -0.3, buttons, 77)
	var d := InputCommand.decode(bytes)
	assert_eq(d["client_tick"], 123)
	assert_eq(d["ack_seq"], 45)
	assert_eq(d["view_server_tick"], 77)
	assert_almost_eq(d["move_x"], 1.0, 0.001)
	assert_almost_eq(d["move_y"], -0.5, 0.001)
	assert_almost_eq(d["yaw"], 1.2, 0.001)
	assert_eq(d["buttons"], buttons)

func test_view_tick_defaults_to_zero() -> void:
	var d := InputCommand.decode(InputCommand.encode(0, 0, 0.0, 0.0, 0.0, 0.0, 0))
	assert_eq(d["view_server_tick"], 0)

func test_move_is_clamped_to_unit() -> void:
	var d := InputCommand.decode(InputCommand.encode(0, 0, 5.0, 0.0, 0.0, 0.0, 0))
	assert_almost_eq(d["move_x"], 1.0, 0.001)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=input_command` → FAIL (`BTN_FIRE` / 8-arg encode not found).

- [ ] **Step 3: Replace `shared/net/input_command.gd`** with:

```gdscript
class_name InputCommand
extends Object
## Client -> server input frame. move_x/move_y are intent in [-1,1] (i16); yaw/pitch
## are angles (u16); buttons is a bitmask; view_server_tick is the server tick the
## client was interpolating at send time (for lag compensation). See M2 spec.

const MOVE_SCALE := 32767.0

const BTN_JUMP := 1
const BTN_CROUCH := 2
const BTN_PRONE := 4
const BTN_SPRINT := 8
const BTN_LEAN_L := 16
const BTN_LEAN_R := 32
const BTN_FIRE := 64
const BTN_RELOAD := 128

static func encode(client_tick: int, ack_seq: int, move_x: float, move_y: float,
		yaw: float, pitch: float, buttons: int, view_server_tick: int = 0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.INPUT)
	buf.put_u32(client_tick)
	buf.put_u32(ack_seq)
	buf.put_u32(view_server_tick)
	buf.put_16(clampi(roundi(clampf(move_x, -1.0, 1.0) * MOVE_SCALE), -32767, 32767))
	buf.put_16(clampi(roundi(clampf(move_y, -1.0, 1.0) * MOVE_SCALE), -32767, 32767))
	buf.put_u16(Quantize.enc_angle(yaw))
	buf.put_u16(Quantize.enc_angle(pitch))
	buf.put_u8(buttons & 0xFF)
	return buf.data_array

static func decode(bytes: PackedByteArray) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)  # skip msg type
	return {
		"client_tick": buf.get_u32(),
		"ack_seq": buf.get_u32(),
		"view_server_tick": buf.get_u32(),
		"move_x": float(buf.get_16()) / MOVE_SCALE,
		"move_y": float(buf.get_16()) / MOVE_SCALE,
		"yaw": Quantize.dec_angle(buf.get_u16()),
		"pitch": Quantize.dec_angle(buf.get_u16()),
		"buttons": buf.get_u8(),
	}
```

- [ ] **Step 4: Run to verify it passes** — `--filter=input_command` → 3 PASS, 0 failed. Then full suite `godot --headless --path . -- --test` → 0 failed (existing bot/client callers still pass 7 args; `view_server_tick` defaults to 0).

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: InputCommand adds button constants + view_server_tick"
```

---

## Task 3: EntityState — replicate combat-visible fields

**Files:** Modify `shared/sim/entity_state.gd`, `tests/entity_state_test.gd`

- [ ] **Step 1: Replace `tests/entity_state_test.gd`** with:

```gdscript
extends TestCase

func test_clone_copies_all_fields() -> void:
	var a := EntityState.new()
	a.pos = Vector3(1, 2, 3); a.yaw = 0.5; a.pitch = -0.2
	a.stance = 1; a.lean = 2; a.team = 1; a.alive = false; a.health = 42
	var b := a.clone()
	assert_eq(b.pos, Vector3(1, 2, 3))
	assert_almost_eq(b.pitch, -0.2)
	assert_eq(b.stance, 1); assert_eq(b.lean, 2); assert_eq(b.team, 1)
	assert_eq(b.alive, false); assert_eq(b.health, 42)
	b.health = 99
	assert_eq(a.health, 42, "clone independent")
```

- [ ] **Step 2: Run to verify it fails** — `--filter=entity_state` → FAIL (no `pitch`/`health`).

- [ ] **Step 3: Replace `shared/sim/entity_state.gd`** with:

```gdscript
class_name EntityState
extends RefCounted
## The replicated view of one entity. Snapshots are maps of id -> EntityState.

var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var stance: int = 0   # Stance.STAND/CROUCH/PRONE
var lean: int = 0     # Stance.LEAN_*
var team: int = 0
var alive: bool = true
var health: int = 100

func clone() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	e.pitch = pitch
	e.stance = stance
	e.lean = lean
	e.team = team
	e.alive = alive
	e.health = health
	return e
```

- [ ] **Step 4: Run to verify it passes** — `--filter=entity_state` → PASS. Full suite → 0 failed (snapshot codec only reads pos/yaw so far; new fields default).

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: EntityState gains pitch/stance/lean/team/alive/health"
```

---

## Task 4: Pawn movement model + sim/prediction wiring

**Files:** Modify `shared/sim/pawn.gd`, `shared/sim/sim_loop.gd`, `client/prediction.gd`, `tests/pawn_test.gd`, `tests/sim_loop_test.gd`

`Pawn.step` now takes a **command dict** and reads keys with `.get(...)` defaults so partial dicts (e.g. the M1-shaped server input) stay valid until the integration tasks fill them in.

- [ ] **Step 1: Replace `tests/pawn_test.gd`** with:

```gdscript
extends TestCase

func _cmd(mx := 0.0, my := 0.0, yaw := 0.0, pitch := 0.0, buttons := 0) -> Dictionary:
	return {"move_x": mx, "move_y": my, "yaw": yaw, "pitch": pitch, "buttons": buttons}

func test_walks_at_stand_speed() -> void:
	var p := Pawn.new(1)
	p.step(1.0, _cmd(1.0, 0.0))
	assert_almost_eq(p.pos.x, Stance.speed(Stance.STAND), 0.001)
	assert_almost_eq(p.pos.y, 0.0, 0.001, "stays grounded")

func test_crouch_is_slower() -> void:
	var p := Pawn.new(1)
	p.step(1.0, _cmd(1.0, 0.0, 0.0, 0.0, InputCommand.BTN_CROUCH))
	assert_eq(p.stance, Stance.CROUCH)
	assert_almost_eq(p.pos.x, Stance.speed(Stance.CROUCH), 0.001)

func test_jump_rises_then_gravity_returns_to_ground() -> void:
	var p := Pawn.new(1)
	p.step(0.1, _cmd(0, 0, 0, 0, InputCommand.BTN_JUMP))
	assert_true(p.pos.y > 0.0, "leaves ground after jump")
	for i in 60:
		p.step(1.0 / 30.0, _cmd())
	assert_almost_eq(p.pos.y, 0.0, 0.001, "gravity returns to ground")
	assert_true(p.grounded)

func test_sprint_drains_stamina_and_is_faster() -> void:
	var p := Pawn.new(1)
	p.step(1.0, _cmd(1.0, 0.0, 0.0, 0.0, InputCommand.BTN_SPRINT))
	assert_almost_eq(p.pos.x, Stance.speed(Stance.STAND) * Pawn.SPRINT_MULT, 0.01)
	assert_true(p.stamina < Pawn.STAMINA_MAX, "sprint drained stamina")

func test_pitch_clamped() -> void:
	var p := Pawn.new(1)
	p.step(0.1, _cmd(0, 0, 0, 10.0))  # absurd pitch
	assert_true(absf(p.pitch) <= Pawn.MAX_PITCH + 0.001)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=pawn` → FAIL (new step signature / fields).

- [ ] **Step 3: Replace `shared/sim/pawn.gd`** with:

```gdscript
class_name Pawn
extends RefCounted
## Kinematic player pawn. Authoritative on the server; predicted on the client.
## step() takes a command dict {move_x,move_y,yaw,pitch,buttons}; missing keys default,
## so partial dicts are tolerated. Movement is world-space planar + vertical jump/gravity.

const SPRINT_MULT := 1.6
const GRAVITY := 14.0
const JUMP_V0 := 4.5
const JUMP_COST := 10.0
const SPRINT_DRAIN := 15.0
const STAMINA_REGEN := 12.0
const STAMINA_REGEN_DELAY := 1.0
const STAMINA_MAX := 100.0
const WORLD_HALF := 1000.0
const MAX_PITCH := 1.4835  # ~85 degrees

var id: int
var pos: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var stance: int = 0
var lean: int = 0
var stamina: float = STAMINA_MAX
var grounded: bool = true
var health: int = 100
var alive: bool = true
var team: int = 0
var _regen_cooldown: float = 0.0

func _init(p_id: int = 0) -> void:
	id = p_id

func step(dt: float, cmd: Dictionary) -> void:
	yaw = cmd.get("yaw", yaw)
	pitch = clampf(cmd.get("pitch", pitch), -MAX_PITCH, MAX_PITCH)
	var buttons: int = cmd.get("buttons", 0)

	# stance
	if buttons & InputCommand.BTN_PRONE:
		stance = Stance.PRONE
	elif buttons & InputCommand.BTN_CROUCH:
		stance = Stance.CROUCH
	else:
		stance = Stance.STAND
	# lean
	if buttons & InputCommand.BTN_LEAN_L:
		lean = Stance.LEAN_LEFT
	elif buttons & InputCommand.BTN_LEAN_R:
		lean = Stance.LEAN_RIGHT
	else:
		lean = Stance.LEAN_NONE

	var move := Vector3(cmd.get("move_x", 0.0), 0.0, cmd.get("move_y", 0.0))
	if move.length() > 1.0:
		move = move.normalized()
	var has_move := move.length() > 0.01

	var sprinting := bool(buttons & InputCommand.BTN_SPRINT) and stance == Stance.STAND and stamina > 0.0 and has_move
	var speed := Stance.speed(stance) * (SPRINT_MULT if sprinting else 1.0)
	velocity.x = move.x * speed
	velocity.z = move.z * speed

	# jump
	if (buttons & InputCommand.BTN_JUMP) and grounded and stamina >= JUMP_COST:
		velocity.y = JUMP_V0
		stamina -= JUMP_COST
		_regen_cooldown = STAMINA_REGEN_DELAY
		grounded = false

	# gravity + integrate
	velocity.y -= GRAVITY * dt
	pos += velocity * dt
	if pos.y <= 0.0:
		pos.y = 0.0
		velocity.y = 0.0
		grounded = true

	# stamina
	if sprinting:
		stamina -= SPRINT_DRAIN * dt
		_regen_cooldown = STAMINA_REGEN_DELAY
	else:
		_regen_cooldown = maxf(0.0, _regen_cooldown - dt)
		if _regen_cooldown <= 0.0:
			stamina += STAMINA_REGEN * dt
	stamina = clampf(stamina, 0.0, STAMINA_MAX)

	pos.x = clampf(pos.x, -WORLD_HALF, WORLD_HALF)
	pos.z = clampf(pos.z, -WORLD_HALF, WORLD_HALF)

func eye_position() -> Vector3:
	return pos + Vector3(0.0, Stance.eye_height(stance), 0.0)

func to_state() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	e.pitch = pitch
	e.stance = stance
	e.lean = lean
	e.team = team
	e.alive = alive
	e.health = health
	return e
```

- [ ] **Step 4: Replace `shared/sim/sim_loop.gd`** with (pass the command dict through; skip dead pawns, but still settle their gravity):

```gdscript
class_name SimLoop
extends RefCounted
## Fixed-timestep authoritative simulation. Same code runs on server (authority) and
## client (prediction). inputs: Dictionary[int id -> command dict]. See AGENTS.md §7.

const DT := 1.0 / 30.0   # 30 Hz

var tick: int = 0
var world := World.new()

func step(inputs: Dictionary) -> void:
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		if not p.alive:
			continue
		p.step(DT, inputs.get(id, {}))
	tick += 1
```

- [ ] **Step 5: Update `tests/sim_loop_test.gd`** — the input is already a dict; make it explicit:

```gdscript
extends TestCase

func test_step_advances_pawns_from_inputs() -> void:
	var sim := SimLoop.new()
	sim.world.spawn(1)
	sim.world.spawn(2)
	var inputs := {1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0}}
	sim.step(inputs)
	assert_eq(sim.tick, 1)
	assert_almost_eq(sim.world.get_pawn(1).pos.x, Stance.speed(Stance.STAND) * SimLoop.DT, 0.0001)
	assert_almost_eq(sim.world.get_pawn(2).pos.x, 0.0, 0.0001, "no input = no move")
```

- [ ] **Step 6: Update `client/prediction.gd`** — keep the public signature, build a command dict internally:

```gdscript
class_name Prediction
extends RefCounted
## Client-side prediction + reconciliation for the local pawn (movement only in M2).

var predicted := Pawn.new(0)
var pending: Array = []   # [{tick, move_x, move_y, yaw}], ascending tick

func record_input(client_tick: int, move_x: float, move_y: float, yaw: float) -> void:
	predicted.step(SimLoop.DT, {"move_x": move_x, "move_y": move_y, "yaw": yaw})
	pending.append({"tick": client_tick, "move_x": move_x, "move_y": move_y, "yaw": yaw})

func reconcile(auth_pos: Vector3, auth_yaw: float, last_input_tick: int) -> void:
	var kept := []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	for inp in pending:
		predicted.step(SimLoop.DT, {"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]})
```

- [ ] **Step 7: Run** — `--filter=pawn` (5 PASS), `--filter=sim_loop` (PASS), `--filter=prediction` (existing 2 PASS). Full suite `godot --headless --path . -- --test` → 0 failed.

- [ ] **Step 8: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: Pawn movement (stances/jump/gravity/stamina) + sim/prediction wiring"
```

---

## Task 5: Snapshot codec — pitch, state byte, health

**Files:** Modify `shared/net/snapshot.gd`, `tests/snapshot_test.gd`

- [ ] **Step 1: Append to `tests/snapshot_test.gd`** these tests (keep the existing M1 tests; update the `_state` helper at the top of the file to the version below):

Replace the existing `_state` helper with:
```gdscript
func _state(x: float, z: float, yaw: float) -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(x, 0, z)
	e.yaw = yaw
	return e
```
(unchanged — existing M1 tests still pass) and ADD:
```gdscript
func test_replicates_pitch_stance_team_alive_health() -> void:
	var e := EntityState.new()
	e.pos = Vector3(1, 0, 2); e.yaw = 0.3; e.pitch = -0.4
	e.stance = Stance.CROUCH; e.lean = Stance.LEAN_RIGHT; e.team = 1
	e.alive = false; e.health = 37
	var bytes := Snapshot.encode(1, 1, 0, 0, {9: e}, {})
	var view := {}
	Snapshot.decode_apply(bytes, view)
	var g: EntityState = view[9]
	assert_almost_eq(g.pitch, -0.4, 0.01, "signed pitch preserved")
	assert_eq(g.stance, Stance.CROUCH)
	assert_eq(g.lean, Stance.LEAN_RIGHT)
	assert_eq(g.team, 1)
	assert_eq(g.alive, false)
	assert_eq(g.health, 37)

func test_health_change_is_a_delta() -> void:
	var base := _state(0, 0, 0); base.health = 100
	var cur := _state(0, 0, 0); cur.health = 80   # only health changed
	var bytes := Snapshot.encode(2, 2, 1, 0, {5: cur}, {5: base})
	var view := {5: _state(0, 0, 0)}; view[5].health = 100
	Snapshot.decode_apply(bytes, view)
	assert_eq(view[5].health, 80)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=snapshot` → FAIL (pitch/stance/health not encoded).

- [ ] **Step 3: Replace `shared/net/snapshot.gd`** with:

```gdscript
class_name Snapshot
extends Object
## Baseline + delta snapshot codec. current/baseline are Dictionary[int id -> EntityState].
## A client holding `baseline` and applying the bytes arrives exactly at `current`.
## baseline_seq == 0 is a keyframe: the receiver resets its view to this snapshot. See M2 spec.

# field_mask bits
const F_POS_X := 1
const F_POS_Y := 2
const F_POS_Z := 4
const F_YAW := 8
const F_PITCH := 16
const F_STATE := 32   # packed: stance(0-1) | lean(2-3) | team(4) | alive(5)
const F_HEALTH := 64
const F_ALL := 127

# per-record flags
const FLAG_ENTER := 1
const FLAG_LEAVE := 2
const FLAG_CHANGED := 4

static func _state_byte(e: EntityState) -> int:
	return (e.stance & 3) | ((e.lean & 3) << 2) | ((1 if e.team != 0 else 0) << 4) | ((1 if e.alive else 0) << 5)

static func encode(server_tick: int, seq: int, baseline_seq: int, last_input_tick: int,
		current: Dictionary, baseline: Dictionary) -> PackedByteArray:
	var recs := StreamPeerBuffer.new()
	var count := 0
	for id in current:
		var cur: EntityState = current[id]
		if baseline.has(id):
			var mask := _diff_mask(baseline[id], cur)
			if mask == 0:
				continue
			count += 1
			recs.put_u32(id); recs.put_u8(FLAG_CHANGED); _put_fields(recs, cur, mask)
		else:
			count += 1
			recs.put_u32(id); recs.put_u8(FLAG_ENTER); _put_fields(recs, cur, F_ALL)
	for id in baseline:
		if not current.has(id):
			count += 1
			recs.put_u32(id); recs.put_u8(FLAG_LEAVE)

	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.SNAPSHOT)
	buf.put_u32(server_tick); buf.put_u32(seq); buf.put_u32(baseline_seq); buf.put_u32(last_input_tick)
	buf.put_u16(count)
	if count > 0:
		buf.put_data(recs.data_array)
	return buf.data_array

static func decode_apply(bytes: PackedByteArray, view: Dictionary) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)
	var server_tick := buf.get_u32()
	var seq := buf.get_u32()
	var baseline_seq := buf.get_u32()
	var last_input_tick := buf.get_u32()
	var count := buf.get_u16()
	if baseline_seq == 0:
		view.clear()
	for _i in count:
		var id := buf.get_u32()
		var flags := buf.get_u8()
		if flags & FLAG_LEAVE:
			view.erase(id); continue
		var mask := buf.get_u8()
		var e: EntityState = view.get(id)
		if e == null:
			e = EntityState.new(); view[id] = e
		if mask & F_POS_X: e.pos.x = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Y: e.pos.y = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Z: e.pos.z = Quantize.dec_pos(buf.get_32())
		if mask & F_YAW:   e.yaw = Quantize.dec_angle(buf.get_u16())
		if mask & F_PITCH:
			var p := Quantize.dec_angle(buf.get_u16())
			e.pitch = p - TAU if p > PI else p   # recover signed pitch
		if mask & F_STATE:
			var sb := buf.get_u8()
			e.stance = sb & 3
			e.lean = (sb >> 2) & 3
			e.team = (sb >> 4) & 1
			e.alive = ((sb >> 5) & 1) == 1
		if mask & F_HEALTH: e.health = buf.get_u8()
	return {"server_tick": server_tick, "seq": seq, "baseline_seq": baseline_seq, "last_input_tick": last_input_tick}

static func _diff_mask(a: EntityState, b: EntityState) -> int:
	var m := 0
	if Quantize.enc_pos(a.pos.x) != Quantize.enc_pos(b.pos.x): m |= F_POS_X
	if Quantize.enc_pos(a.pos.y) != Quantize.enc_pos(b.pos.y): m |= F_POS_Y
	if Quantize.enc_pos(a.pos.z) != Quantize.enc_pos(b.pos.z): m |= F_POS_Z
	if Quantize.enc_angle(a.yaw) != Quantize.enc_angle(b.yaw): m |= F_YAW
	if Quantize.enc_angle(a.pitch) != Quantize.enc_angle(b.pitch): m |= F_PITCH
	if _state_byte(a) != _state_byte(b): m |= F_STATE
	if a.health != b.health: m |= F_HEALTH
	return m

static func _put_fields(buf: StreamPeerBuffer, e: EntityState, mask: int) -> void:
	buf.put_u8(mask)
	if mask & F_POS_X: buf.put_32(Quantize.enc_pos(e.pos.x))
	if mask & F_POS_Y: buf.put_32(Quantize.enc_pos(e.pos.y))
	if mask & F_POS_Z: buf.put_32(Quantize.enc_pos(e.pos.z))
	if mask & F_YAW:   buf.put_u16(Quantize.enc_angle(e.yaw))
	if mask & F_PITCH: buf.put_u16(Quantize.enc_angle(e.pitch))
	if mask & F_STATE: buf.put_u8(_state_byte(e))
	if mask & F_HEALTH: buf.put_u8(clampi(e.health, 0, 255))
```

- [ ] **Step 4: Run** — `--filter=snapshot` → all PASS (M1 + 2 new). Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: Snapshot replicates pitch/stance/lean/team/alive/health"
```

---

## Task 6: Weapon registry

**Files:** Create `shared/sim/weapon.gd`, `tests/weapon_test.gd`

- [ ] **Step 1: Write `tests/weapon_test.gd`**

```gdscript
extends TestCase

func test_weapons_exist_with_sane_stats() -> void:
	for wid in [Weapon.AR, Weapon.SMG, Weapon.DMR]:
		var w := Weapon.get_def(wid)
		assert_true(w["damage_body"] > 0)
		assert_true(w["headshot_mult"] >= 1.0)
		assert_true(w["mag_size"] > 0)
		assert_true(w["rpm"] > 0)

func test_fire_interval_from_rpm() -> void:
	# 600 rpm -> 0.1s between shots
	assert_almost_eq(Weapon.fire_interval(Weapon.AR), 0.1, 0.001)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=weapon` → FAIL.

- [ ] **Step 3: Write `shared/sim/weapon.gd`**

```gdscript
class_name Weapon
extends Object
## Data-driven hit-scan weapon registry. M2: flat damage to range, then 0.

enum { AR = 0, SMG = 1, DMR = 2 }

const _DEFS := {
	AR:  {"name": "AR",  "damage_body": 25, "headshot_mult": 2.0, "rpm": 600, "mag_size": 30, "reload_secs": 2.2, "spread_base_deg": 0.6, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.4, "range_m": 300.0},
	SMG: {"name": "SMG", "damage_body": 18, "headshot_mult": 1.8, "rpm": 900, "mag_size": 35, "reload_secs": 2.0, "spread_base_deg": 1.0, "spread_bloom_deg": 0.6, "recoil_pitch_deg": 0.3, "range_m": 150.0},
	DMR: {"name": "DMR", "damage_body": 45, "headshot_mult": 2.0, "rpm": 260, "mag_size": 20, "reload_secs": 2.6, "spread_base_deg": 0.2, "spread_bloom_deg": 0.3, "recoil_pitch_deg": 0.9, "range_m": 500.0},
}

static func get_def(weapon_id: int) -> Dictionary:
	return _DEFS.get(weapon_id, _DEFS[AR])

static func fire_interval(weapon_id: int) -> float:
	return 60.0 / float(get_def(weapon_id)["rpm"])
```

- [ ] **Step 4: Run** — `--filter=weapon` → 2 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: data-driven weapon registry"
```

---

## Task 7: Hitbox ray tests

**Files:** Create `shared/sim/hitbox.gd`, `tests/hitbox_test.gd`

Body is modeled as a vertical segment with radius (capsule via ray-to-segment distance); head as a sphere. Rays assume a normalized direction.

- [ ] **Step 1: Write `tests/hitbox_test.gd`**

```gdscript
extends TestCase

func test_ray_hits_body_center_not_headshot() -> void:
	# pawn standing at origin; shoot horizontally at chest height from in front (+Z toward -Z)
	var origin := Vector3(0, 0.9, 5)
	var dir := Vector3(0, 0, -1)
	var r := Hitbox.raycast_pawn(origin, dir, Vector3.ZERO, Stance.STAND, 100.0)
	assert_true(r["hit"], "should hit body")
	assert_eq(r["headshot"], false)

func test_ray_at_head_height_is_headshot() -> void:
	var origin := Vector3(0, Stance.head_center(Stance.STAND), 5)
	var dir := Vector3(0, 0, -1)
	var r := Hitbox.raycast_pawn(origin, dir, Vector3.ZERO, Stance.STAND, 100.0)
	assert_true(r["hit"])
	assert_eq(r["headshot"], true)

func test_ray_wide_miss() -> void:
	var origin := Vector3(5, 0.9, 5)
	var dir := Vector3(0, 0, -1)   # passes 5m to the side
	var r := Hitbox.raycast_pawn(origin, dir, Vector3.ZERO, Stance.STAND, 100.0)
	assert_eq(r["hit"], false)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=hitbox` → FAIL.

- [ ] **Step 3: Write `shared/sim/hitbox.gd`**

```gdscript
class_name Hitbox
extends Object
## Head sphere + body capsule (segment+radius) ray tests from a pawn position+stance.
## dir is assumed normalized. Returns nearest hit with a headshot flag.

static func ray_sphere(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := o - c
	var b := oc.dot(d)
	var cc := oc.dot(oc) - r * r
	var disc := b * b - cc
	if disc < 0.0:
		return -1.0
	var t := -b - sqrt(disc)
	return t if t >= 0.0 else -1.0

## Closest distance between ray (o + t*d, t>=0) and segment [a,b], plus the ray t at that point.
static func ray_segment(o: Vector3, d: Vector3, a: Vector3, b: Vector3) -> Dictionary:
	var u := d                      # ray dir (unit)
	var v := b - a
	var w0 := o - a
	var aa := u.dot(u)              # = 1
	var bb := u.dot(v)
	var cc := v.dot(v)
	var dd := u.dot(w0)
	var ee := v.dot(w0)
	var den := aa * cc - bb * bb
	var s := 0.0   # ray param
	var tseg := 0.0
	if den > 0.00001:
		s = (bb * ee - cc * dd) / den
		tseg = (aa * ee - bb * dd) / den
	else:
		s = -dd  # parallel: project
		tseg = 0.0
	s = maxf(s, 0.0)
	tseg = clampf(tseg, 0.0, 1.0)
	var pr := o + u * s
	var ps := a + v * tseg
	return {"dist": pr.distance_to(ps), "t": s}

static func raycast_pawn(o: Vector3, d: Vector3, pawn_pos: Vector3, stance: int, max_dist: float) -> Dictionary:
	var dir := d.normalized()
	# head sphere
	var head_c := pawn_pos + Vector3(0, Stance.head_center(stance), 0)
	var th := ray_sphere(o, dir, head_c, Stance.HEAD_RADIUS)
	# body capsule (feet+r .. body_height-r)
	var bh := Stance.body_height(stance)
	var a := pawn_pos + Vector3(0, Stance.BODY_RADIUS, 0)
	var b := pawn_pos + Vector3(0, maxf(bh - Stance.BODY_RADIUS, Stance.BODY_RADIUS), 0)
	var seg := ray_segment(o, dir, a, b)
	var body_t := seg["t"] if seg["dist"] <= Stance.BODY_RADIUS else -1.0

	var head_ok := th >= 0.0 and th <= max_dist
	var body_ok := body_t >= 0.0 and body_t <= max_dist
	if not head_ok and not body_ok:
		return {"hit": false, "headshot": false, "t": -1.0}
	if head_ok and (not body_ok or th <= body_t):
		return {"hit": true, "headshot": true, "t": th}
	return {"hit": true, "headshot": false, "t": body_t}
```

- [ ] **Step 4: Run** — `--filter=hitbox` → 3 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: hitbox ray tests (head sphere + body capsule)"
```

---

## Task 8: Combat — deterministic ray + damage

**Files:** Create `shared/sim/combat.gd`, `tests/combat_test.gd`

- [ ] **Step 1: Write `tests/combat_test.gd`**

```gdscript
extends TestCase

func test_ray_is_deterministic() -> void:
	var r1 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 1, 3, true)
	var r2 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 1, 3, true)
	assert_almost_eq((r1["dir"] - r2["dir"]).length(), 0.0, 0.00001, "same seed -> same ray")

func test_different_shot_index_differs() -> void:
	var r1 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 1, 3, true)
	var r2 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 5, 3, true)
	assert_true((r1["dir"] - r2["dir"]).length() > 0.0, "recoil/spread differ by shot index")

func test_headshot_multiplier() -> void:
	assert_eq(Combat.damage_for(Weapon.AR, false, 10.0), 25)
	assert_eq(Combat.damage_for(Weapon.AR, true, 10.0), 50)

func test_out_of_range_zero_damage() -> void:
	assert_eq(Combat.damage_for(Weapon.AR, false, 999.0), 0)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=combat` → FAIL.

- [ ] **Step 3: Write `shared/sim/combat.gd`**

```gdscript
class_name Combat
extends Object
## Deterministic, server-authoritative shot reconstruction + damage math. The server
## never trusts a client-supplied ray; it rebuilds the ray from look angles + a seed
## derived from (shooter, fire_tick, shot_index). Client can reproduce it identically.

static func _forward(yaw: float, pitch: float) -> Vector3:
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))

static func _seed(shooter_id: int, fire_tick: int, shot_index: int) -> int:
	return (shooter_id * 73856093) ^ (fire_tick * 19349663) ^ ((shot_index + 1) * 83492791)

## Returns {origin, dir}. lean: -1 left, 0 none, +1 right. moving adds spread.
static func reconstruct_ray(weapon_id: int, eye: Vector3, yaw: float, pitch: float,
		lean: int, shooter_id: int, fire_tick: int, shot_index: int, moving: bool) -> Dictionary:
	var w := Weapon.get_def(weapon_id)
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed(shooter_id, fire_tick, shot_index)

	# recoil: vertical climb grows with consecutive shots (capped), tiny horizontal jitter
	var climb := deg_to_rad(w["recoil_pitch_deg"]) * minf(float(shot_index), 8.0)
	var aim_pitch := pitch + climb

	# spread: base + per-shot bloom + movement penalty, random direction within cone
	var spread := deg_to_rad(w["spread_base_deg"] + w["spread_bloom_deg"] * minf(float(shot_index), 6.0))
	if moving:
		spread += deg_to_rad(1.5)
	var ang := rng.randf_range(0.0, TAU)
	var mag := rng.randf() * spread

	var dir := _forward(yaw + cos(ang) * mag, aim_pitch + sin(ang) * mag).normalized()

	# lean shifts the origin laterally (right vector for this yaw)
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var origin := eye + right * (Stance.LEAN_OFFSET * float(lean))
	return {"origin": origin, "dir": dir}

static func damage_for(weapon_id: int, headshot: bool, distance: float) -> int:
	var w := Weapon.get_def(weapon_id)
	if distance > w["range_m"]:
		return 0
	var dmg := float(w["damage_body"])
	if headshot:
		dmg *= w["headshot_mult"]
	return int(round(dmg))
```

- [ ] **Step 4: Run** — `--filter=combat` → 4 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: deterministic combat ray + damage math"
```

---

## Task 9: Loadout (class → weapon)

**Files:** Create `shared/sim/loadout.gd`, `tests/loadout_test.gd`

- [ ] **Step 1: Write `tests/loadout_test.gd`**

```gdscript
extends TestCase

func test_each_class_maps_to_a_weapon() -> void:
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT, Loadout.RECON]:
		var wid := Loadout.weapon_for(c)
		assert_true(wid in [Weapon.AR, Weapon.SMG, Weapon.DMR], "valid weapon for class %d" % c)

func test_recon_uses_dmr_engineer_uses_smg() -> void:
	assert_eq(Loadout.weapon_for(Loadout.RECON), Weapon.DMR)
	assert_eq(Loadout.weapon_for(Loadout.ENGINEER), Weapon.SMG)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=loadout` → FAIL.

- [ ] **Step 3: Write `shared/sim/loadout.gd`**

```gdscript
class_name Loadout
extends Object
## Minimal class -> weapon mapping for M2. Gadgets/abilities are deferred.

enum { ASSAULT = 0, MEDIC = 1, ENGINEER = 2, SUPPORT = 3, RECON = 4 }

static func weapon_for(cls: int) -> int:
	match cls:
		ENGINEER: return Weapon.SMG
		RECON: return Weapon.DMR
		_: return Weapon.AR   # assault/medic/support

static func random_class() -> int:
	return randi() % 5
```

- [ ] **Step 4: Run** — `--filter=loadout` → 2 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: loadout class->weapon mapping"
```

---

## Task 10: Lag-comp history ring

**Files:** Create `server/lag_comp.gd`, `tests/lag_comp_test.gd`

- [ ] **Step 1: Write `tests/lag_comp_test.gd`**

```gdscript
extends TestCase

func _world_with(id: int, x: float) -> World:
	var w := World.new()
	var p := w.spawn(id)
	p.pos = Vector3(x, 0, 0)
	return w

func test_records_and_rewinds() -> void:
	var lc := LagComp.new()
	lc.record(10, _world_with(1, 5.0))
	lc.record(11, _world_with(1, 6.0))
	var s10 := lc.rewind(10)
	assert_almost_eq(s10[1]["pos"].x, 5.0, 0.001)
	var s11 := lc.rewind(11)
	assert_almost_eq(s11[1]["pos"].x, 6.0, 0.001)

func test_clamps_to_window() -> void:
	var lc := LagComp.new()
	for t in range(1, 50):  # more than HISTORY
		lc.record(t, _world_with(1, float(t)))
	# requesting an evicted old tick clamps to the oldest retained
	var old := lc.rewind(1)
	assert_true(old.size() >= 0, "no crash, clamps")
	var recent := lc.rewind(49)
	assert_almost_eq(recent[1]["pos"].x, 49.0, 0.001)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=lag_comp` → FAIL.

- [ ] **Step 3: Write `server/lag_comp.gd`**

```gdscript
class_name LagComp
extends RefCounted
## Per-tick position history for lag-compensated hit tests. Stores the minimal pawn
## state needed to rebuild hitboxes (pos, stance, team, alive) keyed by server tick.

const HISTORY := 32     # ticks retained (~1.06s @30Hz)
const MAX_REWIND := 12  # max rewind from 'now' (~400ms)

var _hist := {}         # server_tick -> {id -> {pos, stance, team, alive}}
var _newest := -1

func record(server_tick: int, world: World) -> void:
	var frame := {}
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		frame[id] = {"pos": p.pos, "stance": p.stance, "team": p.team, "alive": p.alive}
	_hist[server_tick] = frame
	_newest = maxi(_newest, server_tick)
	var cutoff := _newest - HISTORY
	for t in _hist.keys():
		if t < cutoff:
			_hist.erase(t)

## Returns the recorded frame {id -> state} for a tick, clamped into [now-MAX_REWIND, now].
func rewind(server_tick: int) -> Dictionary:
	if _newest < 0:
		return {}
	var t := clampi(server_tick, _newest - MAX_REWIND, _newest)
	# find nearest retained tick <= t (fallback to newest)
	while t >= _newest - HISTORY and not _hist.has(t):
		t -= 1
	return _hist.get(t, _hist.get(_newest, {}))
```

- [ ] **Step 4: Run** — `--filter=lag_comp` → 2 PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: lag-comp history ring + rewind"
```

---

## Task 11: KILL event in protocol

**Files:** Modify `shared/net/protocol.gd`, `tests/protocol_test.gd` (new)

- [ ] **Step 1: Write `tests/protocol_test.gd`**

```gdscript
extends TestCase

func test_kill_event_round_trip() -> void:
	var bytes := Protocol.encode_kill(7, 3, Weapon.DMR, true)
	assert_eq(Protocol.msg_type(bytes), Protocol.Msg.KILL)
	var d := Protocol.decode_kill(bytes)
	assert_eq(d["victim"], 7)
	assert_eq(d["killer"], 3)
	assert_eq(d["weapon"], Weapon.DMR)
	assert_eq(d["headshot"], true)
```

- [ ] **Step 2: Run to verify it fails** — `--filter=protocol` → FAIL.

- [ ] **Step 3: Modify `shared/net/protocol.gd`** — add `KILL = 6` to the `Msg` enum, and append these methods:

```gdscript
enum Msg {
	HELLO = 1,
	WELCOME = 2,
	REJECT = 3,
	INPUT = 4,
	SNAPSHOT = 5,
	KILL = 6,     ## server -> client (reliable): victim, killer, weapon, headshot
}
```
(keep the existing comments on the other values) and add:
```gdscript
static func encode_kill(victim_id: int, killer_id: int, weapon_id: int, headshot: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.KILL)
	buf.put_u32(victim_id)
	buf.put_u32(killer_id)
	buf.put_u8(weapon_id)
	buf.put_u8(1 if headshot else 0)
	return buf.data_array

static func decode_kill(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"victim": r.get_u32(), "killer": r.get_u32(), "weapon": r.get_u8(), "headshot": r.get_u8() == 1}
```

- [ ] **Step 4: Run** — `--filter=protocol` → PASS. Full suite → 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: KILL event in protocol"
```

---

## Task 12: Server integration — combat, lag-comp, teams, respawn

**Files:** Modify `server/server_main.gd`

This is the integration core: assign teams + spawn halves, drive full movement, record lag-comp history, resolve fires (cooldown/ammo/reload, deterministic ray, rewind enemies, hit→damage→death→KILL), respawn timers, and combat telemetry.

- [ ] **Step 1: Replace `server/server_main.gd`** with:

```gdscript
extends Node
## Dedicated authoritative server. 30 Hz. Movement + hit-scan combat with lag comp,
## teams (FF off), minimal respawn. See docs/specs/m2-core-fps-loop.md.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128
const INTEREST_RADIUS := 250.0
const CELL_SIZE := 64.0
const MAX_HISTORY := 32
const RESPAWN_DELAY_TICKS := 150   # 5s @30Hz
const FIRE_CONE_DOT := 0.985       # broad-phase: target within ~10deg of ray

var _net: NetHost
var _port := 27015
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _lag := LagComp.new()
var _tele := Telemetry.new()
var _next_id := 1
var _tele_accum := 0.0
var _team_counts := {0: 0, 1: 0}

# combat telemetry counters (per window)
var _kills := 0
var _shots := 0
var _hits := 0
var _rewind_clamped := 0

# id -> client record (movement/replication from M1 + combat state)
var _clients := {}
var _peer_to_id := {}

func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))

func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)]); get_tree().quit(1); return
	print("[server] listening on %d, tick=%dHz, max=%d" % [_port, TICK_RATE, MAX_PLAYERS])

func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	_step_movement()
	_lag.record(_sim.tick, _sim.world)
	_resolve_fires()
	_handle_respawns()
	_send_snapshots()
	_tele.record_tick_ms(float(Time.get_ticks_usec() - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry(); _tele_accum = 0.0

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
		# advance reload timer
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
		# track consecutive-shot index (reset when trigger released)
		if not firing:
			c["shot_index"] = 0
			c["trigger_down"] = false
			# reload request
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and c["ammo"] < Weapon.get_def(c["weapon"])["mag_size"]:
				c["reloading"] = true
				c["reload_done_tick"] = _sim.tick + int(round(Weapon.get_def(c["weapon"])["reload_secs"] * TICK_RATE))
			continue
		var now := float(_sim.tick) * SimLoop.DT
		var ready := now - c["last_fire_time"] >= Weapon.fire_interval(c["weapon"])
		var sprinting := (inp["buttons"] & InputCommand.BTN_SPRINT) and shooter.stance == Stance.STAND
		if c["reloading"] or c["ammo"] <= 0 or not ready or sprinting:
			continue
		# fire one shot
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
	var moving := absf(inp["move_x"]) + absf(inp["move_y"]) > 0.01
	var ray := Combat.reconstruct_ray(_clients[shooter_id]["weapon"], shooter.eye_position(),
		inp["yaw"], inp["pitch"], lean_sign, shooter_id, inp["client_tick"], shot_index, moving)

	# clamp rewind + flag
	var view_tick: int = inp["view_server_tick"]
	if view_tick < _sim.tick - LagComp.MAX_REWIND or view_tick > _sim.tick:
		_rewind_clamped += 1
	var frame := _lag.rewind(view_tick)

	var wid: int = _clients[shooter_id]["weapon"]
	var max_range: float = Weapon.get_def(wid)["range_m"]
	var best_t := max_range + 1.0
	var best_victim := 0
	var best_head := false
	for tid in frame:
		if tid == shooter_id: continue
		var st = frame[tid]
		if not st["alive"] or st["team"] == shooter.team: continue   # FF off + skip dead
		var to_target := (st["pos"] - ray["origin"])
		if to_target.length() > max_range: continue
		if to_target.normalized().dot(ray["dir"]) < FIRE_CONE_DOT: continue   # broad phase
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
			p.pos = _spawn_pos(p.team)
			p.velocity = Vector3.ZERO
			p.health = 100
			p.alive = true
			p.stamina = Pawn.STAMINA_MAX
			c["respawn_tick"] = 0
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
			c["reloading"] = false

func _send_snapshots() -> void:
	var state := _sim.world.state_map()
	var positions := {}
	_grid.clear()
	for id in state:
		positions[id] = state[id].pos
		_grid.insert(id, state[id].pos)
	for id in _clients:
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null: continue
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, positions)
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
	var team := 0 if _team_counts[0] <= _team_counts[1] else 1
	_team_counts[team] += 1
	var cls := Loadout.random_class()
	var wid := Loadout.weapon_for(cls)
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "queued_input": null, "last_input": null, "last_input_tick": 0,
		"last_acked_seq": 0, "next_seq": 1, "history": {},
		"team": team, "class": cls, "weapon": wid, "ammo": Weapon.get_def(wid)["mag_size"],
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "trigger_down": false, "respawn_tick": 0,
	}
	var p := _sim.world.spawn(id)
	p.team = team
	p.pos = _spawn_pos(team)
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') team=%d class=%d — %d peers" % [id, pname, team, cls, _clients.size()])

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
		_team_counts[_clients[id]["team"]] -= 1
		_clients.erase(id)
		_sim.world.despawn(id)
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])

func _spawn_pos(team: int) -> Vector3:
	var half := Pawn.WORLD_HALF
	var x := randf_range(-half, -50.0) if team == 0 else randf_range(50.0, half)
	return Vector3(x, 0.0, randf_range(-half, half))

func _log_telemetry() -> void:
	var n := _clients.size()
	var alive := 0
	for id in _sim.world.pawns:
		if _sim.world.pawns[id].alive: alive += 1
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	var hit_rate := 0.0 if _shots == 0 else float(_hits) / float(_shots)
	print("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d"
		% [n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit, _kills, _shots, hit_rate, _tele.starvation, _rewind_clamped])
	_tele.reset_window()
	_kills = 0; _shots = 0; _hits = 0; _rewind_clamped = 0
```

- [ ] **Step 2: Smoke-run the server alone** — `godot --headless --path . --import` then `timeout 3 godot --headless --path . -- --server --port=27220 > /tmp/bf_s.log 2>&1 ; true`. Read `/tmp/bf_s.log`: expect `[server] listening on 27220 ...` and a `[telemetry] players=0 ...kills=0...` line, no `SCRIPT ERROR`/stack traces.

- [ ] **Step 3: Run full unit suite** — `godot --headless --path . -- --test` → `0 failed` (no regressions).

- [ ] **Step 4: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: server combat — lag-comp, fire resolution, teams, respawn, telemetry"
```

---

## Task 13: Client integration — send buttons/pitch/view tick, apply health

**Files:** Modify `client/client_main.gd`

Headless client (real input devices arrive with rendering later). It sends look/buttons/view-tick, predicts movement + ammo, and tracks its own pawn's health/alive from snapshots.

- [ ] **Step 1: Replace `client/client_main.gd`** with:

```gdscript
extends Node
## Client. M2 (headless): connect, send input (look + buttons + view tick), apply snapshots,
## reconcile own pawn, track health/alive. Rendering/real input arrive later.

const Protocol := preload("res://shared/net/protocol.gd")

var _net: NetHost
var _server_ip := "127.0.0.1"
var _port := 27015
var _player_name := "Player"
var _peer: ENetPacketPeer

var my_id := 0
var _client_tick := 0
var _last_snapshot_seq := 0
var _last_server_tick := 0
var _view := {}
var _pred := Prediction.new()
var _interp := Interpolation.new()
var _elapsed := 0.0
var _log_accum := 0.0

func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_player_name = String(args.get("name", _player_name))

func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(_on_connected)
	_net.packet_received.connect(_on_packet)
	_peer = _net.start_client(_server_ip, _port)
	if _peer == null:
		push_error("[client] failed to create client host"); return
	print("[client] connecting to %s:%d ..." % [_server_ip, _port])

func _physics_process(delta: float) -> void:
	_net.poll()
	_elapsed += delta
	if my_id != 0:
		_client_tick += 1
		# M2 headless: neutral movement, no buttons. Real input arrives with rendering.
		_pred.record_input(_client_tick, 0.0, 0.0, 0.0)
		_net.send_to(_peer, NetHost.CHANNEL_INPUT,
			InputCommand.encode(_client_tick, _last_snapshot_seq, 0.0, 0.0, 0.0, 0.0, 0, _last_server_tick), 0)
	_log_accum += delta
	if _log_accum >= 2.0 and my_id != 0:
		var hp := _view[my_id].health if _view.has(my_id) else -1
		print("[client] id=%d tick=%d view=%d hp=%d" % [my_id, _client_tick, _view.size(), hp])
		_log_accum = 0.0

func _on_connected(peer: ENetPacketPeer) -> void:
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_hello(_player_name), ENetPacketPeer.FLAG_RELIABLE)

func _on_packet(_peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var r := Protocol.body_reader(bytes)
			my_id = r.get_u32()
			print("[client] WELCOME — id=%d, server tick=%dHz" % [my_id, r.get_u16()])
		Protocol.Msg.REJECT:
			print("[client] REJECTED: %s" % Protocol.body_reader(bytes).get_utf8_string())
		Protocol.Msg.KILL:
			var k := Protocol.decode_kill(bytes)
			if k["victim"] == my_id or k["killer"] == my_id:
				print("[client] KILL victim=%d killer=%d head=%s" % [k["victim"], k["killer"], str(k["headshot"])])
		Protocol.Msg.SNAPSHOT:
			_apply_snapshot(bytes)

func _apply_snapshot(bytes: PackedByteArray) -> void:
	var hdr := Snapshot.decode_apply(bytes, _view)
	_last_snapshot_seq = maxi(_last_snapshot_seq, int(hdr["seq"]))
	_last_server_tick = int(hdr["server_tick"])
	if _view.has(my_id):
		var mine: EntityState = _view[my_id]
		_pred.reconcile(mine.pos, mine.yaw, int(hdr["last_input_tick"]))
	var remotes := {}
	for id in _view:
		if id != my_id: remotes[id] = (_view[id] as EntityState).clone()
	_interp.push(_elapsed, remotes)
```

- [ ] **Step 2: Smoke test** — `godot --headless --path . --import` then:
```bash
timeout 6 godot --headless --path . -- --server --port=27221 > /tmp/bf_s.log 2>&1 &
sleep 2
timeout 4 godot --headless --path . -- --connect=127.0.0.1 --port=27221 --name=c1 > /tmp/bf_c.log 2>&1
grep -E "WELCOME|hp=" /tmp/bf_c.log; grep -E "welcomed peer 1" /tmp/bf_s.log
```
Expect: client `WELCOME — id=1` and a `hp=100` line; server `welcomed peer 1 (...) team=...`; no script errors.

- [ ] **Step 3: Full unit suite** — `godot --headless --path . -- --test` → 0 failed.

- [ ] **Step 4: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: client sends buttons/pitch/view-tick, tracks health/alive"
```

---

## Task 14: Bot combat AI

**Files:** Modify `bots/bot_driver.gd`

Bots now decode their interest view, pick the nearest enemy-team alive pawn, aim (with small error), fire, reload when empty, move toward the target, and respawn.

- [ ] **Step 1: Replace `bots/bot_driver.gd`** with:

```gdscript
extends Node
## Headless bot fleet. Each bot is a real client that decodes its interest view and
## fights the nearest enemy. Many bots per process (load + playtest). See M2 spec.

const Protocol := preload("res://shared/net/protocol.gd")
const AIM_TOLERANCE := 0.05   # radians; fire when aim within this of target

var _server_ip := "127.0.0.1"
var _port := 27015
var _bot_count := 1
var _bots: Array[Dictionary] = []

func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_bot_count = maxi(1, int(args.get("bot-count", _bot_count)))

func _ready() -> void:
	print("[bots] spawning %d bot(s) -> %s:%d" % [_bot_count, _server_ip, _port])
	for i in _bot_count:
		_spawn_bot(i)

func _spawn_bot(index: int) -> void:
	var net := NetHost.new()
	add_child(net)
	var bot := {
		"net": net, "index": index, "id": 0, "connected": false, "peer": null,
		"tick": 0, "last_seq": 0, "server_tick": 0, "view": {},
		"yaw": randf() * TAU, "pitch": 0.0, "heading": randf() * TAU, "turn_timer": 0.0,
	}
	net.peer_connected.connect(func(peer: ENetPacketPeer) -> void:
		bot["peer"] = peer
		net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_hello("bot-%d" % index), ENetPacketPeer.FLAG_RELIABLE))
	net.peer_disconnected.connect(func(_p: ENetPacketPeer) -> void: bot["connected"] = false)
	net.packet_received.connect(func(_p: ENetPacketPeer, _ch: int, bytes: PackedByteArray) -> void: _on_packet(bot, bytes))
	net.start_client(_server_ip, _port)
	_bots.append(bot)

func _physics_process(delta: float) -> void:
	for bot in _bots:
		(bot["net"] as NetHost).poll()
		if not bot["connected"]: continue
		bot["tick"] += 1
		_drive(bot, delta)

func _drive(bot: Dictionary, delta: float) -> void:
	var view: Dictionary = bot["view"]
	var me: EntityState = view.get(bot["id"])
	var buttons := 0
	var move_x := 0.0
	var move_y := 0.0

	if me == null or not me.alive:
		# dead or not yet visible: idle (still send input so server has a frame)
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# acquire nearest enemy
	var target: EntityState = null
	var best := INF
	for id in view:
		if id == bot["id"]: continue
		var e: EntityState = view[id]
		if not e.alive or e.team == me.team: continue
		var dist := me.pos.distance_to(e.pos)
		if dist < best:
			best = dist; target = e

	if target != null:
		var d := target.pos - me.pos
		var want_yaw := atan2(d.x, d.z)
		var want_pitch := clampf(asin(clampf(d.y / maxf(d.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
		# small aim error, ease toward target
		bot["yaw"] = lerp_angle(bot["yaw"], want_yaw, 0.5) + randf_range(-0.01, 0.01)
		bot["pitch"] = lerpf(bot["pitch"], want_pitch, 0.5)
		# advance toward target; fire when roughly aimed
		move_y = 1.0
		if absf(angle_diff(bot["yaw"], want_yaw)) < AIM_TOLERANCE:
			buttons |= InputCommand.BTN_FIRE
	else:
		# wander
		bot["turn_timer"] -= delta
		if bot["turn_timer"] <= 0.0:
			bot["heading"] = randf() * TAU; bot["turn_timer"] = randf_range(0.5, 2.0)
		bot["yaw"] = bot["heading"]; move_y = 1.0

	_send(bot, move_x, move_y, bot["yaw"], bot["pitch"], buttons)

func angle_diff(a: float, b: float) -> float:
	return wrapf(a - b, -PI, PI)

func _send(bot: Dictionary, mx: float, my: float, yaw: float, pitch: float, buttons: int) -> void:
	var bytes := InputCommand.encode(bot["tick"], bot["last_seq"], mx, my, yaw, pitch, buttons, bot["server_tick"])
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, bytes, 0)

func _on_packet(bot: Dictionary, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			bot["id"] = Protocol.body_reader(bytes).get_u32()
			bot["connected"] = true
			print("[bots] bot %d connected (id %d) — %d/%d" % [bot["index"], bot["id"], _connected_count(), _bot_count])
		Protocol.Msg.SNAPSHOT:
			var hdr := Snapshot.decode_apply(bytes, bot["view"])
			bot["last_seq"] = maxi(bot["last_seq"], int(hdr["seq"]))
			bot["server_tick"] = int(hdr["server_tick"])
		_:
			pass

func _connected_count() -> int:
	var n := 0
	for b in _bots:
		if b["connected"]: n += 1
	return n
```

- [ ] **Step 2: Smoke test 8 bots actually fight** — `godot --headless --path . --import` then:
```bash
timeout 12 godot --headless --path . -- --server --port=27222 > /tmp/bf_s.log 2>&1 &
sleep 2
timeout 9 godot --headless --path . -- --bots --bot-count=8 --port=27222 > /tmp/bf_b.log 2>&1
grep -E "8/8" /tmp/bf_b.log
grep -E "kills=[1-9]" /tmp/bf_s.log | tail -2
```
Expect: `8/8` connected, and at least one telemetry line with `kills>=1` once bots engage (teams spawn apart, so it may take a few seconds to close distance). No script errors.

- [ ] **Step 3: Full unit suite** — `godot --headless --path . -- --test` → 0 failed.

- [ ] **Step 4: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: bot combat AI (acquire/aim/fire/move/respawn)"
```

---

## Task 15: M2 gate — 128 bots, two teams, kills register

**Files:** Create `ci/m2_load_test.sh`

- [ ] **Step 1: Write `ci/m2_load_test.sh`**

```bash
#!/usr/bin/env bash
# M2 gate: server + 128 bots (2 teams) headless ~40s. Assert mean server tick < 33.3ms
# AND kills are registering (bots actually shoot each other). Exit non-zero on breach.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27230}"
BOTS="${BOTS:-128}"
DURATION="${DURATION:-40}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m2] server on $PORT"
"$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m2] $BOTS bots"
"$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!
sleep "$DURATION"

line="$(grep "players=$BOTS" "$server_log" | tail -1)"
echo "--- last telemetry ---"; echo "$line"
if [ -z "$line" ]; then echo "FAIL: never reached $BOTS players"; exit 1; fi

mean="$(echo "$line" | sed -n 's/.*tick_mean=\([0-9.]*\)ms.*/\1/p')"
total_kills="$(grep -oE 'kills=[0-9]+' "$server_log" | sed 's/kills=//' | awk '{s+=$1} END{print s+0}')"
echo "[m2] mean tick=${mean}ms (budget ${TICK_BUDGET_MS})  total kills over run=${total_kills}"

ok=1
awk "BEGIN{exit !($mean < $TICK_BUDGET_MS)}" || { echo "FAIL: tick over budget"; ok=0; }
[ "$total_kills" -ge 1 ] || { echo "FAIL: no kills registered"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M2 GATE: PASS"; exit 0; else echo "M2 GATE: FAIL"; exit 1; fi
```

- [ ] **Step 2: Make executable and run** — `chmod +x ci/m2_load_test.sh && ci/m2_load_test.sh`. Expect `players=128` telemetry, `total kills over run >= 1`, mean tick < 33.3 ms, `M2 GATE: PASS`. If tick is over budget, the hot path is fire resolution / lag-comp rewinds — profile (e.g. tighten the broad-phase cone, cap candidates) before relaxing the budget. If `kills=0`, check bot acquisition (team filter, view decode) and that teams can reach each other.

- [ ] **Step 3: Record evidence** — edit `docs/milestones/M2-core-fps-loop.md`: set status `done ✅ (gate passed 2026-06-13)`, add an Evidence section with the passing telemetry line (tick mean/p99, kills, hit_rate, alive, starv). Edit `docs/TASKS.md`: M2 → `**done ✅**`, M3 → `**next**`.

- [ ] **Step 4: Commit**

```bash
git add -A
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "M2: load-test gate (128 bots, 2 teams, kills register) + evidence"
```

---

## Self-review

**Spec coverage:**
- Full movement (stances/lean/jump/stamina) → Tasks 1, 4 ✓
- Replicate pitch/stance/lean/team/alive/health → Tasks 3, 5 ✓
- Hit-scan weapons (data-driven, recoil/spread/reload/ammo) → Tasks 6, 8, 12 ✓
- Deterministic server-authoritative spread/recoil (no client ray) → Task 8 (`reconstruct_ray`), Task 12 (`_fire_shot` rebuilds ray) ✓
- Two-part head+body hitboxes + headshot mult → Tasks 7, 8 ✓
- Client fire-tick lag comp (clamped, validated, `view_server_tick`) → Tasks 2, 10, 12 ✓
- Health/death/minimal respawn → Tasks 4, 12 ✓
- Teams (balanced, spawn halves), FF off → Task 12 (`_handle_hello`, `_spawn_pos`, `_fire_shot` team check) ✓
- Minimal classes (class→weapon) → Tasks 9, 12 ✓
- KILL event → Tasks 11, 12, 13 ✓
- Combat bot AI (team-filtered acquire/aim/fire/move/respawn, view decode, view tick) → Task 14 ✓
- Telemetry (kills/shots/hit_rate/alive/rewind_clamped) → Task 12 ✓
- 128-bot 2-team gate → Task 15 ✓
- Edge cases: view tick clamp+flag (Task 12), FF same-team skip (Task 12), dead-not-candidate via rewound `alive` (Task 12), reload/sprint/empty rejects (Task 12) ✓
- Explicitly out of scope (no tasks): projectiles, gadgets, deploy/squad spawn, real art/anim/ADS, HUD ✓

**Placeholder scan:** none — every code step has complete code; numeric tuning is concrete.

**Type/name consistency:** `Pawn.step(dt, cmd)` used in Tasks 4/sim_loop/prediction. `Stance.STAND/CROUCH/PRONE`, `Stance.LEAN_*`, `Stance.speed/eye_height/body_height/head_center/BODY_RADIUS/HEAD_RADIUS/LEAN_OFFSET` consistent across Tasks 1/4/7. `InputCommand.BTN_*` and 8-arg `encode(...,view_server_tick=0)` consistent across Tasks 2/4/12/13/14. `EntityState` fields consistent across Tasks 3/5/12/13/14. `Snapshot.encode(server_tick,seq,baseline_seq,last_input_tick,current,baseline)` / `decode_apply→{server_tick,seq,baseline_seq,last_input_tick}` consistent across Tasks 5/12/13/14. `Weapon.get_def/fire_interval`, `Weapon.AR/SMG/DMR` consistent Tasks 6/8/9/12. `Hitbox.raycast_pawn(o,dir,pawn_pos,stance,max_dist)→{hit,headshot,t}` consistent Tasks 7/12. `Combat.reconstruct_ray(weapon,eye,yaw,pitch,lean,shooter_id,fire_tick,shot_index,moving)→{origin,dir}` and `Combat.damage_for(weapon,headshot,distance)` consistent Tasks 8/12. `LagComp.record(tick,world)/rewind(tick)`, `LagComp.MAX_REWIND` consistent Tasks 10/12. `Protocol.encode_kill/decode_kill`, `Msg.KILL` consistent Tasks 11/12/13. ✓

**Known perf note:** fire resolution iterates the rewound frame per shot with a broad-phase cone before precise ray tests. If Task 15 exceeds the tick budget at 128 bots, tighten `FIRE_CONE_DOT` / cap candidates / restrict to interest before relaxing the budget (mirrors M1's interest-management guidance).
