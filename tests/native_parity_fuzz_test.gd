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
	if ClassDB.class_exists("NativeSnapshotEncoder"):
		return true
	if OS.get_environment("CI") != "":
		fail("NativeSnapshotEncoder missing in CI")
	else:
		print("[skip] native_parity_fuzz: .so not built")
	return false

func _rand_entity() -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(_rng.randf_range(-400, 400), _rng.randf_range(-5, 50), _rng.randf_range(-400, 400))
	e.yaw = _rng.randf_range(-10, 10)
	e.pitch = _rng.randf_range(-1.5, 1.5)
	e.stance = _rng.randi_range(0, 2)
	e.lean = _rng.randi_range(0, 2)
	e.team = _rng.randi_range(0, 1)
	e.alive = _rng.randf() > 0.1
	e.health = _rng.randi_range(-10, 310)
	e.is_downed = _rng.randf() > 0.9
	e.climbing = _rng.randf() > 0.95
	e.squad = _rng.randi_range(0, 260)
	e.armor_class = _rng.randi_range(0, 2)
	e.weapon = _rng.randi_range(0, 5)
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
	v.heading = _rng.randf_range(-4, 4)
	v.turret_yaw = _rng.randf_range(-2, 2)
	v.hp = _rng.randi_range(-5, 70000)
	v.type = _rng.randi_range(0, 3)
	var s: Array = []
	for k in _rng.randi_range(0, 3): s.append(_rng.randi_range(1, 128))
	v.seats = s
	return v

func _columns(state: Dictionary, ids: PackedInt32Array, fields: PackedInt32Array) -> void:
	ids.resize(state.size())
	fields.resize(state.size() * SnapshotColumns.PAWN_STRIDE)
	var i := 0
	for id in state:
		var e: EntityState = state[id]
		if not e.q_baked: e.bake()
		ids[i] = id
		var o := i * SnapshotColumns.PAWN_STRIDE
		fields[o] = e.q_px; fields[o + 1] = e.q_py; fields[o + 2] = e.q_pz
		fields[o + 3] = e.q_yaw; fields[o + 4] = e.q_pitch; fields[o + 5] = e.q_state
		fields[o + 6] = e.health; fields[o + 7] = e.squad
		fields[o + 8] = e.armor_class; fields[o + 9] = e.weapon
		i += 1

func _vcolumns(vstate: Dictionary, vids: PackedInt32Array, vfields: PackedInt32Array,
		vseats: PackedInt32Array, voff: PackedInt32Array) -> void:
	vids.resize(vstate.size())
	vfields.resize(vstate.size() * SnapshotColumns.VEH_STRIDE)
	voff.resize(vstate.size() + 1)
	var total := 0
	for vid in vstate: total += (vstate[vid] as VehicleState).seats.size()
	vseats.resize(total)
	var i := 0
	var so := 0
	for vid in vstate:
		var v: VehicleState = vstate[vid]
		if not v.q_baked: v.bake()
		vids[i] = vid
		var o := i * SnapshotColumns.VEH_STRIDE
		vfields[o] = v.q_px; vfields[o + 1] = v.q_py; vfields[o + 2] = v.q_pz
		vfields[o + 3] = v.q_heading; vfields[o + 4] = v.q_turret
		vfields[o + 5] = v.hp; vfields[o + 6] = v.type
		voff[i] = so
		for s in v.seats:
			vseats[so] = int(s)
			so += 1
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
		if _rng.randf() < 0.08 and truth.size() > 4:
			truth.erase(truth.keys()[_rng.randi_range(0, truth.size() - 1)])
		if _rng.randf() < 0.08: truth[1000 + tick] = _rand_entity()
		if _rng.randf() < 0.1:
			for vid in vtruth:
				var v: VehicleState = vtruth[vid]
				v.pos.x += _rng.randf_range(-3, 3)
				v.hp = _rng.randi_range(-5, 70000)
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
		# occasional weapon-swap style baseline drop (mirrors _force_reenter)
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
					interest.append(id)
					current[id] = state[id]
			var vinterest := PackedInt32Array()
			var current_v := {}
			for vid in vstate:
				if _rng.randf() < 0.7:
					vinterest.append(vid)
					current_v[vid] = vstate[vid]
			# reference path — mirrors server_main.gd _send_snapshots baseline resolution
			var bl_seq: int = cl["last_acked"]
			var baseline = cl["hist"].get(bl_seq)
			if baseline == null:
				baseline = {}; bl_seq = 0
			var baseline_v = cl["hist_v"].get(bl_seq)
			if baseline_v == null:
				baseline_v = {}
			var seq: int = cl["next_seq"]
			var ref_bytes := Snapshot.encode(tick, seq, bl_seq, tick * 3, current, baseline, current_v, baseline_v)
			var nat_bytes: PackedByteArray = enc.encode_for(cid, seq, cl["last_acked"], tick * 3, interest, vinterest)
			if nat_bytes != ref_bytes:
				fail("parity mismatch seed=%d tick=%d client=%d seq=%d ref=%d nat=%d bytes" \
					% [seed_v, tick, cid, seq, ref_bytes.size(), nat_bytes.size()])
				return
			cl["hist"][seq] = current
			cl["hist_v"][seq] = current_v
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
