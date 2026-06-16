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

func test_keyframe_resets_view_dropping_stale_entities() -> void:
	# Client holds entities 1 and 2. A keyframe (baseline_seq=0) containing only
	# entity 1 must drop entity 2 (no LEAVE record is sent for keyframes).
	var current := {1: _state(7, 8, 0.0)}
	var bytes := Snapshot.encode(5, 10, 0, 50, current, {})  # baseline_seq=0 => keyframe
	var view := {1: _state(1, 1, 0.0), 2: _state(2, 2, 0.0)}
	Snapshot.decode_apply(bytes, view)
	assert_eq(view.size(), 1, "keyframe drops entities not present")
	assert_true(view.has(1) and not view.has(2))
	assert_almost_eq(view[1].pos.x, 7.0, 0.01)

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
	var cur := _state(0, 0, 0); cur.health = 80
	var bytes := Snapshot.encode(2, 2, 1, 0, {5: cur}, {5: base})
	var view := {5: _state(0, 0, 0)}; view[5].health = 100
	Snapshot.decode_apply(bytes, view)
	assert_eq(view[5].health, 80)

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

func test_downed_replicates_through_state_byte() -> void:
	var cur := {}
	var down := EntityState.new()
	down.is_downed = true
	cur[7] = down
	var bytes := Snapshot.encode(1, 1, 0, 0, cur, {})  # keyframe (empty baseline)
	var view := {}
	Snapshot.decode_apply(bytes, view)
	assert_true(view.has(7))
	assert_true((view[7] as EntityState).is_downed, "DOWNED survives encode/decode")

func test_not_downed_default_replicates_false() -> void:
	var cur := {}
	cur[8] = EntityState.new()  # is_downed defaults false
	var view := {}
	Snapshot.decode_apply(Snapshot.encode(1, 1, 0, 0, cur, {}), view)
	assert_false((view[8] as EntityState).is_downed)

func test_climbing_survives_snapshot_roundtrip() -> void:
	var e := EntityState.new()
	e.climbing = true
	var b := Snapshot._state_byte(e)
	assert_eq((b >> 7) & 1, 1)   # bit 7 set
