extends TestCase
## Replays the committed golden scenario through BOTH encoders and checks every packet
## against the committed expected bytes. Regenerate ONLY on deliberate wire changes
## (tools/gen_snapshot_golden.gd) and say so in the commit message.

func test_reference_matches_golden() -> void:
	_replay(false)

func test_native_matches_golden() -> void:
	if not ClassDB.class_exists("NativeSnapshotEncoder"):
		if OS.get_environment("CI") != "":
			fail("NativeSnapshotEncoder missing in CI")
		else:
			print("[skip] golden native: .so not built")
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
	var hist := {}
	var hist_v := {}
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
			var exp_len := expected.decode_u32(off)
			off += 4
			assert_eq(exp_len, want)
			var exp := expected.slice(off, off + exp_len)
			off += exp_len
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
				var baseline = hist.get(bl_seq)
				if baseline == null:
					baseline = {}; bl_seq = 0
				var baseline_v = hist_v.get(bl_seq)
				if baseline_v == null:
					baseline_v = {}
				bytes = Snapshot.encode(tick, int(send["seq"]), bl_seq, int(send["lit"]), current, baseline, current_v, baseline_v)
				hist[int(send["seq"])] = current
				hist_v[int(send["seq"])] = current_v
			assert_eq(bytes, exp, "golden mismatch tick=%d native=%s" % [tick, str(native)])

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
	v.hp = int(f[5]); v.type = int(f[6])
	v.seats = (d["seats"] as Array).duplicate()
	v.q_baked = true
	return v

func _pack_columns(state: Dictionary, ids: PackedInt32Array, fields: PackedInt32Array) -> void:
	ids.resize(state.size())
	fields.resize(state.size() * SnapshotColumns.PAWN_STRIDE)
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
		var o := i * SnapshotColumns.VEH_STRIDE
		vids[i] = vid
		vfields[o] = v.q_px; vfields[o + 1] = v.q_py; vfields[o + 2] = v.q_pz
		vfields[o + 3] = v.q_heading; vfields[o + 4] = v.q_turret; vfields[o + 5] = v.hp; vfields[o + 6] = v.type
		voff[i] = so
		for s in v.seats:
			vseats[so] = int(s)
			so += 1
		i += 1
	voff[vstate.size()] = so
