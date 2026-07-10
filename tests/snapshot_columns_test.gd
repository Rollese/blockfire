extends TestCase
## SnapshotColumns extraction must equal state_map()+bake() field-for-field (ADR-0003).
## The columns are the FFI contract with native/snapshot_encoder — any divergence here is
## a wire-parity bug, not a style issue.

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

func test_vehicle_columns_match_state_map_bake() -> void:
	var w := World.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in 5:
		var v := Vehicle.new()
		v.id = Vehicle.ID_BASE + i
		v.pos = Vector3(rng.randf_range(-300, 300), 0, rng.randf_range(-300, 300))
		v.heading = rng.randf_range(-4.0, 4.0)
		v.turret_yaw = rng.randf_range(-2.0, 2.0)
		v.hp = rng.randi_range(-10, 70000)
		v.type = rng.randi_range(0, 3)
		var s: Array = []
		for k in i % 3: s.append(rng.randi_range(1, 128))
		v.seats = s
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

func test_arrays_reused_without_leftover() -> void:
	# resize() down must not leave stale rows when the world shrinks between ticks.
	var w := _mk_world()
	var ids := PackedInt32Array(); var fields := PackedInt32Array()
	SnapshotColumns.extract_pawns(w, {}, ids, fields)
	w.despawn(1); w.despawn(2)
	SnapshotColumns.extract_pawns(w, {}, ids, fields)
	assert_eq(ids.size(), w.pawns.size())
	assert_eq(fields.size(), ids.size() * SnapshotColumns.PAWN_STRIDE)
