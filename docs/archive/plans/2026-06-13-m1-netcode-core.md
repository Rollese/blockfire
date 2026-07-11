# M1 Netcode Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the authoritative 30 Hz replication core — per-client baseline+delta snapshots over interest-managed entities, with client prediction/reconciliation and interpolation — and prove it holds 30 Hz with 128 bot pawns.

**Architecture:** Server is sole authority and runs a shared `SimLoop` over a `World` of kinematic `Pawn`s on a flat ground plane. Each tick it consumes one buffered input per client, steps the sim, then for each client queries an `InterestGrid` and sends a delta snapshot encoded against that client's last acked snapshot. Clients/bots send input command frames and piggyback snapshot acks; the real client reconciles its own pawn and interpolates remote pawns. All gameplay rules live in `shared/` so prediction (client) and authority (server) cannot diverge.

**Tech Stack:** Godot 4.6, GDScript, low-level `ENetConnection` transport (from M0), `StreamPeerBuffer` for byte-aligned wire encoding. Custom headless test runner (no external test addon).

**Spec:** [`docs/specs/m1-netcode-core.md`](../specs/m1-netcode-core.md)

---

## File structure

Created/modified in this plan:

| File | Responsibility |
|---|---|
| `tests/test_case.gd` | Base class: assert helpers, failure collection |
| `tests/test_runner.gd` | Headless discovery + run of `*_test.gd`, exit code |
| `shared/bootstrap.gd` *(modify)* | Add `--test` role |
| `shared/net/quantize.gd` | Position ↔ i32 mm, angle ↔ u16 |
| `shared/net/protocol.gd` *(modify)* | Add `Msg.INPUT`, `Msg.SNAPSHOT` |
| `shared/sim/entity_state.gd` | Replicated snapshot of one entity (pos, yaw) |
| `shared/net/snapshot.gd` | Baseline+delta snapshot encode/decode |
| `shared/net/input_command.gd` | Input frame encode/decode |
| `shared/sim/pawn.gd` | Kinematic pawn state + movement integration |
| `shared/sim/world.gd` | Entity registry (id → Pawn) |
| `shared/sim/sim_loop.gd` *(modify)* | Step World from inputs |
| `shared/sim/interest_grid.gd` | Uniform spatial hash + radius query |
| `shared/telemetry.gd` | Tick-time / bandwidth / starvation counters |
| `client/prediction.gd` | Client own-pawn prediction + reconciliation |
| `client/interpolation.gd` | Remote-entity interpolation buffer |
| `server/server_main.gd` *(modify)* | Authoritative tick loop, per-client snapshots, telemetry |
| `client/client_main.gd` *(modify)* | Send input, apply snapshots, reconcile/interp |
| `bots/bot_driver.gd` *(modify)* | Random-walk input, cheap snapshot ack |
| `ci/m1_load_test.sh` | 128-bot gate: assert mean tick < 33.3 ms |

Test files mirror each module: `tests/<name>_test.gd`.

---

## Task 1: Headless test harness

**Files:**
- Create: `tests/test_case.gd`, `tests/test_runner.gd`, `tests/harness_test.gd`
- Modify: `shared/bootstrap.gd`

- [ ] **Step 1: Write `tests/test_case.gd`**

```gdscript
class_name TestCase
extends RefCounted
## Base for all tests. Subclasses define methods named test_*. Asserts append to
## `failures`; a test with no failures passes.

var failures: Array[String] = []

func reset() -> void:
	failures = []

func fail(msg: String) -> void:
	failures.append(msg)

func assert_true(cond: bool, msg := "") -> void:
	if not cond:
		failures.append("assert_true failed: %s" % msg)

func assert_eq(a, b, msg := "") -> void:
	if a != b:
		failures.append("assert_eq: %s != %s  %s" % [str(a), str(b), msg])

func assert_almost_eq(a: float, b: float, tol := 0.001, msg := "") -> void:
	if absf(a - b) > tol:
		failures.append("assert_almost_eq: %s vs %s (tol %s)  %s" % [str(a), str(b), str(tol), msg])
```

- [ ] **Step 2: Write `tests/test_runner.gd`**

```gdscript
extends Node
## Headless test runner. Loads tests/**/*_test.gd, runs each test_* method, prints
## PASS/FAIL, and quits with code 0 (all pass) or 1 (any fail).
## Run: godot --headless --path . -- --test [--filter=substr]

func _ready() -> void:
	var filter := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr("--filter=".length())

	var total := 0
	var failed := 0
	for path in _discover("res://tests"):
		var script: GDScript = load(path)
		var inst = script.new()
		for m in inst.get_method_list():
			var name: String = m.name
			if not name.begins_with("test_"):
				continue
			if filter != "" and not (name.contains(filter) or path.get_file().contains(filter)):
				continue
			total += 1
			inst.reset()
			inst.call(name)
			if inst.failures.is_empty():
				print("  PASS %s::%s" % [path.get_file(), name])
			else:
				failed += 1
				for f in inst.failures:
					print("  FAIL %s::%s — %s" % [path.get_file(), name, f])
	print("TESTS: %d run, %d failed" % [total, failed])
	get_tree().quit(1 if failed > 0 else 0)

func _discover(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			out.append_array(_discover(full))
		elif name.ends_with("_test.gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out
```

- [ ] **Step 3: Add the `--test` role in `shared/bootstrap.gd`**

In `_ready()`, extend the `match role` block (add the `"test"` case as the first branch):

```gdscript
	match role:
		"test":
			role_node = preload("res://tests/test_runner.gd").new()
		"server":
			role_node = preload("res://server/server_main.gd").new()
		"bots":
			role_node = preload("res://bots/bot_driver.gd").new()
		_:
			role_node = preload("res://client/client_main.gd").new()
```

And in `_select_role()`, add at the top:

```gdscript
	if args.has("test"):
		return "test"
```

- [ ] **Step 4: Write the self-test `tests/harness_test.gd`**

```gdscript
extends TestCase

func test_harness_runs_and_asserts() -> void:
	assert_true(true, "trivial")
	assert_eq(1 + 1, 2)
	assert_almost_eq(0.1 + 0.2, 0.3)
```

- [ ] **Step 5: Run the harness**

Run: `godot --headless --path . -- --test --filter=harness`
Expected: line `PASS harness_test.gd::test_harness_runs_and_asserts` and `TESTS: 1 run, 0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/ shared/bootstrap.gd
git commit -m "M1: headless test harness (TestCase + runner + --test role)"
```

---

## Task 2: Quantize helpers

**Files:**
- Create: `shared/net/quantize.gd`, `tests/quantize_test.gd`

- [ ] **Step 1: Write `tests/quantize_test.gd`**

```gdscript
extends TestCase

func test_position_round_trip_mm() -> void:
	for v in [0.0, 1.234, -56.789, 499.999]:
		var enc := Quantize.enc_pos(v)
		assert_almost_eq(Quantize.dec_pos(enc), v, 0.001, "pos %s" % v)

func test_angle_round_trip() -> void:
	for a in [0.0, PI * 0.5, PI, PI * 1.999]:
		var enc := Quantize.enc_angle(a)
		assert_true(enc >= 0 and enc <= 0xFFFF, "u16 range")
		assert_almost_eq(Quantize.dec_angle(enc), a, 0.001, "angle %s" % a)

func test_angle_wraps_negative() -> void:
	# -0.1 rad wraps to ~TAU-0.1; decode stays within [0, TAU)
	var d := Quantize.dec_angle(Quantize.enc_angle(-0.1))
	assert_true(d >= 0.0 and d < TAU, "wrapped into range, got %s" % d)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=quantize`
Expected: FAIL — `Quantize` identifier not found.

- [ ] **Step 3: Write `shared/net/quantize.gd`**

```gdscript
class_name Quantize
extends Object
## Lossy fixed-point encoders for the wire. Positions to millimetres (i32),
## angles to u16 (65536 / 360°). See docs/specs/m1-netcode-core.md.

const POS_SCALE := 1000.0          # 1 mm resolution
const ANGLE_SCALE := 65536.0 / TAU

static func enc_pos(meters: float) -> int:
	return roundi(meters * POS_SCALE)

static func dec_pos(units: int) -> float:
	return float(units) / POS_SCALE

static func enc_angle(rad: float) -> int:
	return roundi(fposmod(rad, TAU) * ANGLE_SCALE) & 0xFFFF

static func dec_angle(u: int) -> float:
	return float(u) / ANGLE_SCALE
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=quantize`
Expected: 3 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/net/quantize.gd tests/quantize_test.gd
git commit -m "M1: quantize helpers (pos<->mm, angle<->u16)"
```

---

## Task 3: EntityState

**Files:**
- Create: `shared/sim/entity_state.gd`, `tests/entity_state_test.gd`

- [ ] **Step 1: Write `tests/entity_state_test.gd`**

```gdscript
extends TestCase

func test_clone_is_independent_copy() -> void:
	var a := EntityState.new()
	a.pos = Vector3(1, 0, 2)
	a.yaw = 1.5
	var b := a.clone()
	assert_eq(b.pos, Vector3(1, 0, 2))
	assert_almost_eq(b.yaw, 1.5)
	b.pos = Vector3(9, 9, 9)
	assert_eq(a.pos, Vector3(1, 0, 2), "mutating clone must not affect original")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=entity_state`
Expected: FAIL — `EntityState` not found.

- [ ] **Step 3: Write `shared/sim/entity_state.gd`**

```gdscript
class_name EntityState
extends RefCounted
## The replicated view of one entity. Snapshots are maps of id -> EntityState.

var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0

func clone() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	return e
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=entity_state`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/entity_state.gd tests/entity_state_test.gd
git commit -m "M1: EntityState (replicated per-entity view)"
```

---

## Task 4: Protocol message types

**Files:**
- Modify: `shared/net/protocol.gd`

- [ ] **Step 1: Add the new enum values**

In `shared/net/protocol.gd`, extend the `Msg` enum:

```gdscript
enum Msg {
	HELLO = 1,    ## client -> server: protocol version + display name
	WELCOME = 2,  ## server -> client: assigned peer id + server tick rate
	REJECT = 3,   ## server -> client: rejection reason (then disconnect)
	INPUT = 4,    ## client -> server: input command frame (see input_command.gd)
	SNAPSHOT = 5, ## server -> client: delta snapshot (see snapshot.gd)
}
```

- [ ] **Step 2: Verify it still parses**

Run: `godot --headless --path . -- --test --filter=harness`
Expected: PASS (no syntax error introduced), `0 failed`.

- [ ] **Step 3: Commit**

```bash
git add shared/net/protocol.gd
git commit -m "M1: add INPUT and SNAPSHOT message types"
```

---

## Task 5: Snapshot encode/decode (baseline + delta)

**Files:**
- Create: `shared/net/snapshot.gd`, `tests/snapshot_test.gd`

- [ ] **Step 1: Write `tests/snapshot_test.gd`**

```gdscript
extends TestCase

func _state(x: float, z: float, yaw: float) -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(x, 0, z)
	e.yaw = yaw
	return e

func test_keyframe_then_apply_reconstructs() -> void:
	# baseline empty -> all entities ENTER; client applying to {} must equal current.
	var current := {1: _state(10, 20, 0.5), 2: _state(-3, 4, 1.0)}
	var bytes := Snapshot.encode(7, 1, 0, 99, current, {})
	var view := {}
	var hdr := Snapshot.decode_apply(bytes, view)
	assert_eq(hdr["seq"], 1)
	assert_eq(hdr["last_input_tick"], 99)
	assert_eq(view.size(), 2)
	assert_almost_eq(view[1].pos.x, 10.0, 0.01)
	assert_almost_eq(view[2].pos.z, 4.0, 0.01)

func test_delta_changed_and_leave() -> void:
	var baseline := {1: _state(10, 20, 0.0), 2: _state(0, 0, 0.0)}
	# entity 1 moved, entity 2 left interest, entity 3 entered.
	var current := {1: _state(11, 20, 0.0), 3: _state(5, 5, 2.0)}
	var bytes := Snapshot.encode(8, 2, 1, 100, current, baseline)
	# client starts holding the baseline, applies the delta, must arrive at current.
	var view := {1: _state(10, 20, 0.0), 2: _state(0, 0, 0.0)}
	Snapshot.decode_apply(bytes, view)
	assert_eq(view.size(), 2, "entity 2 removed, 3 added")
	assert_true(view.has(1) and view.has(3))
	assert_true(not view.has(2))
	assert_almost_eq(view[1].pos.x, 11.0, 0.01)
	assert_almost_eq(view[3].pos.z, 5.0, 0.01)

func test_unchanged_entity_emits_no_record() -> void:
	var same := {1: _state(1, 1, 1.0)}
	var baseline := {1: _state(1, 1, 1.0)}
	var bytes := Snapshot.encode(9, 3, 2, 101, same, baseline)
	# header is 1+4*4 = 17 bytes, entity_count u16 = 0 -> total 19 bytes, no records.
	assert_eq(bytes.size(), 19, "no per-entity bytes when nothing changed")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=snapshot`
Expected: FAIL — `Snapshot` not found.

- [ ] **Step 3: Write `shared/net/snapshot.gd`**

```gdscript
class_name Snapshot
extends Object
## Baseline + delta snapshot codec. current/baseline are Dictionary[int id -> EntityState].
## A client holding `baseline` and applying the produced bytes arrives exactly at `current`.
## See docs/specs/m1-netcode-core.md.

# field_mask bits
const F_POS_X := 1
const F_POS_Y := 2
const F_POS_Z := 4
const F_YAW := 8
const F_ALL := 15

# per-record flags
const FLAG_ENTER := 1
const FLAG_LEAVE := 2
const FLAG_CHANGED := 4


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
			recs.put_u32(id)
			recs.put_u8(FLAG_CHANGED)
			_put_fields(recs, cur, mask)
		else:
			count += 1
			recs.put_u32(id)
			recs.put_u8(FLAG_ENTER)
			_put_fields(recs, cur, F_ALL)

	for id in baseline:
		if not current.has(id):
			count += 1
			recs.put_u32(id)
			recs.put_u8(FLAG_LEAVE)

	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.SNAPSHOT)
	buf.put_u32(server_tick)
	buf.put_u32(seq)
	buf.put_u32(baseline_seq)
	buf.put_u32(last_input_tick)
	buf.put_u16(count)
	if count > 0:
		buf.put_data(recs.data_array)
	return buf.data_array


## Applies the snapshot to `view` (mutated in place). Returns the header fields.
static func decode_apply(bytes: PackedByteArray, view: Dictionary) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)  # skip msg type
	var server_tick := buf.get_u32()
	var seq := buf.get_u32()
	var baseline_seq := buf.get_u32()
	var last_input_tick := buf.get_u32()
	var count := buf.get_u16()
	for _i in count:
		var id := buf.get_u32()
		var flags := buf.get_u8()
		if flags & FLAG_LEAVE:
			view.erase(id)
			continue
		var mask := buf.get_u8()
		var e: EntityState = view.get(id)
		if e == null:
			e = EntityState.new()
			view[id] = e
		if mask & F_POS_X: e.pos.x = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Y: e.pos.y = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Z: e.pos.z = Quantize.dec_pos(buf.get_32())
		if mask & F_YAW:   e.yaw = Quantize.dec_angle(buf.get_u16())
	return {
		"server_tick": server_tick, "seq": seq,
		"baseline_seq": baseline_seq, "last_input_tick": last_input_tick,
	}


static func _diff_mask(a: EntityState, b: EntityState) -> int:
	var m := 0
	if Quantize.enc_pos(a.pos.x) != Quantize.enc_pos(b.pos.x): m |= F_POS_X
	if Quantize.enc_pos(a.pos.y) != Quantize.enc_pos(b.pos.y): m |= F_POS_Y
	if Quantize.enc_pos(a.pos.z) != Quantize.enc_pos(b.pos.z): m |= F_POS_Z
	if Quantize.enc_angle(a.yaw) != Quantize.enc_angle(b.yaw): m |= F_YAW
	return m


static func _put_fields(buf: StreamPeerBuffer, e: EntityState, mask: int) -> void:
	buf.put_u8(mask)
	if mask & F_POS_X: buf.put_32(Quantize.enc_pos(e.pos.x))
	if mask & F_POS_Y: buf.put_32(Quantize.enc_pos(e.pos.y))
	if mask & F_POS_Z: buf.put_32(Quantize.enc_pos(e.pos.z))
	if mask & F_YAW:   buf.put_u16(Quantize.enc_angle(e.yaw))
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=snapshot`
Expected: 3 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/net/snapshot.gd tests/snapshot_test.gd
git commit -m "M1: snapshot codec (baseline+delta, enter/changed/leave)"
```

---

## Task 6: InputCommand encode/decode

**Files:**
- Create: `shared/net/input_command.gd`, `tests/input_command_test.gd`

- [ ] **Step 1: Write `tests/input_command_test.gd`**

```gdscript
extends TestCase

func test_input_round_trip() -> void:
	var bytes := InputCommand.encode(123, 45, 1.0, -0.5, 1.2, -0.3, 0b101)
	var d := InputCommand.decode(bytes)
	assert_eq(d["client_tick"], 123)
	assert_eq(d["ack_seq"], 45)
	assert_almost_eq(d["move_x"], 1.0, 0.001)
	assert_almost_eq(d["move_y"], -0.5, 0.001)
	assert_almost_eq(d["yaw"], 1.2, 0.001)
	assert_eq(d["buttons"], 0b101)

func test_move_is_clamped_to_unit() -> void:
	var d := InputCommand.decode(InputCommand.encode(0, 0, 5.0, 0.0, 0.0, 0.0, 0))
	assert_almost_eq(d["move_x"], 1.0, 0.001, "over-unit input clamps to 1.0")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=input_command`
Expected: FAIL — `InputCommand` not found.

- [ ] **Step 3: Write `shared/net/input_command.gd`**

```gdscript
class_name InputCommand
extends Object
## Client -> server input frame. move_x/move_y are intent in [-1,1] (i16-quantized);
## yaw/pitch are angles (u16). See docs/specs/m1-netcode-core.md.

const MOVE_SCALE := 32767.0

static func encode(client_tick: int, ack_seq: int, move_x: float, move_y: float,
		yaw: float, pitch: float, buttons: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.INPUT)
	buf.put_u32(client_tick)
	buf.put_u32(ack_seq)
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
		"move_x": float(buf.get_16()) / MOVE_SCALE,
		"move_y": float(buf.get_16()) / MOVE_SCALE,
		"yaw": Quantize.dec_angle(buf.get_u16()),
		"pitch": Quantize.dec_angle(buf.get_u16()),
		"buttons": buf.get_u8(),
	}
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=input_command`
Expected: 2 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/net/input_command.gd tests/input_command_test.gd
git commit -m "M1: input command frame codec"
```

---

## Task 7: Pawn movement

**Files:**
- Create: `shared/sim/pawn.gd`, `tests/pawn_test.gd`

> Movement is **kinematic in the shared sim** (not Godot physics): integrate over a flat ground plane (y clamped to 0) inside a square world bound. This keeps movement rules in `shared/` so client prediction mirrors server authority exactly, and keeps the 128p perf cost in the netcode where the risk actually is.

- [ ] **Step 1: Write `tests/pawn_test.gd`**

```gdscript
extends TestCase

func test_moves_along_input_at_speed() -> void:
	var p := Pawn.new(1)
	p.step(1.0, 1.0, 0.0, 0.0)  # 1 second, full +x
	assert_almost_eq(p.pos.x, Pawn.SPEED, 0.001, "travels SPEED metres in 1s")
	assert_almost_eq(p.pos.y, 0.0, 0.001, "stays on ground")

func test_diagonal_input_is_normalized() -> void:
	var p := Pawn.new(1)
	p.step(1.0, 1.0, 1.0, 0.0)
	assert_almost_eq(p.pos.length(), Pawn.SPEED, 0.01, "diagonal not faster than straight")

func test_clamped_to_world_bounds() -> void:
	var p := Pawn.new(1)
	p.pos = Vector3(Pawn.WORLD_HALF - 1.0, 0, 0)
	p.step(1.0, 1.0, 0.0, 0.0)
	assert_almost_eq(p.pos.x, Pawn.WORLD_HALF, 0.001, "cannot exceed world bound")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=pawn`
Expected: FAIL — `Pawn` not found.

- [ ] **Step 3: Write `shared/sim/pawn.gd`**

```gdscript
class_name Pawn
extends RefCounted
## Kinematic player pawn. Authoritative on the server; predicted on the client.
## Movement is world-space for M1 (no yaw-relative strafe yet). See M1 spec.

const SPEED := 6.0          # metres / second
const WORLD_HALF := 500.0   # square world bound (metres)

var id: int
var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0

func _init(p_id: int = 0) -> void:
	id = p_id

func step(dt: float, move_x: float, move_y: float, p_yaw: float) -> void:
	yaw = p_yaw
	var dir := Vector3(move_x, 0.0, move_y)
	if dir.length() > 1.0:
		dir = dir.normalized()
	pos += dir * SPEED * dt
	pos.y = 0.0
	pos.x = clampf(pos.x, -WORLD_HALF, WORLD_HALF)
	pos.z = clampf(pos.z, -WORLD_HALF, WORLD_HALF)

func to_state() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	return e
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=pawn`
Expected: 3 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/pawn.gd tests/pawn_test.gd
git commit -m "M1: kinematic Pawn movement over flat ground"
```

---

## Task 8: World registry

**Files:**
- Create: `shared/sim/world.gd`, `tests/world_test.gd`

- [ ] **Step 1: Write `tests/world_test.gd`**

```gdscript
extends TestCase

func test_spawn_get_despawn() -> void:
	var w := World.new()
	var p := w.spawn(5)
	assert_eq(p.id, 5)
	assert_true(w.get_pawn(5) == p)
	w.despawn(5)
	assert_true(w.get_pawn(5) == null)

func test_state_map_snapshots_all_pawns() -> void:
	var w := World.new()
	w.spawn(1).pos = Vector3(2, 0, 3)
	w.spawn(2).pos = Vector3(-1, 0, 0)
	var m := w.state_map()
	assert_eq(m.size(), 2)
	assert_almost_eq(m[1].pos.x, 2.0, 0.001)
	# mutating the state map must not affect the live pawn
	m[1].pos = Vector3(99, 0, 0)
	assert_almost_eq(w.get_pawn(1).pos.x, 2.0, 0.001)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=world`
Expected: FAIL — `World` not found.

- [ ] **Step 3: Write `shared/sim/world.gd`**

```gdscript
class_name World
extends RefCounted
## Authoritative entity registry. id -> Pawn.

var pawns: Dictionary = {}

func spawn(id: int) -> Pawn:
	var p := Pawn.new(id)
	pawns[id] = p
	return p

func despawn(id: int) -> void:
	pawns.erase(id)

func get_pawn(id: int) -> Pawn:
	return pawns.get(id)

## A fresh id -> EntityState map (decoupled clones, safe to store/send).
func state_map() -> Dictionary:
	var m := {}
	for id in pawns:
		m[id] = (pawns[id] as Pawn).to_state()
	return m
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=world`
Expected: 2 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/world.gd tests/world_test.gd
git commit -m "M1: World entity registry"
```

---

## Task 9: SimLoop step

**Files:**
- Modify: `shared/sim/sim_loop.gd`
- Create: `tests/sim_loop_test.gd`

- [ ] **Step 1: Write `tests/sim_loop_test.gd`**

```gdscript
extends TestCase

func test_step_advances_pawns_from_inputs() -> void:
	var sim := SimLoop.new()
	sim.world.spawn(1)
	sim.world.spawn(2)
	var inputs := {
		1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0},
		# pawn 2 has no input this tick -> must not move
	}
	sim.step(inputs)
	assert_eq(sim.tick, 1)
	assert_almost_eq(sim.world.get_pawn(1).pos.x, Pawn.SPEED * SimLoop.DT, 0.0001)
	assert_almost_eq(sim.world.get_pawn(2).pos.x, 0.0, 0.0001, "no input = no move")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=sim_loop`
Expected: FAIL — `SimLoop.new()` has no `world`, or `step(inputs)` signature mismatch.

- [ ] **Step 3: Rewrite `shared/sim/sim_loop.gd`**

Replace the entire file with:

```gdscript
class_name SimLoop
extends RefCounted
## Fixed-timestep authoritative simulation. The SAME code runs on the server
## (authority) and the client (prediction) so they cannot diverge. See AGENTS.md §7.

const DT := 1.0 / 30.0   # 30 Hz

var tick: int = 0
var world := World.new()

## inputs: Dictionary[int id -> {move_x, move_y, yaw}]. Pawns with no input hold still.
func step(inputs: Dictionary) -> void:
	for id in world.pawns:
		var inp = inputs.get(id)
		if inp == null:
			continue
		(world.pawns[id] as Pawn).step(DT, inp["move_x"], inp["move_y"], inp["yaw"])
	tick += 1
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=sim_loop`
Expected: PASS, `0 failed`. Also run the full suite to catch regressions: `godot --headless --path . -- --test` → `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/sim_loop.gd tests/sim_loop_test.gd
git commit -m "M1: SimLoop steps World from per-pawn inputs"
```

---

## Task 10: InterestGrid

**Files:**
- Create: `shared/sim/interest_grid.gd`, `tests/interest_grid_test.gd`

- [ ] **Step 1: Write `tests/interest_grid_test.gd`**

```gdscript
extends TestCase

func test_query_returns_only_within_radius() -> void:
	var grid := InterestGrid.new(64.0)
	var positions := {
		1: Vector3(0, 0, 0),
		2: Vector3(50, 0, 0),     # within 100
		3: Vector3(300, 0, 0),    # outside 100
	}
	for id in positions:
		grid.insert(id, positions[id])
	var ids := grid.query(Vector3.ZERO, 100.0, positions)
	ids.sort()
	assert_eq(ids, [1, 2])

func test_clear_empties_grid() -> void:
	var grid := InterestGrid.new(64.0)
	grid.insert(1, Vector3.ZERO)
	grid.clear()
	var positions := {1: Vector3.ZERO}
	assert_eq(grid.query(Vector3.ZERO, 100.0, positions), [])
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=interest_grid`
Expected: FAIL — `InterestGrid` not found.

- [ ] **Step 3: Write `shared/sim/interest_grid.gd`**

```gdscript
class_name InterestGrid
extends RefCounted
## Uniform spatial hash over the XZ plane. Rebuilt each tick (insert), then queried
## per client. query() scans the cell neighbourhood covering `radius` then filters by
## exact distance. See docs/specs/m1-netcode-core.md.

var cell_size: float = 64.0
var _cells: Dictionary = {}   # Vector2i -> Array[int]

func _init(p_cell_size := 64.0) -> void:
	cell_size = p_cell_size

func clear() -> void:
	_cells.clear()

func insert(id: int, pos: Vector3) -> void:
	var k := _key(pos)
	if not _cells.has(k):
		_cells[k] = []
	_cells[k].append(id)

## positions: Dictionary[int id -> Vector3] for exact-distance filtering.
func query(center: Vector3, radius: float, positions: Dictionary) -> Array:
	var out := []
	var ck := _key(center)
	var span := int(ceil(radius / cell_size))
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var arr = _cells.get(Vector2i(ck.x + dx, ck.y + dz))
			if arr == null:
				continue
			for id in arr:
				if center.distance_to(positions[id]) <= radius:
					out.append(id)
	return out

func _key(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / cell_size), floori(pos.z / cell_size))
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=interest_grid`
Expected: 2 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/interest_grid.gd tests/interest_grid_test.gd
git commit -m "M1: InterestGrid uniform spatial hash + radius query"
```

---

## Task 11: Telemetry counters

**Files:**
- Create: `shared/telemetry.gd`, `tests/telemetry_test.gd`

- [ ] **Step 1: Write `tests/telemetry_test.gd`**

```gdscript
extends TestCase

func test_mean_and_p99() -> void:
	var t := Telemetry.new()
	for i in range(1, 101):
		t.record_tick_ms(float(i))   # 1..100
	assert_almost_eq(t.mean_tick_ms(), 50.5, 0.01)
	assert_almost_eq(t.p99_tick_ms(), 100.0, 0.001)

func test_bytes_accumulate_and_reset() -> void:
	var t := Telemetry.new()
	t.add_bytes(1, 100)
	t.add_bytes(1, 50)
	t.add_bytes(2, 10)
	assert_eq(int(t.bytes_sent_per_client[1]), 150)
	t.reset_window()
	assert_eq(t.bytes_sent_per_client.size(), 0)
	assert_almost_eq(t.mean_tick_ms(), 0.0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=telemetry`
Expected: FAIL — `Telemetry` not found.

- [ ] **Step 3: Write `shared/telemetry.gd`**

```gdscript
class_name Telemetry
extends RefCounted
## Rolling per-window counters. The server logs and resets these once per second;
## the printed lines are the recorded evidence for the M1 gate.

var _tick_samples: Array[float] = []
var bytes_sent_per_client: Dictionary = {}   # id -> int (this window)
var starvation: int = 0

func record_tick_ms(ms: float) -> void:
	_tick_samples.append(ms)

func add_bytes(client_id: int, n: int) -> void:
	bytes_sent_per_client[client_id] = int(bytes_sent_per_client.get(client_id, 0)) + n

func mean_tick_ms() -> float:
	if _tick_samples.is_empty():
		return 0.0
	var s := 0.0
	for v in _tick_samples:
		s += v
	return s / _tick_samples.size()

func p99_tick_ms() -> float:
	if _tick_samples.is_empty():
		return 0.0
	var sorted := _tick_samples.duplicate()
	sorted.sort()
	return sorted[mini(int(ceil(0.99 * sorted.size())), sorted.size() - 1)]

## Peak bytes/sec for any single client this window (window assumed ~1s).
func peak_bytes_per_client() -> int:
	var peak := 0
	for id in bytes_sent_per_client:
		peak = maxi(peak, int(bytes_sent_per_client[id]))
	return peak

func total_bytes() -> int:
	var sum := 0
	for id in bytes_sent_per_client:
		sum += int(bytes_sent_per_client[id])
	return sum

func reset_window() -> void:
	_tick_samples.clear()
	bytes_sent_per_client.clear()
	starvation = 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=telemetry`
Expected: 2 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/telemetry.gd tests/telemetry_test.gd
git commit -m "M1: telemetry counters (tick time, bandwidth, starvation)"
```

---

## Task 12: Client prediction + reconciliation

**Files:**
- Create: `client/prediction.gd`, `tests/prediction_test.gd`

- [ ] **Step 1: Write `tests/prediction_test.gd`**

```gdscript
extends TestCase

func test_replay_converges_after_authoritative_correction() -> void:
	var pred := Prediction.new()
	# client predicts 3 ticks of +x movement, ticks 1,2,3
	pred.record_input(1, 1.0, 0.0, 0.0)
	pred.record_input(2, 1.0, 0.0, 0.0)
	pred.record_input(3, 1.0, 0.0, 0.0)
	var predicted_x := pred.predicted.pos.x
	# server confirms through tick 1 at the matching authoritative position,
	# but with a small correction (e.g. server placed us 0.5m back).
	var auth := Vector3(Pawn.SPEED * SimLoop.DT - 0.5, 0, 0)
	pred.reconcile(auth, 0.0, 1)
	# inputs 2 and 3 remain and are replayed from the authoritative base.
	assert_eq(pred.pending.size(), 2, "ticks 2,3 still pending")
	var expected := auth.x + 2.0 * Pawn.SPEED * SimLoop.DT
	assert_almost_eq(pred.predicted.pos.x, expected, 0.0001)
	assert_true(absf(pred.predicted.pos.x - predicted_x) > 0.0, "correction applied")

func test_full_ack_clears_pending() -> void:
	var pred := Prediction.new()
	pred.record_input(1, 1.0, 0.0, 0.0)
	pred.reconcile(Vector3(1, 0, 0), 0.0, 1)
	assert_eq(pred.pending.size(), 0)
	assert_almost_eq(pred.predicted.pos.x, 1.0, 0.0001, "no replay, sits at authoritative")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=prediction`
Expected: FAIL — `Prediction` not found.

- [ ] **Step 3: Write `client/prediction.gd`**

```gdscript
class_name Prediction
extends RefCounted
## Client-side prediction + server reconciliation for the local pawn.
## Predicts immediately on input; when the authoritative state arrives it snaps to
## it and replays inputs the server hasn't consumed yet. See M1 spec.

var predicted := Pawn.new(0)
var pending: Array = []   # [{tick, move_x, move_y, yaw}], ascending tick

func record_input(client_tick: int, move_x: float, move_y: float, yaw: float) -> void:
	predicted.step(SimLoop.DT, move_x, move_y, yaw)
	pending.append({"tick": client_tick, "move_x": move_x, "move_y": move_y, "yaw": yaw})

## Apply authoritative own-pawn state. last_input_tick = last input the server consumed.
func reconcile(auth_pos: Vector3, auth_yaw: float, last_input_tick: int) -> void:
	var kept := []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	for inp in pending:
		predicted.step(SimLoop.DT, inp["move_x"], inp["move_y"], inp["yaw"])
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=prediction`
Expected: 2 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add client/prediction.gd tests/prediction_test.gd
git commit -m "M1: client prediction + reconciliation"
```

---

## Task 13: Remote-entity interpolation buffer

**Files:**
- Create: `client/interpolation.gd`, `tests/interpolation_test.gd`

- [ ] **Step 1: Write `tests/interpolation_test.gd`**

```gdscript
extends TestCase

func _view(id: int, x: float) -> Dictionary:
	var e := EntityState.new()
	e.pos = Vector3(x, 0, 0)
	return {id: e}

func test_interpolates_between_two_snapshots() -> void:
	var interp := Interpolation.new()
	interp.push(1.0, _view(1, 0.0))
	interp.push(1.1, _view(1, 10.0))   # 10m over 100ms
	# render time = now - DELAY(0.1). now=1.15 -> render at 1.05 = halfway.
	var out := interp.sample(1.15)
	assert_true(out.has(1))
	assert_almost_eq(out[1].pos.x, 5.0, 0.01, "halfway between 0 and 10")

func test_clamps_to_latest_when_render_time_past_newest() -> void:
	var interp := Interpolation.new()
	interp.push(1.0, _view(1, 0.0))
	interp.push(1.1, _view(1, 10.0))
	var out := interp.sample(5.0)  # way past
	assert_almost_eq(out[1].pos.x, 10.0, 0.01)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=interpolation`
Expected: FAIL — `Interpolation` not found.

- [ ] **Step 3: Write `client/interpolation.gd`**

```gdscript
class_name Interpolation
extends RefCounted
## Buffers recent remote-entity views and samples them ~DELAY seconds in the past,
## lerping positions between the two surrounding snapshots to hide jitter/loss.

const DELAY := 0.1   # 100 ms render delay
const MAX_BUFFER := 32

var _buf: Array = []   # [{time, view: Dictionary[id->EntityState]}], ascending time

func push(time: float, view: Dictionary) -> void:
	_buf.append({"time": time, "view": view})
	while _buf.size() > MAX_BUFFER:
		_buf.pop_front()

## Returns an interpolated id -> EntityState map at (now - DELAY).
func sample(now: float) -> Dictionary:
	if _buf.is_empty():
		return {}
	var t := now - DELAY
	if t <= _buf[0]["time"]:
		return _clone_view(_buf[0]["view"])
	if t >= _buf[_buf.size() - 1]["time"]:
		return _clone_view(_buf[_buf.size() - 1]["view"])
	for i in range(_buf.size() - 1):
		var a = _buf[i]
		var b = _buf[i + 1]
		if t >= a["time"] and t <= b["time"]:
			var span: float = b["time"] - a["time"]
			var f: float = 0.0 if span <= 0.0 else (t - a["time"]) / span
			return _lerp_views(a["view"], b["view"], f)
	return _clone_view(_buf[_buf.size() - 1]["view"])

func _lerp_views(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out := {}
	for id in b:
		var eb: EntityState = b[id]
		var e := EntityState.new()
		if a.has(id):
			var ea: EntityState = a[id]
			e.pos = ea.pos.lerp(eb.pos, f)
			e.yaw = lerp_angle(ea.yaw, eb.yaw, f)
		else:
			e.pos = eb.pos
			e.yaw = eb.yaw
		out[id] = e
	return out

func _clone_view(view: Dictionary) -> Dictionary:
	var out := {}
	for id in view:
		out[id] = (view[id] as EntityState).clone()
	return out
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter=interpolation`
Expected: 2 PASS lines, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add client/interpolation.gd tests/interpolation_test.gd
git commit -m "M1: remote-entity interpolation buffer"
```

---

## Task 14: Server authoritative tick loop

**Files:**
- Modify: `server/server_main.gd`

This wires the shared pieces into the authoritative loop: spawn a pawn per welcomed peer, buffer inputs, step the sim, send per-client delta snapshots against each client's last acked snapshot, and log telemetry each second.

- [ ] **Step 1: Rewrite `server/server_main.gd`**

```gdscript
extends Node
## Dedicated authoritative server. 30 Hz. Spawns a pawn per peer, consumes one input
## per client per tick, steps the shared SimLoop, and sends per-client delta snapshots.
## See docs/specs/m1-netcode-core.md.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128
const INTEREST_RADIUS := 250.0
const CELL_SIZE := 64.0

var _net: NetHost
var _port := 27015
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _tele := Telemetry.new()
var _next_id := 1
var _tele_accum := 0.0

# id -> client record
#   { peer, queued_input (Dictionary|null), last_input (Dictionary|null),
#     last_input_tick:int, last_acked_seq:int, next_seq:int,
#     history: Dictionary[seq -> Dictionary[id->EntityState]] }
var _clients := {}
var _peer_to_id := {}


func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))


func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)  # wait for HELLO before spawning
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)])
		get_tree().quit(1)
		return
	print("[server] listening on %d, tick=%dHz, max=%d" % [_port, TICK_RATE, MAX_PLAYERS])


func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	_consume_inputs_and_step()
	_send_snapshots()
	_tele.record_tick_ms(float(Time.get_ticks_usec() - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry()
		_tele_accum = 0.0


func _consume_inputs_and_step() -> void:
	var inputs := {}
	for id in _clients:
		var c = _clients[id]
		var inp = c["queued_input"]
		if inp == null:
			inp = c["last_input"]
			if inp != null:
				_tele.starvation += 1
		if inp != null:
			inputs[id] = inp
			c["last_input"] = inp
			c["last_input_tick"] = inp["client_tick"]
		c["queued_input"] = null
	_sim.step(inputs)


func _send_snapshots() -> void:
	var state := _sim.world.state_map()      # id -> EntityState (fresh clones)
	var positions := {}
	_grid.clear()
	for id in state:
		positions[id] = state[id].pos
		_grid.insert(id, state[id].pos)

	for id in _clients:
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null:
			continue
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, positions)
		var current := {}
		for vid in ids:
			current[vid] = state[vid]
		var baseline = c["history"].get(c["last_acked_seq"], {})
		var seq: int = c["next_seq"]
		var bytes := Snapshot.encode(_sim.tick, seq, c["last_acked_seq"],
			c["last_input_tick"], current, baseline)
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)  # unreliable-sequenced
		c["history"][seq] = current
		c["next_seq"] = seq + 1
		_tele.add_bytes(id, bytes.size())


func _on_packet(peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.HELLO:
			_handle_hello(peer, bytes)
		Protocol.Msg.INPUT:
			_handle_input(peer, bytes)
		_:
			pass


func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var r := Protocol.body_reader(bytes)
	var ver := r.get_u16()
	var pname := r.get_utf8_string()
	if ver != Protocol.VERSION:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("version mismatch"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later()
		return
	if _clients.size() >= MAX_PLAYERS:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("server full"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later()
		return
	var id := _next_id
	_next_id += 1
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "queued_input": null, "last_input": null,
		"last_input_tick": 0, "last_acked_seq": 0, "next_seq": 1, "history": {},
	}
	_sim.world.spawn(id)
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') — %d peers" % [id, pname, _clients.size()])


func _handle_input(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id):
		return
	var d := InputCommand.decode(bytes)
	var c = _clients[id]
	# stale/duplicate guard
	if c["queued_input"] != null and d["client_tick"] <= c["queued_input"]["client_tick"]:
		return
	c["queued_input"] = d
	# process the piggybacked snapshot ack: advance baseline, prune older history.
	var ack: int = d["ack_seq"]
	if ack > c["last_acked_seq"]:
		c["last_acked_seq"] = ack
		for s in c["history"].keys():
			if s < ack:
				c["history"].erase(s)


func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	_peer_to_id.erase(peer)
	if id != 0:
		_clients.erase(id)
		_sim.world.despawn(id)
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])


func _log_telemetry() -> void:
	var n := _clients.size()
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	print("[telemetry] players=%d tick_mean=%.2fms tick_p99=%.2fms peak=%dB/s agg=%.1fMbit/s starv=%d"
		% [n, _tele.mean_tick_ms(), _tele.p99_tick_ms(), _tele.peak_bytes_per_client(), mbit, _tele.starvation])
	_tele.reset_window()
```

- [ ] **Step 2: Smoke-run the server alone (no crash on startup)**

Run: `timeout 3 godot --headless --path . -- --server --port=27120 ; echo "exit=$?"`
Expected: prints `[server] listening on 27120 ...` and at least one `[telemetry] players=0 ...` line; exit from the timeout (124) is fine — it means it ran without crashing.

- [ ] **Step 3: Commit**

```bash
git add server/server_main.gd
git commit -m "M1: authoritative server tick loop with per-client delta snapshots"
```

---

## Task 15: Client send-input + apply-snapshot wiring

**Files:**
- Modify: `client/client_main.gd`

Headless for M1 (no rendering yet). The client sends a neutral input each tick (real input devices arrive with M2 rendering), acks snapshots, reconciles its own pawn via `Prediction`, and feeds remote entities into `Interpolation`. It logs the first WELCOME and periodic state so a human can confirm replication.

- [ ] **Step 1: Rewrite `client/client_main.gd`**

```gdscript
extends Node
## Client. M1 (headless): connect, send input frames, ack + apply snapshots,
## reconcile own pawn, interpolate remotes. Rendering/real input arrive in M2.

const Protocol := preload("res://shared/net/protocol.gd")

var _net: NetHost
var _server_ip := "127.0.0.1"
var _port := 27015
var _player_name := "Player"
var _peer: ENetPacketPeer

var my_id := 0
var _client_tick := 0
var _last_snapshot_seq := 0
var _view := {}                     # id -> EntityState (authoritative, pre-interp)
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
		push_error("[client] failed to create client host")
		return
	print("[client] connecting to %s:%d ..." % [_server_ip, _port])


func _physics_process(delta: float) -> void:
	_net.poll()
	_elapsed += delta
	if my_id != 0:
		_client_tick += 1
		# M1: neutral input (no input device headless). M2 reads real input here.
		var move_x := 0.0
		var move_y := 0.0
		var yaw := 0.0
		_pred.record_input(_client_tick, move_x, move_y, yaw)
		_net.send_to(_peer, NetHost.CHANNEL_INPUT,
			InputCommand.encode(_client_tick, _last_snapshot_seq, move_x, move_y, yaw, 0.0, 0),
			0)  # unreliable-sequenced
	_log_accum += delta
	if _log_accum >= 2.0 and my_id != 0:
		print("[client] id=%d tick=%d view_entities=%d pred_pos=%s"
			% [my_id, _client_tick, _view.size(), str(_pred.predicted.pos)])
		_log_accum = 0.0


func _on_connected(peer: ENetPacketPeer) -> void:
	_net.send_to(peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_hello(_player_name), ENetPacketPeer.FLAG_RELIABLE)


func _on_packet(_peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var r := Protocol.body_reader(bytes)
			my_id = r.get_u32()
			print("[client] WELCOME — id=%d, server tick=%dHz" % [my_id, r.get_u16()])
		Protocol.Msg.REJECT:
			print("[client] REJECTED: %s" % Protocol.body_reader(bytes).get_utf8_string())
		Protocol.Msg.SNAPSHOT:
			_apply_snapshot(bytes)


func _apply_snapshot(bytes: PackedByteArray) -> void:
	var hdr := Snapshot.decode_apply(bytes, _view)
	_last_snapshot_seq = maxi(_last_snapshot_seq, int(hdr["seq"]))
	# reconcile own pawn if present in the authoritative view
	if _view.has(my_id):
		var mine: EntityState = _view[my_id]
		_pred.reconcile(mine.pos, mine.yaw, int(hdr["last_input_tick"]))
	# feed remote entities (everyone but me) into interpolation
	var remotes := {}
	for id in _view:
		if id != my_id:
			remotes[id] = (_view[id] as EntityState).clone()
	_interp.push(_elapsed, remotes)
```

- [ ] **Step 2: Smoke test client against server (handshake + snapshots flow)**

Run:
```bash
timeout 6 godot --headless --path . -- --server --port=27121 > /tmp/bf_s.log 2>&1 &
sleep 2
timeout 4 godot --headless --path . -- --connect=127.0.0.1 --port=27121 --name=c1 > /tmp/bf_c.log 2>&1
grep -E "WELCOME|view_entities" /tmp/bf_c.log
```
Expected: a `WELCOME — id=...` line and at least one `view_entities=` line (the client received snapshots). (`view_entities` may be 0 if it's the only player — that's fine; the snapshot path still ran without error.)

- [ ] **Step 3: Commit**

```bash
git add client/client_main.gd
git commit -m "M1: client input send + snapshot apply/reconcile/interpolate"
```

---

## Task 16: Bot driver random-walk input

**Files:**
- Modify: `bots/bot_driver.gd`

Each bot sends a random-walk input each tick and acks snapshots cheaply (reads only the header seq, discards the body) so 128 stay light in one process.

- [ ] **Step 1: Rewrite `bots/bot_driver.gd`**

```gdscript
extends Node
## Headless bot fleet. Each bot is a real client connection that sends random-walk
## input and acks snapshots without decoding the body (bots are load, not renderers).

const Protocol := preload("res://shared/net/protocol.gd")

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
		"tick": 0, "last_seq": 0, "heading": randf() * TAU, "turn_timer": 0.0,
	}
	net.peer_connected.connect(func(peer: ENetPacketPeer) -> void:
		bot["peer"] = peer
		net.send_to(peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_hello("bot-%d" % index), ENetPacketPeer.FLAG_RELIABLE))
	net.peer_disconnected.connect(func(_p: ENetPacketPeer) -> void: bot["connected"] = false)
	net.packet_received.connect(func(_p: ENetPacketPeer, _ch: int, bytes: PackedByteArray) -> void:
		_on_packet(bot, bytes))
	net.start_client(_server_ip, _port)
	_bots.append(bot)


func _physics_process(delta: float) -> void:
	for bot in _bots:
		(bot["net"] as NetHost).poll()
		if not bot["connected"]:
			continue
		bot["tick"] += 1
		bot["turn_timer"] -= delta
		if bot["turn_timer"] <= 0.0:
			bot["heading"] = randf() * TAU
			bot["turn_timer"] = randf_range(0.5, 2.0)
		var move_x: float = cos(bot["heading"])
		var move_y: float = sin(bot["heading"])
		var bytes := InputCommand.encode(bot["tick"], bot["last_seq"], move_x, move_y, bot["heading"], 0.0, 0)
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, bytes, 0)


func _on_packet(bot: Dictionary, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var r := Protocol.body_reader(bytes)
			bot["id"] = r.get_u32()
			bot["connected"] = true
			print("[bots] bot %d connected (id %d) — %d/%d connected"
				% [bot["index"], bot["id"], _connected_count(), _bot_count])
		Protocol.Msg.SNAPSHOT:
			# cheap ack: read only seq (header bytes 9..12), ignore the body.
			var buf := StreamPeerBuffer.new()
			buf.data_array = bytes
			buf.seek(5)  # skip type(1) + server_tick(4)
			bot["last_seq"] = buf.get_u32()


func _connected_count() -> int:
	var n := 0
	for b in _bots:
		if b["connected"]:
			n += 1
	return n
```

- [ ] **Step 2: Smoke test 4 bots move the sim**

Run:
```bash
timeout 8 godot --headless --path . -- --server --port=27122 > /tmp/bf_s.log 2>&1 &
sleep 2
timeout 5 godot --headless --path . -- --bots --bot-count=4 --port=27122 > /tmp/bf_b.log 2>&1
grep -E "4/4 connected" /tmp/bf_b.log
grep -E "players=4" /tmp/bf_s.log | tail -1
```
Expected: `4/4 connected` in bot log, and a `[telemetry] players=4 ...` line in server log with a small `tick_mean`.

- [ ] **Step 3: Commit**

```bash
git add bots/bot_driver.gd
git commit -m "M1: bot driver random-walk input + cheap snapshot ack"
```

---

## Task 17: M1 load-test gate (128 bots @ 30 Hz)

**Files:**
- Create: `ci/m1_load_test.sh`

- [ ] **Step 1: Write `ci/m1_load_test.sh`**

```bash
#!/usr/bin/env bash
# M1 gate: run the server + 128 bots headless for ~30s, parse the last telemetry
# line, and assert mean server tick < 33.3 ms (30 Hz held). Exit non-zero on breach.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27130}"
BOTS="${BOTS:-128}"
DURATION="${DURATION:-30}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

echo "[m1] server on $PORT"
"$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m1] $BOTS bots"
"$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

sleep "$DURATION"

# last telemetry line at full population
line="$(grep "players=$BOTS" "$server_log" | tail -1)"
echo "--- last telemetry ---"
echo "$line"

if [ -z "$line" ]; then
	echo "FAIL: never reached $BOTS players"; exit 1
fi

mean="$(echo "$line" | sed -n 's/.*tick_mean=\([0-9.]*\)ms.*/\1/p')"
echo "[m1] mean tick = ${mean}ms (budget ${TICK_BUDGET_MS}ms)"
if awk "BEGIN{exit !($mean < $TICK_BUDGET_MS)}"; then
	echo "M1 GATE: PASS"; exit 0
else
	echo "M1 GATE: FAIL (mean tick $mean >= $TICK_BUDGET_MS)"; exit 1
fi
```

- [ ] **Step 2: Make executable and run the gate**

Run:
```bash
chmod +x ci/m1_load_test.sh
ci/m1_load_test.sh
```
Expected: a `[telemetry] players=128 ...` line and `M1 GATE: PASS` with mean tick well under 33.3 ms. If it FAILs, profile per the spec's interest-management optimization note (cache/stagger interest recompute) before relaxing the budget — the budget is the de-risking forcing function.

- [ ] **Step 3: Record evidence in the milestone and update the board**

Edit `docs/milestones/M1-netcode-core.md` "Evidence" section with the budget targets and the actual telemetry line. Set its status to `done`. In `docs/TASKS.md` set M1 → `done ✅` and M2 → `next`.

- [ ] **Step 4: Commit**

```bash
git add ci/m1_load_test.sh docs/milestones/M1-netcode-core.md docs/TASKS.md
git commit -m "M1: load-test gate (128 bots @ 30 Hz) + record evidence"
```

---

## Self-review

**Spec coverage:**
- Wire protocol (INPUT/SNAPSHOT, quantization) → Tasks 2, 4, 5, 6 ✓
- Authoritative 30 Hz tick + input jitter buffer + starvation repeat → Task 14 ✓
- Per-client baseline+delta snapshots + acks + history pruning → Tasks 5, 14 ✓
- Interest management (uniform grid, radius query) → Tasks 10, 14 ✓
- Prediction/reconciliation → Task 12, wired in 15 ✓
- Interpolation → Task 13, wired in 15 ✓
- Telemetry → Task 11, logged in 14 ✓
- Test pawn over flat ground via shared sim → Tasks 7, 8, 9 ✓
- Bots random-walk + cheap ack → Task 16 ✓
- 128p @ 30 Hz gate → Task 17 ✓
- Error cases: lost snapshot (baseline held until acked), keyframe-on-no-ack (baseline `{}` → ENTER-all), input starvation (repeat last), late/dup input (tick guard), disconnect (despawn + LEAVE) → Tasks 5, 14 ✓
- Explicitly deferred (no M1 task, by design): lag-comp history buffer, weapons, full map, clock-sync, bit-packing ✓

**Type/name consistency:** `Snapshot.encode(server_tick, seq, baseline_seq, last_input_tick, current, baseline)` and `decode_apply(bytes, view)→hdr{server_tick,seq,baseline_seq,last_input_tick}` used identically in Tasks 5/14/15. `Pawn.step(dt, move_x, move_y, yaw)` consistent across Tasks 7/9/12. `SimLoop.DT`, `SimLoop.step(inputs)`, `world` consistent across Tasks 9/12/14. `InterestGrid.query(center, radius, positions)` consistent Tasks 10/14. Channels (`CHANNEL_CONTROL/SNAPSHOT/INPUT`) from M0 `NetHost`. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code. ✓

**Known scaling note (not a blocker):** Task 14 rebuilds the interest grid once/tick and queries per client (O(players × neighbourhood)); if Task 17's gate fails on tick time at 128p, apply the spec's interest-caching/stagger optimization before touching the budget.
