# Native (Rust) Snapshot Encoder Implementation Plan (ADR-0003 Phase A + deferred Phase B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Per ADR-0003 this is a **review-heavy** implementation: dispatch review subagents on the integration tasks (10–14), and mind the subagent git-safety rule (read-only reviewers, verify HEAD after).

**Goal:** Replace the GDScript per-tick snapshot encode hot path (`snap` ≈ 24 ms on budget-class cores, 69% of tick, gate FAIL 34.84 ms) with a byte-identical Rust `gdext` encoder so the 128-bot `conquest_town` fleet gate passes E-core-pinned, keeping the GDScript encoder as reference/fallback.

**Architecture:** GDScript extracts quantized state once per tick into flat `PackedInt32Array` columns; a `NativeSnapshotEncoder` (Rust, `native/snapshot_encoder/`, mirroring `voice_opus`) owns per-client baseline history natively (Arc-shared tick columns + ordered sent-id lists) and emits complete SNAPSHOT packets. Parity is enforced by a differential fuzz harness + golden vectors + the existing roundtrip suite. Spec: `docs/superpowers/specs/2026-07-10-native-snapshot-encoder-design.md`; decision record: `docs/adr/0003-native-snapshot-encoder.md`.

**Tech Stack:** Godot 4.6.3 GDScript; Rust (edition 2021) + `godot`/gdext 0.5.3 `api-4-6` + `rustc-hash`; the repo's `TestCase` suite (`godot --headless --path . -- --test`); `cargo test`; docker fleet gate on game2.

**Wire-format ground truth (memorize before Task 4):** one SNAPSHOT packet =
`u8 msg(=Protocol.Msg.SNAPSHOT=5) · u32 server_tick · u32 seq · u32 baseline_seq · u32 last_input_tick · u16 count · pawn-records · u16 vcount · vehicle-records`, all little-endian (`StreamPeerBuffer` default).
Pawn record: `u32 id · u8 flags`, then for CHANGED(4): `u8 mask` + masked fields; for ENTER(1): `u8 mask(=255)` + all fields + `u8 armor&3` + `u8 weapon&0xFF`; for LEAVE(2): nothing.
Pawn fields in mask-bit order: pos_x/y/z `i32` (bit 1/2/4), yaw/pitch `u16` (8/16), state `u8` (32), health `u8` **clamped 0..255 at write, diffed raw** (64), squad `u8` masked `&0xFF` at write, diffed raw (128).
Vehicle record: same flags; fields: pos_x/y/z `i32` (1/2/4), heading `u16` (8), turret `u16` (16), hp `u16` clamped 0..65535 at write / diffed raw (32), seats `u8 n + n×u32` diffed as whole list (64), type `u8` `&0xFF` (128). No ENTER-extra bytes for vehicles.
`count`/`vcount` include LEAVE records. Record order = current-map insertion order; LEAVE order = baseline-map insertion order. Reference implementation: `shared/net/snapshot.gd` (do not modify it in this plan).

**Column schema (single source of truth — used by Tasks 2, 4, 8, 9):**
Pawn stride **10**: `[0]=q_px [1]=q_py [2]=q_pz [3]=q_yaw [4]=q_pitch [5]=q_state [6]=health(raw) [7]=squad(raw) [8]=armor_class [9]=weapon`.
Vehicle stride **7**: `[0]=q_px [1]=q_py [2]=q_pz [3]=q_heading [4]=q_turret [5]=hp(raw) [6]=type`; seats flattened in `vseats` with `vseat_off` (length = n_vehicles+1, `vseat_off[i]..vseat_off[i+1]` = vehicle i's occupant ids).
`q_*` values are exactly what `EntityState.bake()` / `VehicleState.bake()` produce (`Quantize.enc_pos`/`enc_angle`, state-byte packing incl. bit7 = climbing).

**Working agreement reminders:** claim the task in `docs/TASKS.md` (§3); work on a feature branch and **land per §11** (commit → fetch/reconcile → merge master → push) — don't strand work; run `/graphify --update` after landing; the E-core-pinned gate runs in Tasks 1/14 are a **deliberate exception** to the §8 "server on P-cores" rule (budget-hardware proxy, per ADR-0003 Phase 0 — label the runs clearly).

---

## Phase A — native columnar encoder (single-core win; committed target: 128p on budget hardware)

### Task 1: `snap` sub-bucket instrumentation + E-core re-profile

Converts the "~80–90% of `snap` is addressable" estimate into measured sub-buckets and creates the attribution baseline for the Phase A win. No behavior change — instrumentation only, so no new unit test; the hard check is the full suite staying green and the profile evidence.

**Files:**
- Modify: `server/server_main.gd` (`_phase_us` dict ~line 112, `_send_snapshots()` ~lines 872–948, `[perf]` print ~lines 2287–2288)

- [ ] **Step 1: Add sub-bucket keys**

In the `_phase_us` initializer (line ~112) append five keys to the dictionary: `"snapq": 0, "snapenc": 0, "snapsend": 0, "snapstruct": 0, "snapself": 0` (keep the existing `"snap"` key — it stays the umbrella total measured by the caller).

- [ ] **Step 2: Time the sections inside `_send_snapshots()`**

Wrap the existing code with local `Time.get_ticks_usec()` accumulators — no logic changes:

```gdscript
func _send_snapshots() -> void:
	var t_q := 0; var t_enc := 0; var t_send := 0; var t_struct := 0; var t_self := 0
	var t0 := Time.get_ticks_usec()
	var state := _sim.world.state_map()
	# ... existing weapon stamp + vehicle_state_map ...
	t_enc += Time.get_ticks_usec() - t0
	for id in _clients:
		# ... existing stride skip + self_pawn guard ...
		t0 = Time.get_ticks_usec()
		_sync_structure_baselines(c, self_pawn.pos)
		t_struct += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, _positions)
		# ... existing enemy-cull block ...
		t_q += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		# ... existing current/current_v/baseline lookups + Snapshot.encode ...
		t_enc += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)
		t_send += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		# ... existing SELF_STATE encode + send ...
		t_self += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		# ... existing history store + prune + telemetry ...
		t_enc += Time.get_ticks_usec() - t0
	_phase_us["snapq"] += t_q; _phase_us["snapenc"] += t_enc; _phase_us["snapsend"] += t_send
	_phase_us["snapstruct"] += t_struct; _phase_us["snapself"] += t_self
```

Extend the `[perf]` print (line ~2287) with ` snapq=%d snapenc=%d snapsend=%d snapstruct=%d snapself=%d` and the matching `_phase_us[...] / pt` values (same pattern as the existing buckets).

- [ ] **Step 3: Run the suite**

Run: `godot --headless --path . -- --test`
Expected: same pass count as master (currently ~1455/0), 0 failures.

- [ ] **Step 4: E-core profile run (evidence)**

```bash
cd docker
SERVER_CPUS=16,17,18,19 BOTS_CPUS=0-15 BOT_REPLICAS=16 BOT_COUNT=8 \
  MAP=conquest_town LABEL=phaseA-ecore-subbuckets ./stress.sh
```
Expected: FAIL verdict (~34–35 ms peak, matching Phase 0) but now with `snapq/snapenc/snapsend/snapstruct/snapself` in the peak `[perf]` lines. Record the peak-window sub-bucket split in a gate-evidence note (the `gate_evidence` helper writes `docs/gate-evidence/` automatically via `_gate_lib.sh`). `snapenc` is the Phase A addressable number — write it into the evidence file summary.

- [ ] **Step 5: Commit**

```bash
git add server/server_main.gd docs/gate-evidence/
git commit -m "perf(server): split snap bucket into snapq/snapenc/snapsend/snapstruct/snapself + E-core evidence (ADR-0003 Task 1)"
```

### Task 2: `SnapshotColumns` — pawn extraction (GDScript)

**Files:**
- Create: `shared/net/snapshot_columns.gd`
- Test: `tests/snapshot_columns_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
extends TestCase
## SnapshotColumns.extract_pawns must equal state_map()+bake() field-for-field (ADR-0003).

func _mk_world() -> World:
	var w := World.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for i in 40:
		var p := w.spawn(i + 1)
		p.pos = Vector3(rng.randf_range(-500, 500), rng.randf_range(-10, 60), rng.randf_range(-500, 500))
		p.yaw = rng.randf_range(-10.0, 10.0)
		p.pitch = rng.randf_range(-1.5, 1.5)
		p.stance = rng.randi_range(0, 2)
		p.lean = rng.randi_range(0, 2)
		p.team = rng.randi_range(0, 1)
		p.alive = rng.randf() > 0.2
		p.health = rng.randi_range(-5, 300)   # raw values incl. out-of-u8-range
		p.is_downed = rng.randf() > 0.8
		p.climbing = rng.randf() > 0.9
		p.squad = rng.randi_range(0, 300)
		p.armor_class = rng.randi_range(0, 2)
	return w

func test_pawn_columns_match_state_map_bake() -> void:
	var w := _mk_world()
	var weapons := {3: 4, 7: 1}   # only some ids have a client weapon
	var ids := PackedInt32Array()
	var fields := PackedInt32Array()
	SnapshotColumns.extract_pawns(w, weapons, ids, fields)
	var state := w.state_map()
	for sid in state:
		if weapons.has(sid): (state[sid] as EntityState).weapon = weapons[sid]
	assert_eq(ids.size(), state.size())
	assert_eq(fields.size(), ids.size() * SnapshotColumns.PAWN_STRIDE)
	var i := 0
	for id in w.pawns:   # column order must be world iteration order
		assert_eq(ids[i], id)
		var e: EntityState = state[id]
		e.bake()
		var o := i * SnapshotColumns.PAWN_STRIDE
		assert_eq(fields[o + 0], e.q_px); assert_eq(fields[o + 1], e.q_py); assert_eq(fields[o + 2], e.q_pz)
		assert_eq(fields[o + 3], e.q_yaw); assert_eq(fields[o + 4], e.q_pitch); assert_eq(fields[o + 5], e.q_state)
		assert_eq(fields[o + 6], e.health); assert_eq(fields[o + 7], e.squad)
		assert_eq(fields[o + 8], e.armor_class); assert_eq(fields[o + 9], e.weapon)
		i += 1

func test_arrays_reused_without_leftover() -> void:
	# resize() down must not leave stale rows when the world shrinks between ticks.
	var w := _mk_world()
	var ids := PackedInt32Array(); var fields := PackedInt32Array()
	SnapshotColumns.extract_pawns(w, {}, ids, fields)
	w.despawn(1); w.despawn(2)
	SnapshotColumns.extract_pawns(w, {}, ids, fields)
	assert_eq(ids.size(), w.pawns.size())
	assert_eq(fields.size(), ids.size() * SnapshotColumns.PAWN_STRIDE)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=snapshot_columns`
Expected: FAIL (SnapshotColumns not found / parse error).

- [ ] **Step 3: Implement `shared/net/snapshot_columns.gd`**

```gdscript
class_name SnapshotColumns
extends Object
## Columnar wire-state extraction for the native snapshot encoder (ADR-0003).
## Lane order is the FFI contract with native/snapshot_encoder/src/core.rs — change both or neither.
## health/squad (and vehicle hp) are stored RAW; the encoder clamps/masks at write time,
## matching Snapshot._put_fields exactly.

const PAWN_STRIDE := 10
const VEH_STRIDE := 7

static func extract_pawns(world: World, weapon_by_id: Dictionary,
		out_ids: PackedInt32Array, out_fields: PackedInt32Array) -> void:
	var n := world.pawns.size()
	out_ids.resize(n)
	out_fields.resize(n * PAWN_STRIDE)
	var i := 0
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		out_ids[i] = id
		var o := i * PAWN_STRIDE
		out_fields[o + 0] = Quantize.enc_pos(p.pos.x)
		out_fields[o + 1] = Quantize.enc_pos(p.pos.y)
		out_fields[o + 2] = Quantize.enc_pos(p.pos.z)
		out_fields[o + 3] = Quantize.enc_angle(p.yaw)
		out_fields[o + 4] = Quantize.enc_angle(p.pitch)
		out_fields[o + 5] = (p.stance & 3) | ((p.lean & 3) << 2) \
			| ((1 if p.team != 0 else 0) << 4) | ((1 if p.alive else 0) << 5) \
			| ((1 if p.is_downed else 0) << 6) | ((1 if p.climbing else 0) << 7)
		out_fields[o + 6] = p.health
		out_fields[o + 7] = p.squad
		out_fields[o + 8] = p.armor_class
		out_fields[o + 9] = int(weapon_by_id.get(id, 0))
		i += 1
```

(The state-byte packing must stay bit-identical to `EntityState.bake()` — if bake() ever gains a bit, both change together; the test above enforces it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=snapshot_columns`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/net/snapshot_columns.gd tests/snapshot_columns_test.gd
git commit -m "feat(net): columnar pawn state extraction for native encoder (ADR-0003 Task 2)"
```

### Task 3: `SnapshotColumns` — vehicle extraction

**Files:**
- Modify: `shared/net/snapshot_columns.gd`
- Test: `tests/snapshot_columns_test.gd`

- [ ] **Step 1: Write the failing test (append to `tests/snapshot_columns_test.gd`)**

```gdscript
func test_vehicle_columns_match_state_map_bake() -> void:
	var w := World.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in 5:
		var v := Vehicle.new(Vehicle.ID_BASE + i, 0)
		v.pos = Vector3(rng.randf_range(-300, 300), 0, rng.randf_range(-300, 300))
		v.heading = rng.randf_range(-4.0, 4.0)
		v.turret_yaw = rng.randf_range(-2.0, 2.0)
		v.hp = rng.randi_range(-10, 70000)
		v.type = rng.randi_range(0, 3)
		v.seats = [] if i == 0 else [rng.randi_range(1, 128), rng.randi_range(1, 128)].slice(0, i % 3)
		w.spawn_vehicle(v)
	var vids := PackedInt32Array(); var vfields := PackedInt32Array()
	var vseats := PackedInt32Array(); var vseat_off := PackedInt32Array()
	SnapshotColumns.extract_vehicles(w, vids, vfields, vseats, vseat_off)
	var vstate := w.vehicle_state_map()
	assert_eq(vids.size(), vstate.size())
	assert_eq(vseat_off.size(), vids.size() + 1)
	var i := 0
	for vid in w.vehicles:
		assert_eq(vids[i], vid)
		var e: VehicleState = vstate[vid]
		e.bake()
		var o := i * SnapshotColumns.VEH_STRIDE
		assert_eq(vfields[o + 0], e.q_px); assert_eq(vfields[o + 1], e.q_py); assert_eq(vfields[o + 2], e.q_pz)
		assert_eq(vfields[o + 3], e.q_heading); assert_eq(vfields[o + 4], e.q_turret)
		assert_eq(vfields[o + 5], e.hp); assert_eq(vfields[o + 6], e.type)
		var s0 := vseat_off[i]; var s1 := vseat_off[i + 1]
		assert_eq(s1 - s0, e.seats.size())
		for k in e.seats.size():
			assert_eq(vseats[s0 + k], int(e.seats[k]))
		i += 1
	assert_eq(vseat_off[vids.size()], vseats.size())
```

(If the `Vehicle.new(...)` constructor signature differs, mirror how `tests/vehicle_snapshot_test.gd` builds vehicles — the assertion body is what matters.)

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=snapshot_columns`
Expected: FAIL (`extract_vehicles` not defined).

- [ ] **Step 3: Implement `extract_vehicles` (append to `shared/net/snapshot_columns.gd`)**

```gdscript
static func extract_vehicles(world: World, out_vids: PackedInt32Array, out_vfields: PackedInt32Array,
		out_vseats: PackedInt32Array, out_vseat_off: PackedInt32Array) -> void:
	var n := world.vehicles.size()
	out_vids.resize(n)
	out_vfields.resize(n * VEH_STRIDE)
	out_vseat_off.resize(n + 1)
	var total := 0
	for vid in world.vehicles:
		total += (world.vehicles[vid] as Vehicle).seats.size()
	out_vseats.resize(total)
	var i := 0
	var so := 0
	for vid in world.vehicles:
		var v: Vehicle = world.vehicles[vid]
		out_vids[i] = vid
		var o := i * VEH_STRIDE
		out_vfields[o + 0] = Quantize.enc_pos(v.pos.x)
		out_vfields[o + 1] = Quantize.enc_pos(v.pos.y)
		out_vfields[o + 2] = Quantize.enc_pos(v.pos.z)
		out_vfields[o + 3] = Quantize.enc_angle(v.heading)
		out_vfields[o + 4] = Quantize.enc_angle(v.turret_yaw)
		out_vfields[o + 5] = v.hp
		out_vfields[o + 6] = v.type
		out_vseat_off[i] = so
		for s in v.seats:
			out_vseats[so] = int(s)
			so += 1
		i += 1
	out_vseat_off[n] = so
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=snapshot_columns`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/net/snapshot_columns.gd tests/snapshot_columns_test.gd
git commit -m "feat(net): columnar vehicle state extraction (ADR-0003 Task 3)"
```

### Task 4: Crate scaffold + little-endian wire writer (`wire.rs`)

**Files:**
- Create: `native/snapshot_encoder/Cargo.toml`
- Create: `native/snapshot_encoder/snapshot_encoder.gdextension`
- Create: `native/snapshot_encoder/src/lib.rs` (stub — bindings come in Task 8)
- Create: `native/snapshot_encoder/src/wire.rs`
- Create: `native/snapshot_encoder/README.md`

- [ ] **Step 1: Scaffold the crate**

`native/snapshot_encoder/Cargo.toml`:

```toml
[package]
name = "snapshot_encoder"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "rlib"]   # rlib so `cargo test` can link the core

[dependencies]
# Same pin as native/voice_opus (ADR-0006 toolchain precedent).
godot = { version = "0.5.3", features = ["api-4-6"] }
rustc-hash = "2"
```

`native/snapshot_encoder/snapshot_encoder.gdextension`:

```ini
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = "4.6"
reloadable = true

[libraries]
linux.debug.x86_64 = "res://native/snapshot_encoder/target/debug/libsnapshot_encoder.so"
linux.release.x86_64 = "res://native/snapshot_encoder/target/release/libsnapshot_encoder.so"
```

(Linux-only by decision — the encoder is server-side and every server host is Linux x86_64; see ADR-0003 ratified decisions.)

`native/snapshot_encoder/src/lib.rs` (minimal for now):

```rust
mod core;
mod wire;

use godot::prelude::*;

struct SnapshotEncoderExt;

#[gdextension]
unsafe impl ExtensionLibrary for SnapshotEncoderExt {}
```

`native/snapshot_encoder/README.md`: three lines — what it is (ADR-0003), build (`cargo build --release` in this dir; binary is gitignored, loaded via the `.gdextension`), and that the GDScript reference path runs when the `.so` is absent.

Also create an empty `native/snapshot_encoder/src/core.rs` containing only `// EncoderCore lands in Task 5.` so the crate compiles.

- [ ] **Step 2: Write the failing wire tests (inside `src/wire.rs`)**

```rust
//! Little-endian wire primitives matching Godot's StreamPeerBuffer defaults.

pub fn put_u8(b: &mut Vec<u8>, v: u8) { b.push(v); }
pub fn put_u16(b: &mut Vec<u8>, v: u16) { b.extend_from_slice(&v.to_le_bytes()); }
pub fn put_u32(b: &mut Vec<u8>, v: u32) { b.extend_from_slice(&v.to_le_bytes()); }
pub fn put_i32(b: &mut Vec<u8>, v: i32) { b.extend_from_slice(&v.to_le_bytes()); }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn little_endian_widths() {
        let mut b = Vec::new();
        put_u8(&mut b, 5);
        put_u32(&mut b, 0x01020304);
        put_u16(&mut b, 0xBEEF);
        put_i32(&mut b, -1000);
        assert_eq!(b, vec![5, 0x04, 0x03, 0x02, 0x01, 0xEF, 0xBE, 0x18, 0xFC, 0xFF, 0xFF]);
    }
}
```

- [ ] **Step 3: Build + test**

Run: `cargo test --manifest-path native/snapshot_encoder/Cargo.toml`
Expected: `little_endian_widths ... ok`. Then `cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml` — expect a `libsnapshot_encoder.so` under `target/release/`.

- [ ] **Step 4: Gitignore the target dir**

Append `/native/snapshot_encoder/target/` to `.gitignore` (the `*.so` rule already exists).

- [ ] **Step 5: Commit**

```bash
git add native/snapshot_encoder/ .gitignore
git commit -m "feat(native): snapshot_encoder crate scaffold + LE wire writer (ADR-0003 Task 4)"
```

### Task 5: `core.rs` — tick columns + pawn record encoding (pure Rust, cargo-tested)

This is the parity-critical core. Every semantic detail below mirrors `shared/net/snapshot.gd` — when in doubt, open that file and match it, not intuition.

**Files:**
- Modify: `native/snapshot_encoder/src/core.rs`

- [ ] **Step 1: Write the core data model + `begin_tick`**

```rust
//! EncoderCore: pure-Rust snapshot delta encoder + native baseline history (ADR-0003).
//! Byte-identical contract with shared/net/snapshot.gd — see the parity invariants in
//! docs/superpowers/specs/2026-07-10-native-snapshot-encoder-design.md §4.
//! INVARIANT: nothing hash-ordered is ever iterated into wire output — ordered Vecs only.

use crate::wire::*;
use rustc_hash::{FxHashMap, FxHashSet};
use std::collections::BTreeMap;
use std::sync::Arc;

pub const PAWN_STRIDE: usize = 10;
pub const VEH_STRIDE: usize = 7;
pub const MAX_HISTORY: i64 = 32; // server_main.gd MAX_HISTORY

const FLAG_ENTER: u8 = 1;
const FLAG_LEAVE: u8 = 2;
const FLAG_CHANGED: u8 = 4;
const F_ALL: u8 = 255;
// pawn lane i diffs into mask bit (1 << i) for lanes 0..8 (px,py,pz,yaw,pitch,state,health,squad)
const F_YAW: u8 = 8;
const F_PITCH: u8 = 16;
const F_STATE: u8 = 32;
const F_HEALTH: u8 = 64;
const F_SQUAD: u8 = 128;
const VF_HEADING: u8 = 8;
const VF_TURRET: u8 = 16;
const VF_HP: u8 = 32;
const VF_SEATS: u8 = 64;
const VF_TYPE: u8 = 128;

pub struct TickData {
    pub tick: u32,
    pub ids: Vec<i32>,
    pub fields: Vec<i32>,
    pub row: FxHashMap<i32, usize>,
    pub vids: Vec<i32>,
    pub vfields: Vec<i32>,
    pub vseats: Vec<i32>,
    pub vseat_off: Vec<i32>,
    pub vrow: FxHashMap<i32, usize>,
}

struct HistoryRec {
    tick: Arc<TickData>,
    sent_ids: Vec<i32>,
    sent_set: FxHashSet<i32>,
    sent_vids: Vec<i32>,
    sent_vset: FxHashSet<i32>,
}

pub struct EncoderCore {
    msg_id: u8,
    cur: Option<Arc<TickData>>,
    hist: FxHashMap<i32, BTreeMap<i64, HistoryRec>>,
}

impl EncoderCore {
    pub fn new() -> Self {
        Self { msg_id: 0, cur: None, hist: FxHashMap::default() }
    }

    pub fn set_msg_id(&mut self, id: u8) { self.msg_id = id; }

    pub fn begin_tick(&mut self, tick: u32, ids: &[i32], fields: &[i32], vids: &[i32],
            vfields: &[i32], vseats: &[i32], vseat_off: &[i32]) -> Result<(), String> {
        if fields.len() != ids.len() * PAWN_STRIDE {
            return Err(format!("pawn columns ragged: {} ids vs {} fields", ids.len(), fields.len()));
        }
        if vfields.len() != vids.len() * VEH_STRIDE || vseat_off.len() != vids.len() + 1 {
            return Err("vehicle columns ragged".into());
        }
        if *vseat_off.last().unwrap_or(&0) as usize != vseats.len() {
            return Err("vseat_off does not close vseats".into());
        }
        let mut row = FxHashMap::default();
        for (i, &id) in ids.iter().enumerate() { row.insert(id, i); }
        let mut vrow = FxHashMap::default();
        for (i, &vid) in vids.iter().enumerate() { vrow.insert(vid, i); }
        self.cur = Some(Arc::new(TickData {
            tick, ids: ids.to_vec(), fields: fields.to_vec(), row,
            vids: vids.to_vec(), vfields: vfields.to_vec(),
            vseats: vseats.to_vec(), vseat_off: vseat_off.to_vec(), vrow,
        }));
        Ok(())
    }
}

fn put_pawn_fields(b: &mut Vec<u8>, f: &[i32], mask: u8) {
    put_u8(b, mask);
    if mask & 1 != 0 { put_i32(b, f[0]); }
    if mask & 2 != 0 { put_i32(b, f[1]); }
    if mask & 4 != 0 { put_i32(b, f[2]); }
    if mask & F_YAW != 0 { put_u16(b, f[3] as u16); }
    if mask & F_PITCH != 0 { put_u16(b, f[4] as u16); }
    if mask & F_STATE != 0 { put_u8(b, f[5] as u8); }
    if mask & F_HEALTH != 0 { put_u8(b, f[6].clamp(0, 255) as u8); }
    if mask & F_SQUAD != 0 { put_u8(b, (f[7] & 0xFF) as u8); }
}
```

- [ ] **Step 2: Write failing tests for pawn encoding parity semantics**

Append to `core.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn pawn(id: i32, px: i32, health: i32) -> (i32, [i32; PAWN_STRIDE]) {
        (id, [px, 2000, 3000, 100, 200, 0b100001, health, 1, 2, 4])
    }

    fn core_with_tick(pawns: &[(i32, [i32; PAWN_STRIDE])], tick: u32) -> EncoderCore {
        let mut c = EncoderCore::new();
        c.set_msg_id(5);
        let ids: Vec<i32> = pawns.iter().map(|p| p.0).collect();
        let fields: Vec<i32> = pawns.iter().flat_map(|p| p.1).collect();
        c.begin_tick(tick, &ids, &fields, &[], &[], &[], &[0]).unwrap();
        c
    }

    #[test]
    fn keyframe_all_enter_with_extras() {
        let mut c = core_with_tick(&[pawn(1, 1000, 90), pawn(2, -500, 300)], 7);
        let buf = c.encode_for(42, 1, 0, 99, &[1, 2], &[]).unwrap();
        // header: msg,tick,seq,baseline_seq(0=keyframe),last_input_tick,count=2
        assert_eq!(buf[0], 5);
        assert_eq!(u32::from_le_bytes(buf[1..5].try_into().unwrap()), 7);
        assert_eq!(u32::from_le_bytes(buf[5..9].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[9..13].try_into().unwrap()), 0);
        assert_eq!(u32::from_le_bytes(buf[13..17].try_into().unwrap()), 99);
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 2);
        // rec 1: id=1 ENTER mask=255 → 4+1+1 + (3*4 + 2*2 + 3*1) + armor + weapon
        assert_eq!(u32::from_le_bytes(buf[19..23].try_into().unwrap()), 1);
        assert_eq!(buf[23], FLAG_ENTER);
        assert_eq!(buf[24], F_ALL);
        let rec1_end = 25 + 12 + 4 + 3 + 2;
        assert_eq!(buf[rec1_end - 2], 2 & 3);      // armor
        assert_eq!(buf[rec1_end - 1], 4);          // weapon
        // rec 2 health 300 must clamp to 255 at write
        let h2 = rec1_end + 4 + 1 + 1 + 12 + 4 + 1; // ...through state byte
        assert_eq!(buf[h2], 255);
        // trailing vcount == 0
        let n = buf.len();
        assert_eq!(u16::from_le_bytes(buf[n - 2..].try_into().unwrap()), 0);
    }

    #[test]
    fn delta_changed_leave_and_raw_diff_clamped_write() {
        let mut c = core_with_tick(&[pawn(1, 1000, 90), pawn(2, 0, 50)], 7);
        c.encode_for(42, 1, 0, 0, &[1, 2], &[]).unwrap();
        // next tick: pawn 1 health 256→ raw diff fires even though clamp(256)==clamp(300) writes differ? use 300→256
        let mut p1 = pawn(1, 1000, 300); p1.1[6] = 300; // unchanged px, health 300 (was 90)
        let p3 = pawn(3, 5, 5);
        let ids = vec![1, 3];
        let fields: Vec<i32> = [p1.1, p3.1].concat();
        c.begin_tick(8, &ids, &fields, &[], &[], &[], &[0]).unwrap();
        // interest now {1,3}: 1 CHANGED (health only), 3 ENTER, 2 LEAVE (in baseline sent order)
        let buf = c.encode_for(42, 2, 1, 0, &[1, 3], &[]).unwrap();
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 3);
        assert_eq!(buf[23], FLAG_CHANGED);
        assert_eq!(buf[24], F_HEALTH);
        assert_eq!(buf[25], 255); // clamped write of raw 300
        // rec 2: id=3 ENTER; rec 3: id=2 LEAVE with no mask byte
        let leave_at = 26 + (4 + 1 + 1 + 12 + 4 + 3 + 2);
        assert_eq!(u32::from_le_bytes(buf[leave_at..leave_at + 4].try_into().unwrap()), 2);
        assert_eq!(buf[leave_at + 4], FLAG_LEAVE);
    }

    #[test]
    fn raw_equal_over_clamp_boundary_emits_no_record() {
        // health 300 → 300 must NOT diff (raw compare), even though both clamp to 255.
        let mut c = core_with_tick(&[pawn(1, 1000, 300)], 1);
        c.encode_for(9, 1, 0, 0, &[1], &[]).unwrap();
        let (id, f) = pawn(1, 1000, 300);
        c.begin_tick(2, &[id], &f, &[], &[], &[], &[0]).unwrap();
        let buf = c.encode_for(9, 2, 1, 0, &[1], &[]).unwrap();
        assert_eq!(buf.len(), 21); // header 19 + vcount 2 — zero records
    }

    #[test]
    fn record_order_is_interest_order_not_sorted() {
        let mut c = core_with_tick(&[pawn(1, 0, 1), pawn(2, 0, 1), pawn(9, 0, 1)], 1);
        let buf = c.encode_for(9, 1, 0, 0, &[9, 1, 2], &[]).unwrap();
        assert_eq!(u32::from_le_bytes(buf[19..23].try_into().unwrap()), 9);
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cargo test --manifest-path native/snapshot_encoder/Cargo.toml`
Expected: compile error — `encode_for` not defined.

- [ ] **Step 4: Implement `encode_for` (pawn records + history insert)**

```rust
impl EncoderCore {
    pub fn encode_for(&mut self, client: i32, seq: i64, want_baseline_seq: i64,
            last_input_tick: u32, interest_ids: &[i32], interest_vids: &[i32])
            -> Result<Vec<u8>, String> {
        let cur = self.cur.clone().ok_or("encode_for before begin_tick")?;
        let baseline = self.hist.get(&client).and_then(|h| h.get(&want_baseline_seq));
        let baseline_seq: u32 = if baseline.is_some() { want_baseline_seq as u32 } else { 0 };

        let interest_set: FxHashSet<i32> = interest_ids.iter().copied().collect();
        let mut recs: Vec<u8> = Vec::with_capacity(interest_ids.len() * 24);
        let mut count: u32 = 0;
        for &id in interest_ids {
            let crow = *cur.row.get(&id).ok_or_else(|| format!("interest id {id} not in tick columns"))?;
            let cf = &cur.fields[crow * PAWN_STRIDE..crow * PAWN_STRIDE + PAWN_STRIDE];
            let base_fields = baseline.and_then(|r| {
                if !r.sent_set.contains(&id) { return None; }
                let brow = *r.tick.row.get(&id)?;
                Some(&r.tick.fields[brow * PAWN_STRIDE..brow * PAWN_STRIDE + PAWN_STRIDE])
            });
            match base_fields {
                Some(bf) => {
                    let mut mask: u8 = 0;
                    for lane in 0..8 {
                        if cf[lane] != bf[lane] { mask |= 1 << lane; }
                    }
                    if mask == 0 { continue; }
                    count += 1;
                    put_u32(&mut recs, id as u32);
                    put_u8(&mut recs, FLAG_CHANGED);
                    put_pawn_fields(&mut recs, cf, mask);
                }
                None => {
                    count += 1;
                    put_u32(&mut recs, id as u32);
                    put_u8(&mut recs, FLAG_ENTER);
                    put_pawn_fields(&mut recs, cf, F_ALL);
                    put_u8(&mut recs, (cf[8] & 3) as u8);
                    put_u8(&mut recs, (cf[9] & 0xFF) as u8);
                }
            }
        }
        if let Some(r) = baseline {
            for &id in &r.sent_ids {
                if !interest_set.contains(&id) {
                    count += 1;
                    put_u32(&mut recs, id as u32);
                    put_u8(&mut recs, FLAG_LEAVE);
                }
            }
        }

        let (vrecs, vcount) = self.encode_vehicles(&cur, baseline, interest_vids)?;

        let mut buf: Vec<u8> = Vec::with_capacity(21 + recs.len() + vrecs.len());
        put_u8(&mut buf, self.msg_id);
        put_u32(&mut buf, cur.tick);
        put_u32(&mut buf, seq as u32);
        put_u32(&mut buf, baseline_seq);
        put_u32(&mut buf, last_input_tick);
        put_u16(&mut buf, count as u16);
        buf.extend_from_slice(&recs);
        put_u16(&mut buf, vcount as u16);
        buf.extend_from_slice(&vrecs);

        // history: full interest map (not just emitted records), mirroring c["history"][seq] = current
        let vset: FxHashSet<i32> = interest_vids.iter().copied().collect();
        let rec = HistoryRec {
            tick: cur.clone(),
            sent_ids: interest_ids.to_vec(), sent_set: interest_set,
            sent_vids: interest_vids.to_vec(), sent_vset: vset,
        };
        let h = self.hist.entry(client).or_default();
        h.insert(seq, rec);
        let cutoff = seq - MAX_HISTORY;
        h.retain(|&s, _| s >= cutoff);
        Ok(buf)
    }
}
```

Add a temporary `encode_vehicles` stub so pawn tests compile (fleshed out in Task 6):

```rust
    fn encode_vehicles(&self, _cur: &TickData, _baseline: Option<&HistoryRec>,
            interest_vids: &[i32]) -> Result<(Vec<u8>, u32), String> {
        if !interest_vids.is_empty() { return Err("vehicles not implemented until Task 6".into()); }
        Ok((Vec::new(), 0))
    }
```

Note the borrow shape: `baseline` is an immutable borrow used throughout encoding; the mutable `self.hist.entry(...)` happens only after `recs`/`vrecs` are complete. If the borrow checker complains about `baseline` living across `encode_vehicles`, pass `baseline` in as a parameter (as written) — `encode_vehicles` takes `&self` and the already-resolved `Option<&HistoryRec>`.

- [ ] **Step 5: Run the cargo tests**

Run: `cargo test --manifest-path native/snapshot_encoder/Cargo.toml`
Expected: all 5 tests PASS (4 new + wire test).

- [ ] **Step 6: Commit**

```bash
git add native/snapshot_encoder/src/
git commit -m "feat(native): EncoderCore pawn delta encoding + native history (ADR-0003 Task 5)"
```

### Task 6: `core.rs` — vehicle records + history ops (ack/prune/drop/remove/reset)

**Files:**
- Modify: `native/snapshot_encoder/src/core.rs`

- [ ] **Step 1: Write failing tests**

```rust
    fn veh(vid: i32, px: i32, hp: i32, seats: &[i32]) -> (i32, [i32; VEH_STRIDE], Vec<i32>) {
        (vid, [px, 0, 0, 50, 60, hp, 1], seats.to_vec())
    }

    fn begin_with_vehicles(c: &mut EncoderCore, tick: u32, vehs: &[(i32, [i32; VEH_STRIDE], Vec<i32>)]) {
        let vids: Vec<i32> = vehs.iter().map(|v| v.0).collect();
        let vfields: Vec<i32> = vehs.iter().flat_map(|v| v.1).collect();
        let mut vseats = Vec::new();
        let mut voff = vec![0i32];
        for v in vehs {
            vseats.extend_from_slice(&v.2);
            voff.push(vseats.len() as i32);
        }
        c.begin_tick(tick, &[], &[], &vids, &vfields, &vseats, &voff).unwrap();
    }

    #[test]
    fn vehicle_enter_seats_and_leave() {
        let mut c = EncoderCore::new(); c.set_msg_id(5);
        begin_with_vehicles(&mut c, 1, &[veh(1000, 5, 70000, &[7, 9])]);
        let buf = c.encode_for(1, 1, 0, 0, &[], &[1000]).unwrap();
        // header 19 + count 0 → vcount at 17? No: count u16 at 17..19 = 0, vcount at 19..21 = 1
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 0);
        assert_eq!(u16::from_le_bytes(buf[19..21].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[21..25].try_into().unwrap()), 1000);
        assert_eq!(buf[25], FLAG_ENTER);
        assert_eq!(buf[26], 255);
        // fields: 12B pos, 2+2 angles, hp u16 clamped(70000→65535), seats u8 2 + 2*u32, type u8
        let hp = u16::from_le_bytes(buf[27 + 12 + 4..27 + 12 + 6].try_into().unwrap());
        assert_eq!(hp, 65535);
        assert_eq!(buf[27 + 12 + 6], 2); // seat count
        // vehicle leaves next tick
        begin_with_vehicles(&mut c, 2, &[]);
        let buf2 = c.encode_for(1, 2, 1, 0, &[], &[]).unwrap();
        assert_eq!(u16::from_le_bytes(buf2[19..21].try_into().unwrap()), 1);
        assert_eq!(buf2[25], FLAG_LEAVE);
    }

    #[test]
    fn vehicle_seat_change_diffs_as_list() {
        let mut c = EncoderCore::new(); c.set_msg_id(5);
        begin_with_vehicles(&mut c, 1, &[veh(1000, 5, 100, &[7])]);
        c.encode_for(1, 1, 0, 0, &[], &[1000]).unwrap();
        begin_with_vehicles(&mut c, 2, &[veh(1000, 5, 100, &[7, 8])]);
        let buf = c.encode_for(1, 2, 1, 0, &[], &[1000]).unwrap();
        assert_eq!(buf[25], FLAG_CHANGED);
        assert_eq!(buf[26], VF_SEATS);
        assert_eq!(buf[27], 2); // new seat count
    }

    #[test]
    fn max_history_prune_and_ack_prune() {
        let mut c = core_with_tick(&[pawn(1, 0, 1)], 1);
        for s in 1..=40i64 {
            c.encode_for(9, s, 0, 0, &[1], &[]).unwrap();
        }
        assert_eq!(c.history_len(9), MAX_HISTORY as usize); // 40-32.. pruned to seq>=8... exact: seqs 9..=40 minus cutoff → 32 entries? cutoff=40-32=8 → keeps 9..=40 = 32
        c.on_ack(9, 38);
        assert_eq!(c.history_len(9), 3); // 38,39,40
        c.remove_client(9);
        assert_eq!(c.history_len(9), 0);
    }

    #[test]
    fn aged_out_baseline_falls_back_to_keyframe() {
        let mut c = core_with_tick(&[pawn(1, 0, 1)], 1);
        c.encode_for(9, 1, 0, 0, &[1], &[]).unwrap();
        c.on_ack(9, 2); // prunes seq 1
        let buf = c.encode_for(9, 2, 1, 0, &[1], &[]).unwrap(); // wants seq1: gone → keyframe
        assert_eq!(u32::from_le_bytes(buf[9..13].try_into().unwrap()), 0);
        assert_eq!(buf[23], FLAG_ENTER);
    }

    #[test]
    fn drop_entity_forces_reenter_without_leave() {
        let mut c = core_with_tick(&[pawn(1, 0, 1), pawn(2, 0, 1)], 1);
        c.encode_for(9, 1, 0, 0, &[1, 2], &[]).unwrap();
        c.drop_entity_from_baselines(2);
        // same interest, no field changes: pawn 2 must ENTER again; pawn 1 no record; NO LEAVE for 2
        let buf = c.encode_for(9, 2, 1, 0, &[1, 2], &[]).unwrap();
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[19..23].try_into().unwrap()), 2);
        assert_eq!(buf[23], FLAG_ENTER);
    }

    #[test]
    fn tick_data_evicted_when_unreferenced() {
        let mut c = core_with_tick(&[pawn(1, 0, 1)], 1);
        c.encode_for(9, 1, 0, 0, &[1], &[]).unwrap();
        for t in 2..=80u32 {
            let (id, f) = pawn(1, t as i32, 1);
            c.begin_tick(t, &[id], &f, &[], &[], &[], &[0]).unwrap();
            c.encode_for(9, t as i64, t as i64 - 1, 0, &[1], &[]).unwrap();
        }
        // MAX_HISTORY(32) recs + cur → bounded distinct ticks alive
        assert!(c.live_tick_count() <= MAX_HISTORY as usize + 1);
    }
```

(Fix the `max_history_prune_and_ack_prune` comment arithmetic while implementing — the assertion values are the spec: after 40 sequential sends with cutoff `seq - 32`, exactly 32 remain; after `on_ack(38)` exactly `{38,39,40}` remain.)

- [ ] **Step 2: Run to verify failures**

Run: `cargo test --manifest-path native/snapshot_encoder/Cargo.toml`
Expected: compile errors — `on_ack`/`history_len`/`live_tick_count`/`drop_entity_from_baselines`/`remove_client` missing; vehicle stub errors.

- [ ] **Step 3: Implement**

Replace the `encode_vehicles` stub and add the ops:

```rust
impl EncoderCore {
    fn encode_vehicles(&self, cur: &TickData, baseline: Option<&HistoryRec>,
            interest_vids: &[i32]) -> Result<(Vec<u8>, u32), String> {
        let vset: FxHashSet<i32> = interest_vids.iter().copied().collect();
        let mut recs = Vec::new();
        let mut count: u32 = 0;
        for &vid in interest_vids {
            let crow = *cur.vrow.get(&vid).ok_or_else(|| format!("interest vid {vid} not in tick columns"))?;
            let cf = &cur.vfields[crow * VEH_STRIDE..crow * VEH_STRIDE + VEH_STRIDE];
            let cseats = &cur.vseats[cur.vseat_off[crow] as usize..cur.vseat_off[crow + 1] as usize];
            let base = baseline.and_then(|r| {
                if !r.sent_vset.contains(&vid) { return None; }
                let brow = *r.tick.vrow.get(&vid)?;
                let bf = &r.tick.vfields[brow * VEH_STRIDE..brow * VEH_STRIDE + VEH_STRIDE];
                let bs = &r.tick.vseats[r.tick.vseat_off[brow] as usize..r.tick.vseat_off[brow + 1] as usize];
                Some((bf, bs))
            });
            match base {
                Some((bf, bs)) => {
                    let mut mask: u8 = 0;
                    for lane in 0..5 { if cf[lane] != bf[lane] { mask |= 1 << lane; } }
                    if cf[5] != bf[5] { mask |= VF_HP; }
                    if cseats != bs { mask |= VF_SEATS; }
                    if cf[6] != bf[6] { mask |= VF_TYPE; }
                    if mask == 0 { continue; }
                    count += 1;
                    put_u32(&mut recs, vid as u32);
                    put_u8(&mut recs, FLAG_CHANGED);
                    put_veh_fields(&mut recs, cf, cseats, mask);
                }
                None => {
                    count += 1;
                    put_u32(&mut recs, vid as u32);
                    put_u8(&mut recs, FLAG_ENTER);
                    put_veh_fields(&mut recs, cf, cseats, F_ALL);
                }
            }
        }
        if let Some(r) = baseline {
            for &vid in &r.sent_vids {
                if !vset.contains(&vid) {
                    count += 1;
                    put_u32(&mut recs, vid as u32);
                    put_u8(&mut recs, FLAG_LEAVE);
                }
            }
        }
        Ok((recs, count))
    }

    pub fn on_ack(&mut self, client: i32, ack: i64) {
        if let Some(h) = self.hist.get_mut(&client) {
            h.retain(|&s, _| s >= ack);
        }
    }

    pub fn remove_client(&mut self, client: i32) { self.hist.remove(&client); }

    pub fn drop_entity_from_baselines(&mut self, id: i32) {
        for h in self.hist.values_mut() {
            for rec in h.values_mut() {
                if rec.sent_set.remove(&id) {
                    rec.sent_ids.retain(|&x| x != id);
                }
            }
        }
    }

    pub fn reset(&mut self) { self.hist.clear(); self.cur = None; }

    pub fn history_len(&self, client: i32) -> usize {
        self.hist.get(&client).map_or(0, |h| h.len())
    }

    pub fn live_tick_count(&self) -> usize {
        let mut ptrs: FxHashSet<*const TickData> = FxHashSet::default();
        if let Some(c) = &self.cur { ptrs.insert(Arc::as_ptr(c)); }
        for h in self.hist.values() {
            for r in h.values() { ptrs.insert(Arc::as_ptr(&r.tick)); }
        }
        ptrs.len()
    }
}

fn put_veh_fields(b: &mut Vec<u8>, f: &[i32], seats: &[i32], mask: u8) {
    put_u8(b, mask);
    if mask & 1 != 0 { put_i32(b, f[0]); }
    if mask & 2 != 0 { put_i32(b, f[1]); }
    if mask & 4 != 0 { put_i32(b, f[2]); }
    if mask & VF_HEADING != 0 { put_u16(b, f[3] as u16); }
    if mask & VF_TURRET != 0 { put_u16(b, f[4] as u16); }
    if mask & VF_HP != 0 { put_u16(b, f[5].clamp(0, 65535) as u16); }
    if mask & VF_SEATS != 0 {
        put_u8(b, seats.len() as u8);
        for &s in seats { put_u32(b, s as u32); }
    }
    if mask & VF_TYPE != 0 { put_u8(b, (f[6] & 0xFF) as u8); }
}
```

- [ ] **Step 4: Run the cargo tests**

Run: `cargo test --manifest-path native/snapshot_encoder/Cargo.toml`
Expected: all tests PASS (11 total).

- [ ] **Step 5: Commit**

```bash
git add native/snapshot_encoder/src/
git commit -m "feat(native): vehicle records + history ops (ack/prune/drop/reset) (ADR-0003 Task 6)"
```

### Task 7: gdext bindings (`NativeSnapshotEncoder` class) + Godot smoke test

**Files:**
- Modify: `native/snapshot_encoder/src/lib.rs`
- Test: `tests/native_encoder_smoke_test.gd`

- [ ] **Step 1: Write the failing GDScript smoke test**

```gdscript
extends TestCase
## Loads the native encoder and checks a tiny keyframe against the GDScript reference.
## Skips when the .so is absent locally; FAILS when absent in CI (the parity gate must run there).

func _native_required() -> bool:
	if ClassDB.class_exists("NativeSnapshotEncoder"):
		return true
	if OS.get_environment("CI") != "":
		fail("NativeSnapshotEncoder missing in CI — cargo build step broken")
	else:
		print("[skip] native_encoder_smoke: .so not built (cargo build --release in native/snapshot_encoder)")
	return false

func test_keyframe_matches_reference() -> void:
	if not _native_required(): return
	var e1 := EntityState.new(); e1.pos = Vector3(10, 2, 20); e1.health = 90; e1.squad = 3
	var e2 := EntityState.new(); e2.pos = Vector3(-3, 0, 4); e2.weapon = 2; e2.armor_class = 1
	var current := {1: e1, 2: e2}
	var ref_bytes := Snapshot.encode(7, 1, 0, 99, current, {})
	var enc = ClassDB.instantiate("NativeSnapshotEncoder")
	enc.set_msg_id(Protocol.Msg.SNAPSHOT)
	var ids := PackedInt32Array([1, 2])
	var fields := PackedInt32Array()
	fields.resize(2 * SnapshotColumns.PAWN_STRIDE)
	var i := 0
	for id in current:
		var e: EntityState = current[id]
		e.bake()
		var o := i * SnapshotColumns.PAWN_STRIDE
		fields[o] = e.q_px; fields[o + 1] = e.q_py; fields[o + 2] = e.q_pz
		fields[o + 3] = e.q_yaw; fields[o + 4] = e.q_pitch; fields[o + 5] = e.q_state
		fields[o + 6] = e.health; fields[o + 7] = e.squad
		fields[o + 8] = e.armor_class; fields[o + 9] = e.weapon
		i += 1
	assert_true(enc.begin_tick(7, ids, fields, PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array([0])))
	var nat_bytes: PackedByteArray = enc.encode_for(42, 1, 0, 99, ids, PackedInt32Array())
	assert_eq(nat_bytes, ref_bytes, "native keyframe must byte-equal Snapshot.encode")
	# and the unchanged GDScript decoder must accept it
	var view := {}
	Snapshot.decode_apply(nat_bytes, view)
	assert_eq(view.size(), 2)
	assert_almost_eq(view[1].pos.x, 10.0, 0.01)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter=native_encoder_smoke`
Expected: skip locally if you haven't rebuilt; after `cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml`, FAIL with "NativeSnapshotEncoder missing"…? No — the class won't exist until the bindings land; with the `.so` built but bindings absent the lib exports no class either. Accept either the skip (pre-build) or the CI-style fail — the point is it does not PASS yet.

- [ ] **Step 3: Implement the bindings in `src/lib.rs`**

```rust
mod core;
mod wire;

use crate::core::EncoderCore;
use godot::prelude::*;

struct SnapshotEncoderExt;

#[gdextension]
unsafe impl ExtensionLibrary for SnapshotEncoderExt {}

/// Server-side snapshot delta encoder + native baseline history (ADR-0003).
/// Owns no gameplay rules — pure codec + ack bookkeeping (ADR-0006 leaf rule).
#[derive(GodotClass)]
#[class(base = RefCounted)]
struct NativeSnapshotEncoder {
    base: Base<RefCounted>,
    core: EncoderCore,
}

#[godot_api]
impl IRefCounted for NativeSnapshotEncoder {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, core: EncoderCore::new() }
    }
}

#[godot_api]
impl NativeSnapshotEncoder {
    #[func]
    fn set_msg_id(&mut self, id: i64) { self.core.set_msg_id(id as u8); }

    /// Returns false on ragged columns (caller must fall back to the reference encoder).
    #[func]
    fn begin_tick(&mut self, tick: i64, ids: PackedInt32Array, fields: PackedInt32Array,
            vids: PackedInt32Array, vfields: PackedInt32Array,
            vseats: PackedInt32Array, vseat_off: PackedInt32Array) -> bool {
        match self.core.begin_tick(tick as u32, ids.as_slice(), fields.as_slice(),
                vids.as_slice(), vfields.as_slice(), vseats.as_slice(), vseat_off.as_slice()) {
            Ok(()) => true,
            Err(e) => { godot_error!("[native-enc] begin_tick: {e}"); false }
        }
    }

    /// Empty return = internal failure (caller falls back — see snapshot send integration).
    #[func]
    fn encode_for(&mut self, client_id: i64, seq: i64, want_baseline_seq: i64,
            last_input_tick: i64, interest_ids: PackedInt32Array,
            interest_vids: PackedInt32Array) -> PackedByteArray {
        match self.core.encode_for(client_id as i32, seq, want_baseline_seq,
                last_input_tick as u32, interest_ids.as_slice(), interest_vids.as_slice()) {
            Ok(v) => PackedByteArray::from(v.as_slice()),
            Err(e) => { godot_error!("[native-enc] encode_for(client {client_id}): {e}"); PackedByteArray::new() }
        }
    }

    #[func]
    fn on_ack(&mut self, client_id: i64, acked_seq: i64) { self.core.on_ack(client_id as i32, acked_seq); }

    #[func]
    fn remove_client(&mut self, client_id: i64) { self.core.remove_client(client_id as i32); }

    #[func]
    fn drop_entity_from_baselines(&mut self, entity_id: i64) { self.core.drop_entity_from_baselines(entity_id as i32); }

    #[func]
    fn reset(&mut self) { self.core.reset(); }

    // test/telemetry introspection
    #[func]
    fn history_len(&self, client_id: i64) -> i64 { self.core.history_len(client_id as i32) as i64 }

    #[func]
    fn live_tick_count(&self) -> i64 { self.core.live_tick_count() as i64 }
}
```

(`mod core` name-collides with the Rust `core` crate only in edge cases; if the compiler complains about `crate::core`, rename the module to `enc_core.rs` and adjust — keep the class code identical.)

- [ ] **Step 4: Build + run smoke**

```bash
cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml
godot --headless --path . --import   # let Godot register the new .gdextension once
godot --headless --path . -- --test --filter=native_encoder_smoke
```
Expected: PASS. Also run the full suite (`-- --test`): same count as before + new tests, 0 failures — the extension must not disturb anything else.

- [ ] **Step 5: Commit**

```bash
git add native/snapshot_encoder/ tests/native_encoder_smoke_test.gd
git commit -m "feat(native): NativeSnapshotEncoder gdext bindings + smoke parity test (ADR-0003 Task 7)"
```
(Also `git add` the `.uid` file Godot generates beside the `.gdextension` on first import.)

### Task 8: Differential fuzz harness (primary parity gate)

Dual-runs the GDScript reference (with faithful `server_main`-style history bookkeeping) and the native encoder over seeded random multi-tick scenarios; every packet must byte-equal. This test is the reason we can trust the swap.

**Files:**
- Test: `tests/native_parity_fuzz_test.gd`

- [ ] **Step 1: Write the test (it fails/skips until Tasks 5–7 are in; with them it must pass immediately — any failure is a real parity bug)**

```gdscript
extends TestCase
## ADR-0003 primary parity gate: reference Snapshot.encode + dict history vs
## NativeSnapshotEncoder over seeded random scenarios — byte equality on EVERY packet.

const TICKS := 120
const N_ENTITIES := 24
const N_VEHICLES := 3
const N_CLIENTS := 4
const SEEDS := [1, 7, 20260710]

var _rng := RandomNumberGenerator.new()

func _native_required() -> bool:
	if ClassDB.class_exists("NativeSnapshotEncoder"): return true
	if OS.get_environment("CI") != "": fail("NativeSnapshotEncoder missing in CI")
	else: print("[skip] native_parity_fuzz: .so not built")
	return false

func _rand_entity() -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(_rng.randf_range(-400, 400), _rng.randf_range(-5, 50), _rng.randf_range(-400, 400))
	e.yaw = _rng.randf_range(-10, 10); e.pitch = _rng.randf_range(-1.5, 1.5)
	e.stance = _rng.randi_range(0, 2); e.lean = _rng.randi_range(0, 2)
	e.team = _rng.randi_range(0, 1); e.alive = _rng.randf() > 0.1
	e.health = _rng.randi_range(-10, 310); e.is_downed = _rng.randf() > 0.9
	e.climbing = _rng.randf() > 0.95; e.squad = _rng.randi_range(0, 260)
	e.armor_class = _rng.randi_range(0, 2); e.weapon = _rng.randi_range(0, 5)
	return e

func _mutate(e: EntityState) -> void:
	if _rng.randf() < 0.6: e.pos.x += _rng.randf_range(-2, 2)
	if _rng.randf() < 0.4: e.pos.z += _rng.randf_range(-2, 2)
	if _rng.randf() < 0.3: e.yaw += _rng.randf_range(-0.5, 0.5)
	if _rng.randf() < 0.15: e.health = _rng.randi_range(-10, 310)
	if _rng.randf() < 0.1: e.stance = _rng.randi_range(0, 2)
	if _rng.randf() < 0.05: e.squad = _rng.randi_range(0, 260)
	if _rng.randf() < 0.05: e.alive = not e.alive

func _rand_vehicle() -> VehicleState:
	var v := VehicleState.new()
	v.pos = Vector3(_rng.randf_range(-300, 300), 0, _rng.randf_range(-300, 300))
	v.heading = _rng.randf_range(-4, 4); v.turret_yaw = _rng.randf_range(-2, 2)
	v.hp = _rng.randi_range(-5, 70000); v.type = _rng.randi_range(0, 3)
	var s: Array = []
	for k in _rng.randi_range(0, 3): s.append(_rng.randi_range(1, 128))
	v.seats = s
	return v

func _columns(state: Dictionary, ids: PackedInt32Array, fields: PackedInt32Array) -> void:
	ids.resize(state.size()); fields.resize(state.size() * SnapshotColumns.PAWN_STRIDE)
	var i := 0
	for id in state:
		var e: EntityState = state[id]
		if not e.q_baked: e.bake()
		ids[i] = id
		var o := i * SnapshotColumns.PAWN_STRIDE
		fields[o] = e.q_px; fields[o + 1] = e.q_py; fields[o + 2] = e.q_pz
		fields[o + 3] = e.q_yaw; fields[o + 4] = e.q_pitch; fields[o + 5] = e.q_state
		fields[o + 6] = e.health; fields[o + 7] = e.squad; fields[o + 8] = e.armor_class; fields[o + 9] = e.weapon
		i += 1

func _vcolumns(vstate: Dictionary, vids: PackedInt32Array, vfields: PackedInt32Array,
		vseats: PackedInt32Array, voff: PackedInt32Array) -> void:
	vids.resize(vstate.size()); vfields.resize(vstate.size() * SnapshotColumns.VEH_STRIDE)
	voff.resize(vstate.size() + 1)
	var total := 0
	for vid in vstate: total += (vstate[vid] as VehicleState).seats.size()
	vseats.resize(total)
	var i := 0; var so := 0
	for vid in vstate:
		var v: VehicleState = vstate[vid]
		if not v.q_baked: v.bake()
		vids[i] = vid
		var o := i * SnapshotColumns.VEH_STRIDE
		vfields[o] = v.q_px; vfields[o + 1] = v.q_py; vfields[o + 2] = v.q_pz
		vfields[o + 3] = v.q_heading; vfields[o + 4] = v.q_turret
		vfields[o + 5] = v.hp; vfields[o + 6] = v.type
		voff[i] = so
		for s in v.seats: vseats[so] = int(s); so += 1
		i += 1
	voff[vstate.size()] = so

func test_fuzz_parity() -> void:
	if not _native_required(): return
	for seed_v in SEEDS:
		_run_scenario(seed_v)

func _run_scenario(seed_v: int) -> void:
	_rng.seed = seed_v
	var enc = ClassDB.instantiate("NativeSnapshotEncoder")
	enc.set_msg_id(Protocol.Msg.SNAPSHOT)
	var truth := {}
	for i in N_ENTITIES: truth[i + 1] = _rand_entity()
	var vtruth := {}
	for i in N_VEHICLES: vtruth[10000 + i] = _rand_vehicle()
	var clients := {}
	for ci in N_CLIENTS:
		clients[100 + ci] = {"hist": {}, "hist_v": {}, "last_acked": 0, "next_seq": 1, "sent_seqs": []}
	for tick in TICKS:
		# world churn
		for id in truth: _mutate(truth[id])
		if _rng.randf() < 0.08 and truth.size() > 4: truth.erase(truth.keys()[_rng.randi_range(0, truth.size() - 1)])
		if _rng.randf() < 0.08: truth[1000 + tick] = _rand_entity()
		if _rng.randf() < 0.1:
			for vid in vtruth:
				var v: VehicleState = vtruth[vid]
				v.pos.x += _rng.randf_range(-3, 3); v.hp = _rng.randi_range(-5, 70000)
				if _rng.randf() < 0.3:
					var s: Array = []
					for k in _rng.randi_range(0, 3): s.append(_rng.randi_range(1, 128))
					v.seats = s
		# fresh per-tick clones (state_map semantics: baked once, shared across clients)
		var state := {}
		for id in truth: state[id] = (truth[id] as EntityState).clone()
		var vstate := {}
		for vid in vtruth: vstate[vid] = (vtruth[vid] as VehicleState).clone()
		var ids := PackedInt32Array(); var fields := PackedInt32Array()
		_columns(state, ids, fields)
		var vids := PackedInt32Array(); var vfields := PackedInt32Array()
		var vseats := PackedInt32Array(); var voff := PackedInt32Array()
		_vcolumns(vstate, vids, vfields, vseats, voff)
		assert_true(enc.begin_tick(tick, ids, fields, vids, vfields, vseats, voff))
		# occasional weapon-swap style baseline drop
		if _rng.randf() < 0.05 and state.size() > 0:
			var drop_id: int = state.keys()[_rng.randi_range(0, state.size() - 1)]
			enc.drop_entity_from_baselines(drop_id)
			for cid in clients:
				for s in clients[cid]["hist"]:
					(clients[cid]["hist"][s] as Dictionary).erase(drop_id)
		for cid in clients:
			var cl: Dictionary = clients[cid]
			# random interest subset, insertion order = state order (like _send_snapshots' current)
			var interest := PackedInt32Array()
			var current := {}
			for id in state:
				if _rng.randf() < 0.75:
					interest.append(id); current[id] = state[id]
			var vinterest := PackedInt32Array()
			var current_v := {}
			for vid in vstate:
				if _rng.randf() < 0.7:
					vinterest.append(vid); current_v[vid] = vstate[vid]
			# reference path — mirrors server_main.gd lines 923-947
			var bl_seq: int = cl["last_acked"]
			var baseline = cl["hist"].get(bl_seq)
			if baseline == null: baseline = {}; bl_seq = 0
			var baseline_v = cl["hist_v"].get(bl_seq)
			if baseline_v == null: baseline_v = {}
			var seq: int = cl["next_seq"]
			var ref_bytes := Snapshot.encode(tick, seq, bl_seq, tick * 3, current, baseline, current_v, baseline_v)
			var nat_bytes: PackedByteArray = enc.encode_for(cid, seq, cl["last_acked"], tick * 3, interest, vinterest)
			if nat_bytes != ref_bytes:
				fail("parity mismatch seed=%d tick=%d client=%d seq=%d ref=%d nat=%d bytes" \
					% [seed_v, tick, cid, seq, ref_bytes.size(), nat_bytes.size()])
				return
			cl["hist"][seq] = current; cl["hist_v"][seq] = current_v
			cl["next_seq"] = seq + 1
			cl["sent_seqs"].append(seq)
			var cutoff := seq - 32
			for s in cl["hist"].keys():
				if s < cutoff: cl["hist"].erase(s)
			for s in cl["hist_v"].keys():
				if s < cutoff: cl["hist_v"].erase(s)
			# random ack progression (sometimes stale → keyframe path exercised)
			if _rng.randf() < 0.6 and cl["sent_seqs"].size() > 0:
				var ack: int = cl["sent_seqs"][_rng.randi_range(0, cl["sent_seqs"].size() - 1)]
				if ack > cl["last_acked"]:
					cl["last_acked"] = ack
					enc.on_ack(cid, ack)
					for s in cl["hist"].keys():
						if s < ack: cl["hist"].erase(s)
					for s in cl["hist_v"].keys():
						if s < ack: cl["hist_v"].erase(s)
	print("[fuzz] seed %d: %d ticks × %d clients parity OK" % [seed_v, TICKS, N_CLIENTS])
```

- [ ] **Step 2: Run it**

Run: `godot --headless --path . -- --test --filter=native_parity_fuzz`
Expected: PASS (3 seeds). **If it fails, this is a real parity bug — use superpowers:systematic-debugging; the failure message pins seed/tick/client/seq for a deterministic repro.** Shrink by lowering TICKS/N_CLIENTS and hex-diffing `ref_bytes` vs `nat_bytes`.

- [ ] **Step 3: Commit**

```bash
git add tests/native_parity_fuzz_test.gd
git commit -m "test(native): differential fuzz parity gate — reference vs native, byte-equal (ADR-0003 Task 8)"
```

### Task 9: Golden vectors (drift pin)

Pins BOTH encoders to committed bytes so an accidental semantic change in either (e.g. a refactor of `snapshot.gd`) fails loudly even without the other side present.

**Files:**
- Create: `tools/gen_snapshot_golden.gd`
- Create: `tests/fixtures/snapshot_golden_scenario.json` (generated)
- Create: `tests/fixtures/snapshot_golden_expected.bin` (generated)
- Test: `tests/snapshot_golden_test.gd`

- [ ] **Step 1: Write the generator**

`tools/gen_snapshot_golden.gd` (run: `godot --headless --path . --script tools/gen_snapshot_golden.gd`):

```gdscript
extends SceneTree
## Regenerates the snapshot golden vectors from the GDScript REFERENCE encoder.
## Run ONLY when the wire format deliberately changes (then bump VERSION and update
## both encoders first). Scenario is expressed in quantized column space.

const TICKS := 40
const SEED := 20260710

func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var scenario := {"ticks": []}
	var expected := PackedByteArray()
	var truth := {}
	for i in 8: truth[i + 1] = _rand_fields(rng)
	var vtruth := {10001: _rand_vfields(rng)}
	var hist := {}; var hist_v := {}
	var last_acked := 0
	for tick in TICKS:
		for id in truth: _mutate_fields(rng, truth[id])
		if tick == 15: truth.erase(2)
		if tick == 20: truth[99] = _rand_fields(rng)
		var trec := {"tick": tick, "pawns": {}, "vehicles": {}, "sends": []}
		for id in truth: trec["pawns"][str(id)] = truth[id].duplicate()
		for vid in vtruth: trec["vehicles"][str(vid)] = vtruth[vid].duplicate(true)
		# one client, deterministic interest = all ids except a rotating skip
		var current := {}
		var interest: Array = []
		var skip: int = truth.keys()[tick % truth.size()]
		for id in truth:
			if id == skip and tick % 3 == 0: continue
			interest.append(id)
			current[id] = _state_from(truth[id])
		var current_v := {}
		var vinterest: Array = []
		for vid in vtruth:
			vinterest.append(vid); current_v[vid] = _vstate_from(vtruth[vid])
		var bl_seq := last_acked
		var baseline = hist.get(bl_seq); if baseline == null: baseline = {}; bl_seq = 0
		var baseline_v = hist_v.get(bl_seq); if baseline_v == null: baseline_v = {}
		var seq := tick + 1
		var bytes := Snapshot.encode(tick, seq, bl_seq, tick * 2, current, baseline, current_v, baseline_v)
		trec["sends"].append({"cid": 7, "seq": seq, "want_baseline": last_acked,
			"lit": tick * 2, "interest": interest, "vinterest": vinterest, "len": bytes.size()})
		var lenb := PackedByteArray(); lenb.resize(4); lenb.encode_u32(0, bytes.size())
		expected.append_array(lenb); expected.append_array(bytes)
		hist[seq] = current; hist_v[seq] = current_v
		if tick % 2 == 0: last_acked = seq
		scenario["ticks"].append(trec)
	DirAccess.make_dir_recursive_absolute("res://tests/fixtures")
	var f := FileAccess.open("res://tests/fixtures/snapshot_golden_scenario.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(scenario)); f.close()
	var fb := FileAccess.open("res://tests/fixtures/snapshot_golden_expected.bin", FileAccess.WRITE)
	fb.store_buffer(expected); fb.close()
	print("[golden] wrote %d ticks, %d expected bytes" % [TICKS, expected.size()])
	quit()

func _rand_fields(rng: RandomNumberGenerator) -> Array:
	return [rng.randi_range(-400000, 400000), rng.randi_range(-5000, 50000), rng.randi_range(-400000, 400000),
		rng.randi_range(0, 65535), rng.randi_range(0, 65535), rng.randi_range(0, 255),
		rng.randi_range(-10, 310), rng.randi_range(0, 260), rng.randi_range(0, 2), rng.randi_range(0, 5)]

func _mutate_fields(rng: RandomNumberGenerator, f: Array) -> void:
	if rng.randf() < 0.6: f[0] += rng.randi_range(-2000, 2000)
	if rng.randf() < 0.3: f[3] = rng.randi_range(0, 65535)
	if rng.randf() < 0.15: f[6] = rng.randi_range(-10, 310)
	if rng.randf() < 0.1: f[5] = rng.randi_range(0, 255)

func _rand_vfields(rng: RandomNumberGenerator) -> Dictionary:
	return {"f": [rng.randi_range(-300000, 300000), 0, rng.randi_range(-300000, 300000),
		rng.randi_range(0, 65535), rng.randi_range(0, 65535), rng.randi_range(-5, 70000), rng.randi_range(0, 3)],
		"seats": [rng.randi_range(1, 128)]}

func _state_from(f: Array) -> EntityState:
	var e := EntityState.new()
	e.q_px = f[0]; e.q_py = f[1]; e.q_pz = f[2]; e.q_yaw = f[3]; e.q_pitch = f[4]; e.q_state = f[5]
	e.health = f[6]; e.squad = f[7]; e.armor_class = f[8]; e.weapon = f[9]
	e.q_baked = true
	return e

func _vstate_from(d: Dictionary) -> VehicleState:
	var v := VehicleState.new()
	var f: Array = d["f"]
	v.q_px = f[0]; v.q_py = f[1]; v.q_pz = f[2]; v.q_heading = f[3]; v.q_turret = f[4]
	v.hp = f[5]; v.type = f[6]; v.seats = (d["seats"] as Array).duplicate()
	v.q_baked = true
	return v
```

- [ ] **Step 2: Generate the fixtures**

Run: `godot --headless --path . --script tools/gen_snapshot_golden.gd`
Expected: `[golden] wrote 40 ticks, ... bytes`; two files under `tests/fixtures/`.

- [ ] **Step 3: Write the test**

`tests/snapshot_golden_test.gd`:

```gdscript
extends TestCase
## Replays the committed golden scenario through BOTH encoders and checks every packet
## against the committed expected bytes. Regenerate ONLY on deliberate wire changes
## (tools/gen_snapshot_golden.gd) and say so in the commit message.

func test_reference_matches_golden() -> void:
	_replay(false)

func test_native_matches_golden() -> void:
	if not ClassDB.class_exists("NativeSnapshotEncoder"):
		if OS.get_environment("CI") != "": fail("NativeSnapshotEncoder missing in CI")
		else: print("[skip] golden native: .so not built")
		return
	_replay(true)

func _replay(native: bool) -> void:
	var scenario: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/snapshot_golden_scenario.json"))
	var expected := FileAccess.get_file_as_bytes("res://tests/fixtures/snapshot_golden_expected.bin")
	var off := 0
	var enc = null
	if native:
		enc = ClassDB.instantiate("NativeSnapshotEncoder")
		enc.set_msg_id(Protocol.Msg.SNAPSHOT)
	var hist := {}; var hist_v := {}
	for trec in scenario["ticks"]:
		var tick := int(trec["tick"])
		# rebuild per-tick state from the recorded quantized columns
		var state := {}
		for sid in trec["pawns"]: state[int(sid)] = _state_from(trec["pawns"][sid])
		var vstate := {}
		for svid in trec["vehicles"]: vstate[int(svid)] = _vstate_from(trec["vehicles"][svid])
		if native:
			var ids := PackedInt32Array(); var fields := PackedInt32Array()
			_pack_columns(state, ids, fields)
			var vids := PackedInt32Array(); var vfields := PackedInt32Array()
			var vseats := PackedInt32Array(); var voff := PackedInt32Array()
			_pack_vcolumns(vstate, vids, vfields, vseats, voff)
			assert_true(enc.begin_tick(tick, ids, fields, vids, vfields, vseats, voff))
		for send in trec["sends"]:
			var want := int(send["len"])
			var exp_len := expected.decode_u32(off); off += 4
			assert_eq(exp_len, want)
			var exp := expected.slice(off, off + exp_len); off += exp_len
			var bytes: PackedByteArray
			if native:
				var interest := PackedInt32Array()
				for id in send["interest"]: interest.append(int(id))
				var vinterest := PackedInt32Array()
				for vid in send["vinterest"]: vinterest.append(int(vid))
				bytes = enc.encode_for(int(send["cid"]), int(send["seq"]), int(send["want_baseline"]),
					int(send["lit"]), interest, vinterest)
			else:
				var current := {}
				for id in send["interest"]: current[int(id)] = state[int(id)]
				var current_v := {}
				for vid in send["vinterest"]: current_v[int(vid)] = vstate[int(vid)]
				var bl_seq := int(send["want_baseline"])
				var baseline = hist.get(bl_seq); if baseline == null: baseline = {}; bl_seq = 0
				var baseline_v = hist_v.get(bl_seq); if baseline_v == null: baseline_v = {}
				bytes = Snapshot.encode(tick, int(send["seq"]), bl_seq, int(send["lit"]), current, baseline, current_v, baseline_v)
				hist[int(send["seq"])] = current; hist_v[int(send["seq"])] = current_v
			assert_eq(bytes, exp, "golden mismatch tick=%d" % tick)

func _state_from(f: Array) -> EntityState:
	var e := EntityState.new()
	e.q_px = int(f[0]); e.q_py = int(f[1]); e.q_pz = int(f[2]); e.q_yaw = int(f[3]); e.q_pitch = int(f[4])
	e.q_state = int(f[5]); e.health = int(f[6]); e.squad = int(f[7]); e.armor_class = int(f[8]); e.weapon = int(f[9])
	e.q_baked = true
	return e

func _vstate_from(d: Dictionary) -> VehicleState:
	var v := VehicleState.new()
	var f: Array = d["f"]
	v.q_px = int(f[0]); v.q_py = int(f[1]); v.q_pz = int(f[2]); v.q_heading = int(f[3]); v.q_turret = int(f[4])
	v.hp = int(f[5]); v.type = int(f[6]); v.seats = (d["seats"] as Array).duplicate()
	v.q_baked = true
	return v

func _pack_columns(state: Dictionary, ids: PackedInt32Array, fields: PackedInt32Array) -> void:
	ids.resize(state.size()); fields.resize(state.size() * SnapshotColumns.PAWN_STRIDE)
	var i := 0
	for id in state:
		var e: EntityState = state[id]
		var o := i * SnapshotColumns.PAWN_STRIDE
		ids[i] = id
		fields[o] = e.q_px; fields[o + 1] = e.q_py; fields[o + 2] = e.q_pz
		fields[o + 3] = e.q_yaw; fields[o + 4] = e.q_pitch; fields[o + 5] = e.q_state
		fields[o + 6] = e.health; fields[o + 7] = e.squad; fields[o + 8] = e.armor_class; fields[o + 9] = e.weapon
		i += 1

func _pack_vcolumns(vstate: Dictionary, vids: PackedInt32Array, vfields: PackedInt32Array,
		vseats: PackedInt32Array, voff: PackedInt32Array) -> void:
	vids.resize(vstate.size()); vfields.resize(vstate.size() * SnapshotColumns.VEH_STRIDE)
	voff.resize(vstate.size() + 1)
	var total := 0
	for vid in vstate: total += (vstate[vid] as VehicleState).seats.size()
	vseats.resize(total)
	var i := 0; var so := 0
	for vid in vstate:
		var v: VehicleState = vstate[vid]
		var o := i * SnapshotColumns.VEH_STRIDE
		vids[i] = vid
		vfields[o] = v.q_px; vfields[o + 1] = v.q_py; vfields[o + 2] = v.q_pz
		vfields[o + 3] = v.q_heading; vfields[o + 4] = v.q_turret; vfields[o + 5] = v.hp; vfields[o + 6] = v.type
		voff[i] = so
		for s in v.seats: vseats[so] = int(s); so += 1
		i += 1
	voff[vstate.size()] = so
```

Note the golden scenario uses a single client whose reference history is rebuilt during replay — the recorded `want_baseline` in the scenario is what drives native baseline resolution; the generator only acks every other tick so both delta and keyframe paths are pinned. (The generator's scenario JSON stores plain pawn field Arrays; `duplicate()` snapshots them per tick.)

- [ ] **Step 4: Run**

Run: `godot --headless --path . -- --test --filter=snapshot_golden`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit (fixtures included — they are the pin)**

```bash
git add tools/gen_snapshot_golden.gd tests/fixtures/ tests/snapshot_golden_test.gd
git commit -m "test(net): golden snapshot vectors pin reference + native encoders (ADR-0003 Task 9)"
```

### Task 10: Server integration — native path in `_send_snapshots` + lifecycle hooks

**Files:**
- Modify: `server/server_main.gd` (`configure()` ~line 163, `_send_snapshots()` ~line 872, `_handle_input` ack block ~line 1251, `_force_reenter` ~line 1196, `_on_peer_disconnected` ~line 2243, rotation wipe ~lines 299–307)

No new unit test drives this (it is wiring, proven by the fuzz/golden/smoke tests + connect smoke + the parity-audit run in Task 11); the hard checks are the full suite, `ci/connect_smoke_test.sh`, and Task 14's gates. Review this task with a subagent — it touches the hot loop.

- [ ] **Step 1: Encoder selection in `configure()`**

Add fields near the other server state (~line 112):

```gdscript
var _enc_native = null            # NativeSnapshotEncoder when built + selected (ADR-0003)
var _enc_native_failed := false   # any native failure → permanent reference fallback this process
var _col_ids := PackedInt32Array()
var _col_fields := PackedInt32Array()
var _col_vids := PackedInt32Array()
var _col_vfields := PackedInt32Array()
var _col_vseats := PackedInt32Array()
var _col_vseat_off := PackedInt32Array()
```

In `configure(args)` (after the existing flag parsing ~line 184):

```gdscript
	# ADR-0003: --encoder=gd forces the GDScript reference path (A/B gate runs).
	if String(args.get("encoder", "native")) != "gd" and ClassDB.class_exists("NativeSnapshotEncoder"):
		_enc_native = ClassDB.instantiate("NativeSnapshotEncoder")
		_enc_native.set_msg_id(Protocol.Msg.SNAPSHOT)
		print("[server] snapshot encoder: NATIVE (ADR-0003)")
	else:
		print("[server] snapshot encoder: GDScript reference")
```

- [ ] **Step 2: Rework `_send_snapshots()`**

Keep the Task 1 timers. Shape (existing code marked `# unchanged`):

```gdscript
func _send_snapshots() -> void:
	var t_q := 0; var t_enc := 0; var t_send := 0; var t_struct := 0; var t_self := 0
	var use_native := _enc_native != null and not _enc_native_failed
	var t0 := Time.get_ticks_usec()
	var state := {}
	var vstate := {}
	if use_native:
		var wby := {}
		for cid in _clients: wby[cid] = int(_clients[cid].get("weapon", Weapon.AR))
		SnapshotColumns.extract_pawns(_sim.world, wby, _col_ids, _col_fields)
		SnapshotColumns.extract_vehicles(_sim.world, _col_vids, _col_vfields, _col_vseats, _col_vseat_off)
		if not _enc_native.begin_tick(_sim.tick, _col_ids, _col_fields, _col_vids, _col_vfields, _col_vseats, _col_vseat_off):
			_native_encoder_fail("begin_tick")
			return   # skip this tick's sends; next tick runs the reference path
	else:
		state = _sim.world.state_map()
		for sid in state:                              # unchanged weapon stamp
			if _clients.has(sid):
				(state[sid] as EntityState).weapon = int(_clients[sid].get("weapon", Weapon.AR))
		vstate = _sim.world.vehicle_state_map()
	t_enc += Time.get_ticks_usec() - t0
	for id in _clients:
		if (_sim.tick + id) % _snapshot_stride != 0:    # unchanged stagger
			continue
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null: continue
		t0 = Time.get_ticks_usec()
		_sync_structure_baselines(c, self_pawn.pos)     # unchanged
		t_struct += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, _positions)
		if ids.size() > MAX_SNAPSHOT_ENTITIES:
			# unchanged enemy-cull block, EXCEPT team source becomes the pawn (identical value,
			# works on both paths): replace `int(state[vid].team)` with
			# `(_sim.world.get_pawn(vid) as Pawn).team`
			...
		t_q += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		var seq: int = c["next_seq"]
		var bytes: PackedByteArray
		if use_native:
			var vlist := PackedInt32Array()
			for vid in _sim.world.vehicles:
				if self_pawn.pos.distance_to((_sim.world.vehicles[vid] as Vehicle).pos) <= INTEREST_RADIUS:
					vlist.append(vid)
			bytes = _enc_native.encode_for(id, seq, c["last_acked_seq"], c["last_input_tick"],
				PackedInt32Array(ids), vlist)
			if bytes.is_empty():
				_native_encoder_fail("encode_for client %d" % id)
				return
		else:
			# unchanged reference block: current/current_v dicts, baseline lookups,
			# Snapshot.encode(...), then (below, after send) history store + prune
			...
		t_enc += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)   # unchanged
		t_send += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		# unchanged SELF_STATE block
		...
		t_self += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		if not use_native:
			# unchanged: c["history"][seq] = current; history_v; prune to MAX_HISTORY
			...
		c["next_seq"] = seq + 1
		_tele.add_bytes(id, bytes.size())               # unchanged
		t_enc += Time.get_ticks_usec() - t0
	# unchanged sub-bucket accumulation from Task 1
	...

func _native_encoder_fail(where: String) -> void:
	_enc_native_failed = true
	push_error("[native-enc] %s failed — permanent fallback to GDScript reference encoder" % where)
```

Key parity points: the vehicle interest filter uses the same float `distance_to` on the same `Vehicle.pos` the reference reads via `to_state()`, and iterates `world.vehicles` in the same order `vehicle_state_map()` does; `ids` order is untouched (query order, or `kept.keys()` order after the cull). A skipped tick after a native failure is safe — clients already tolerate stride-skipped snapshots, and the reference path self-heals via the keyframe fallback since `c["history"]` is empty.

- [ ] **Step 3: Lifecycle hooks**

In `_handle_input` (~line 1251), inside the existing `if ack > c["last_acked_seq"]:` block, after `c["last_acked_seq"] = ack` add:

```gdscript
		if _enc_native != null: _enc_native.on_ack(id, ack)
```

(the existing dict prunes below it stay — they are no-ops on the native path).

In `_force_reenter(pid)` (~line 1196), first line of the function body:

```gdscript
	if _enc_native != null: _enc_native.drop_entity_from_baselines(pid)
```

In `_on_peer_disconnected` (~line 2243), where the client id is resolved and `_clients` is cleaned up:

```gdscript
	if _enc_native != null: _enc_native.remove_client(id)
```

In the rotation/match-boundary wipe (~lines 299–307, next to `_net.disconnect_all()`):

```gdscript
	if _enc_native != null: _enc_native.reset()
```

- [ ] **Step 4: Run everything local**

```bash
godot --headless --path . -- --test          # full suite: previous count + new tests, 0 failures
./ci/connect_smoke_test.sh                   # connect smoke with the native encoder active
```
Also boot a local server once with `--encoder=gd` and confirm the `[server] snapshot encoder: GDScript reference` line — the A/B switch works.

- [ ] **Step 5: Request review, then commit**

Use superpowers:requesting-code-review (read-only reviewer; verify HEAD after). Then:

```bash
git add server/server_main.gd
git commit -m "feat(server): native snapshot encoder path + lifecycle hooks, --encoder=gd fallback (ADR-0003 Task 10)"
```

### Task 11: `--parity-audit` live dual-run flag

**Files:**
- Modify: `server/server_main.gd` (`configure()`, `_send_snapshots()`)

- [ ] **Step 1: Implement**

`configure()`: `_parity_audit = args.has("parity-audit")` (new `var _parity_audit := false` field).

In `_send_snapshots()`, when `_parity_audit and use_native`: also run the reference bookkeeping — build `state`/`vstate` (the `else` branch's prep) unconditionally at tick top, and per client compute `ref_bytes` via the reference block (current/baseline dicts + `Snapshot.encode` + history store) alongside the native `bytes`, then:

```gdscript
			if bytes != ref_bytes:
				push_error("[parity-audit] MISMATCH client=%d seq=%d tick=%d nat=%dB ref=%dB"
					% [id, seq, _sim.tick, bytes.size(), ref_bytes.size()])
				_native_encoder_fail("parity-audit")
				return
```

Audit mode intentionally pays double encode cost (it exists for one gate run, printed loudly at boot: `print("[server] PARITY AUDIT ON — double encode cost")`). Send the NATIVE bytes. Keep both histories consistent (reference history stores happen in audit mode so `ref_bytes` baselines stay valid).

- [ ] **Step 2: Verify locally**

Boot server + `ci/` smoke bots with `--parity-audit` for a couple of minutes; expect zero `[parity-audit] MISMATCH` lines and a clean shutdown. Run the full suite.

- [ ] **Step 3: Commit**

```bash
git add server/server_main.gd
git commit -m "feat(server): --parity-audit live dual-encode comparison (ADR-0003 Task 11)"
```

### Task 12: CI + gate-script build integration

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `docker/docker-compose.yml` (server `command`)
- Modify: `docker/stress.sh` (env docs + fail-fast)

- [ ] **Step 1: CI Rust build**

In `.github/workflows/ci.yml`, before the "Import resources" step:

```yaml
      - name: Rust toolchain (native snapshot encoder)
        uses: dtolnay/rust-toolchain@stable

      - name: Cargo cache
        uses: Swatinem/rust-cache@v2
        with:
          workspaces: native/snapshot_encoder

      - name: Build + test native snapshot encoder
        run: |
          cargo test --release --manifest-path native/snapshot_encoder/Cargo.toml
          cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml
```

GitHub sets `CI=true`, so the `_native_required()` guards in the GDScript tests now FAIL (not skip) if the class is missing — the parity gate cannot silently vanish from CI. (voice_opus stays unbuilt in CI — unchanged.)

- [ ] **Step 2: Compose A/B switch + fail-fast**

`docker/docker-compose.yml` server command gains `"--encoder=${ENCODER:-native}"` after `--time-limit=...`. In `docker/stress.sh` after `source ./_gate_lib.sh` add:

```bash
# ADR-0003: the fleet gate must exercise the shipped encoder — refuse to run without the
# built .so unless the reference path was explicitly requested (ENCODER=gd).
if [ "${ENCODER:-native}" != "gd" ] && [ ! -f ../native/snapshot_encoder/target/release/libsnapshot_encoder.so ]; then
	echo "FATAL: native snapshot encoder not built (cargo build --release --manifest-path ../native/snapshot_encoder/Cargo.toml)"; exit 1
fi
```

and document `ENCODER` in the Env usage comment.

- [ ] **Step 3: Verify**

Local: `ENCODER=gd ./docker/stress.sh` refuses nothing; unset with the `.so` deleted refuses to run. Push the branch and confirm the GitHub CI job goes green including the native parity tests.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml docker/docker-compose.yml docker/stress.sh
git commit -m "ci: build+test native snapshot encoder; fleet gate encoder switch + fail-fast (ADR-0003 Task 12)"
```

### Task 13: Wire-change discipline note in the reference encoder

**Files:**
- Modify: `shared/net/snapshot.gd` (header comment only)

- [ ] **Step 1: Add to the file-top doc comment**

```gdscript
## PARITY CONTRACT (ADR-0003): native/snapshot_encoder/ must produce byte-identical output.
## ANY change to this wire format must (1) update the Rust encoder, (2) regenerate the golden
## vectors (tools/gen_snapshot_golden.gd), (3) re-run the fuzz parity suite, (4) bump VERSION.
```

- [ ] **Step 2: Suite still green, commit**

```bash
godot --headless --path . -- --test
git add shared/net/snapshot.gd
git commit -m "docs(net): parity-contract change discipline on the reference encoder (ADR-0003 Task 13)"
```

### Task 14: Phase A gates — the FAIL→PASS flip (hard evidence)

The exact E-core config that failed Phase 0 at 34.84 ms must pass. All runs on game2, dense map. (E-core server pinning here is the deliberate ADR-0003 budget-proxy exception to AGENTS.md §8.)

- [ ] **Step 1: Reference-path E-core run (the "before", with sub-buckets)**

```bash
cd docker
ENCODER=gd SERVER_CPUS=16,17,18,19 BOTS_CPUS=0-15 BOT_REPLICAS=16 BOT_COUNT=8 \
  MAP=conquest_town LABEL=phaseA-ecore-gdref ./stress.sh
```
Expected: **FAIL** ≈ 34–35 ms peak (matches Phase 0), `snapenc` dominant. Keep the evidence file.

- [ ] **Step 2: Native-path E-core run (the flip)**

```bash
ENCODER=native SERVER_CPUS=16,17,18,19 BOTS_CPUS=0-15 BOT_REPLICAS=16 BOT_COUNT=8 \
  MAP=conquest_town LABEL=phaseA-ecore-native ./stress.sh
```
Expected: **PASS** — peak tick **< 33.3 ms with margin (target ≤ ~22 ms)**, `snapenc` **≤ ~6 ms**, p99 under budget, 0 script errors, no `[native-enc]` fallback lines. If it passes but `snapenc` > 6 ms, profile before celebrating — the win must come from the encoder, not noise.

- [ ] **Step 3: Parity-audit fleet run (one-off)**

```bash
SERVER_EXTRA_NOTE="parity audit" ENCODER=native SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 \
  BOT_REPLICAS=16 BOT_COUNT=8 MAP=conquest_town LABEL=phaseA-parity-audit ./stress.sh
```
…with `--parity-audit` added to the compose server command for this run (add/remove it by hand or via a `PARITY_AUDIT` env passthrough analogous to `ENCODER` — one-line compose change). P-cores are fine here (this run checks bytes, not budget; audit doubles encode cost). Expected: full match, **zero** `[parity-audit] MISMATCH` lines (grep the saved srvlog), verdict may be judged on completion not tick budget.

- [ ] **Step 4: P-core no-regression run**

```bash
ENCODER=native SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 \
  MAP=conquest_town LABEL=phaseA-pcore-native ./stress.sh
```
Expected: PASS with peak tick comfortably below the previous ~24–26 ms P-core baseline (snap should drop from ~14 ms to a few ms).

- [ ] **Step 5: Full verification sweep (superpowers:verification-before-completion)**

Full suite (`godot --headless --path . -- --test` — 0 failures), `ci/connect_smoke_test.sh`, GitHub CI green on the branch, all four evidence files committed under `docs/gate-evidence/`.

- [ ] **Step 6: Land + docs**

Update `docs/TASKS.md` (perf-track note → Phase A DONE with the before/after numbers) and the ADR-0003 "Verification / gates" section with the measured results. Then land per AGENTS.md §11 (commit → fetch → merge master → push) using superpowers:finishing-a-development-branch, and run `/graphify --update`.

```bash
git add docs/gate-evidence/ docs/TASKS.md docs/adr/0003-native-snapshot-encoder.md
git commit -m "gate(perf): Phase A E-core flip — 34.84ms FAIL → PASS with native encoder (ADR-0003)"
```

---

## Phase B — parallel encode, serial send (DEFERRED — do not start until triggered)

**Trigger (either):** a 256-player milestone is actually scheduled, **or** post-destruction E-core headroom drops below ~5 ms at 128p. Re-validate this plan section against the then-current code before executing; the Phase A architecture (immutable `Arc<TickData>`, per-client partitioned history) was built so these tasks stay small.

### Task 15: `encode_batch` + rayon worker pool

**Files:**
- Modify: `native/snapshot_encoder/Cargo.toml` (add `rayon = "1"`)
- Modify: `native/snapshot_encoder/src/core.rs`, `src/lib.rs`

Core: split `EncoderCore.hist` so each client's `BTreeMap` can be `&mut` independently (e.g. take the per-client maps out of the FxHashMap into a scratch Vec for the batch, or wrap each in its own cell) and add:

```rust
pub struct EncodeReq {
    pub client: i32, pub seq: i64, pub want_baseline_seq: i64,
    pub last_input_tick: u32, pub interest_ids: Vec<i32>, pub interest_vids: Vec<i32>,
}

pub fn encode_batch(&mut self, reqs: Vec<EncodeReq>) -> Vec<Result<Vec<u8>, String>> {
    // partition: one (client-history, req) pair per rayon task; TickData is Arc-shared read-only.
    // Each task runs the existing single-client encode path (factor encode_for's body into
    // fn encode_one(cur: &Arc<TickData>, hist: &mut BTreeMap<i64, HistoryRec>, msg_id: u8, req: &EncodeReq))
    // then reassemble the history map. No Godot API inside tasks.
}
```

Binding: `#[func] fn encode_batch(&mut self, requests: Array) -> Array` where each request is `[client_id, seq, want_baseline_seq, last_input_tick, PackedInt32Array, PackedInt32Array]` and the return is positionally matched `PackedByteArray`s (empty = that client failed). Worker count: `min(4, num_cpus)` with a `set_workers(n)` func for the `--encode-workers=N` server flag.

Tests (cargo): `encode_batch` output byte-equals sequential `encode_for` for the same requests (build two cores, feed identical ticks — this transitively inherits the GDScript parity proof); a duplicate-client batch returns an error for the duplicate, not a data race (reject duplicates up front).

GDScript: `_send_snapshots` gains a batch path behind `--encode-workers=N>1`: first loop collects due clients' `(seq, interest, vinterest)` (structure sync + cull as today), one `encode_batch` call, second loop does `_net.send_to` + SELF_STATE + `next_seq`/telemetry. Fuzz test extends with a batch-mode scenario asserting equality with reference bytes.

### Task 16: Phase B scaling gate

Bench harness: a headless script that loads a recorded dense-tick column set, calls `encode_batch` for 128 and 256 synthetic clients at workers = 1/2/4, and prints wall-time per tick. Gate: near-linear scaling to ≥3× at 4 workers; then a raised-player-count fleet run (bot fleet at the target count) with peak tick under budget on the production-class host. Evidence to `docs/gate-evidence/`, ADR-0003 updated with Phase B results.

---

## Self-review notes (spec coverage)

- Spec §3 columns → Tasks 2–3; §4 native model/API/invariants/error handling → Tasks 5–7; §5 seam/fallback → Task 10; §6 parity layers → Tasks 7 (roundtrip via decode_apply + smoke), 8 (fuzz), 9 (golden), 11+14 (live audit); §7 Phase B → Tasks 15–16; §8 build/CI → Tasks 4, 12; §9 instrumentation + gates → Tasks 1, 14; §10 risks → Task 13 (drift discipline), Task 6 (`live_tick_count` bound), Task 10 (fallback).
- No VERSION bump anywhere: output is byte-identical, dispatch/msg ids unchanged.
- The reference encoder (`shared/net/snapshot.gd`) is modified only by a comment (Task 13) — it remains the parity oracle.
