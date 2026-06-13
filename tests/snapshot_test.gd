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
