extends TestCase
## ADR-0003 A.5 parity gate for the native interest+cull layer (encode_for_auto).
## The wire ORDER is no longer pinned to the GDScript grid (decode is order-independent), so
## this harness verifies at the decoded-VIEW level: a GDScript oracle replicates the documented
## membership rule (exact 3D distance on quantized mm ints, d2 <= r2; over-cap keeps self +
## all teammates + nearest max_enemies enemies, ties by ascending id), feeds Snapshot.encode,
## and both packet streams must decode to EXACTLY equal views every send.
## The byte-level fuzz/golden tests (explicit-interest encode_for) still guard the codec core.

const TICKS := 120
const N_ENTITIES := 24
const N_VEHICLES := 3
const N_CLIENTS := 4
const SEEDS := [3, 11, 20260711]
const RADIUS_MM := 100000        # 100 m — small enough that walkers cross the boundary
const MAX_ENTITIES := 8          # force the enemy cull constantly
const MAX_ENEMIES := 3

var _rng := RandomNumberGenerator.new()

func _native_required() -> bool:
	if ClassDB.class_exists("NativeSnapshotEncoder"):
		return true
	if OS.get_environment("CI") != "":
		fail("NativeSnapshotEncoder missing in CI")
	else:
		print("[skip] native_interest_view: .so not built")
	return false

func _rand_entity() -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(_rng.randf_range(-150, 150), _rng.randf_range(-5, 20), _rng.randf_range(-150, 150))
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
	if _rng.randf() < 0.7: e.pos.x += _rng.randf_range(-6, 6)
	if _rng.randf() < 0.5: e.pos.z += _rng.randf_range(-6, 6)
	if _rng.randf() < 0.3: e.yaw += _rng.randf_range(-0.5, 0.5)
	if _rng.randf() < 0.15: e.health = _rng.randi_range(-10, 310)
	if _rng.randf() < 0.05: e.squad = _rng.randi_range(0, 260)

func _rand_vehicle() -> VehicleState:
	var v := VehicleState.new()
	v.pos = Vector3(_rng.randf_range(-150, 150), 0, _rng.randf_range(-150, 150))
	v.heading = _rng.randf_range(-4, 4)
	v.turret_yaw = _rng.randf_range(-2, 2)
	v.hp = _rng.randi_range(-5, 70000)
	v.type = _rng.randi_range(0, 3)
	var s: Array = []
	for k in _rng.randi_range(0, 2): s.append(_rng.randi_range(1, 128))
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

## Oracle: the documented native membership rule, on the same quantized ints.
func _oracle_members(state: Dictionary, self_id: int) -> Dictionary:
	var s: EntityState = state[self_id]
	var r2 := RADIUS_MM * RADIUS_MM
	var members: Array = []
	var d2_of := {}
	for id in state:
		var e: EntityState = state[id]
		var dx := e.q_px - s.q_px
		var dy := e.q_py - s.q_py
		var dz := e.q_pz - s.q_pz
		var d2 := dx * dx + dy * dy + dz * dz
		if d2 <= r2:
			members.append(id)
			d2_of[id] = d2
	if members.size() > MAX_ENTITIES:
		var steam := (s.q_state >> 4) & 1
		var kept := {self_id: true}
		var enemies: Array = []
		for id in members:
			if id == self_id: continue
			if ((state[id] as EntityState).q_state >> 4) & 1 == steam:
				kept[id] = true
			else:
				enemies.append([d2_of[id], id])
		enemies.sort()
		var n := 0
		for pair in enemies:
			if n >= MAX_ENEMIES: break
			kept[pair[1]] = true
			n += 1
		var culled: Array = []
		for id in members:
			if kept.has(id): culled.append(id)
		members = culled
	var out := {}
	for id in members: out[id] = true
	return out

func _oracle_vmembers(vstate: Dictionary, s: EntityState) -> Dictionary:
	var r2 := RADIUS_MM * RADIUS_MM
	var out := {}
	for vid in vstate:
		var v: VehicleState = vstate[vid]
		var dx := v.q_px - s.q_px
		var dy := v.q_py - s.q_py
		var dz := v.q_pz - s.q_pz
		if dx * dx + dy * dy + dz * dz <= r2:
			out[vid] = true
	return out

func _entity_eq(a: EntityState, b: EntityState) -> bool:
	return a.pos == b.pos and a.yaw == b.yaw and a.pitch == b.pitch and a.stance == b.stance \
		and a.lean == b.lean and a.team == b.team and a.alive == b.alive and a.health == b.health \
		and a.is_downed == b.is_downed and a.climbing == b.climbing and a.squad == b.squad \
		and a.armor_class == b.armor_class and a.weapon == b.weapon

func _views_equal(nv: Dictionary, rv: Dictionary) -> bool:
	if nv.size() != rv.size(): return false
	for id in nv:
		if not rv.has(id): return false
		if not _entity_eq(nv[id], rv[id]): return false
	return true

func _vviews_equal(nv: Dictionary, rv: Dictionary) -> bool:
	if nv.size() != rv.size(): return false
	for vid in nv:
		if not rv.has(vid): return false
		var a: VehicleState = nv[vid]
		var b: VehicleState = rv[vid]
		if not (a.pos == b.pos and a.heading == b.heading and a.turret_yaw == b.turret_yaw \
				and a.hp == b.hp and a.type == b.type and a.seats == b.seats):
			return false
	return true

func test_auto_interest_view_parity() -> void:
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
		# self entity = ids 1..N_CLIENTS (never erased below)
		clients[100 + ci] = {"self": ci + 1, "hist": {}, "hist_v": {}, "last_acked": 0,
			"next_seq": 1, "sent_seqs": [], "nat_view": {}, "nat_vview": {}, "ref_view": {}, "ref_vview": {}}
	for tick in TICKS:
		for id in truth: _mutate(truth[id])
		if _rng.randf() < 0.08 and truth.size() > N_CLIENTS + 4:
			var victim: int = truth.keys()[_rng.randi_range(0, truth.size() - 1)]
			if victim > N_CLIENTS: truth.erase(victim)   # keep self entities alive
		if _rng.randf() < 0.08: truth[1000 + tick] = _rand_entity()
		if _rng.randf() < 0.15:
			for vid in vtruth:
				var v: VehicleState = vtruth[vid]
				v.pos.x += _rng.randf_range(-8, 8)
				if _rng.randf() < 0.2: v.hp = _rng.randi_range(-5, 70000)
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
		if _rng.randf() < 0.05:
			var drop_id: int = state.keys()[_rng.randi_range(0, state.size() - 1)]
			enc.drop_entity_from_baselines(drop_id)
			for cid in clients:
				for s in clients[cid]["hist"]:
					(clients[cid]["hist"][s] as Dictionary).erase(drop_id)
		for cid in clients:
			var cl: Dictionary = clients[cid]
			var self_id: int = cl["self"]
			# oracle membership -> reference current dicts (state iteration order)
			var members := _oracle_members(state, self_id)
			var current := {}
			for id in state:
				if members.has(id): current[id] = state[id]
			var vmembers := _oracle_vmembers(vstate, state[self_id])
			var current_v := {}
			for vid in vstate:
				if vmembers.has(vid): current_v[vid] = vstate[vid]
			var bl_seq: int = cl["last_acked"]
			var baseline = cl["hist"].get(bl_seq)
			if baseline == null:
				baseline = {}; bl_seq = 0
			var baseline_v = cl["hist_v"].get(bl_seq)
			if baseline_v == null:
				baseline_v = {}
			var seq: int = cl["next_seq"]
			var ref_bytes := Snapshot.encode(tick, seq, bl_seq, tick * 3, current, baseline, current_v, baseline_v)
			var nat_bytes: PackedByteArray = enc.encode_for_auto(cid, self_id, seq, cl["last_acked"],
				tick * 3, RADIUS_MM, MAX_ENTITIES, MAX_ENEMIES)
			assert_true(not nat_bytes.is_empty(), "encode_for_auto failed")
			Snapshot.decode_apply(nat_bytes, cl["nat_view"], cl["nat_vview"])
			Snapshot.decode_apply(ref_bytes, cl["ref_view"], cl["ref_vview"])
			if not _views_equal(cl["nat_view"], cl["ref_view"]) or not _vviews_equal(cl["nat_vview"], cl["ref_vview"]):
				fail("view mismatch seed=%d tick=%d client=%d seq=%d (nat %d/%d ents, ref %d/%d)" \
					% [seed_v, tick, cid, seq, cl["nat_view"].size(), cl["nat_vview"].size(), cl["ref_view"].size(), cl["ref_vview"].size()])
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
			if _rng.randf() < 0.6 and cl["sent_seqs"].size() > 0:
				var ack: int = cl["sent_seqs"][_rng.randi_range(0, cl["sent_seqs"].size() - 1)]
				if ack > cl["last_acked"]:
					cl["last_acked"] = ack
					enc.on_ack(cid, ack)
					for s in cl["hist"].keys():
						if s < ack: cl["hist"].erase(s)
					for s in cl["hist_v"].keys():
						if s < ack: cl["hist_v"].erase(s)
	print("[view-fuzz] seed %d: %d ticks × %d clients auto-interest view parity OK" % [seed_v, TICKS, N_CLIENTS])
