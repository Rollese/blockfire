extends TestCase

func _state(x: float, team := 0) -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(x, 0, 0)
	e.team = team
	e.alive = true
	return e

# keyframe snapshot (baseline empty) with local id 1 at origin + remote id 2 at remote_x
func _snap(seq: int, remote_x: float) -> PackedByteArray:
	var current := {1: _state(0.0, 0), 2: _state(remote_x, 1)}
	return Snapshot.encode(100 + seq, seq, 0, seq, current, {})

func test_remotes_interpolate_excluding_self() -> void:
	var wv := WorldView.new()
	wv.set_local_id(1)
	wv.apply_snapshot(_snap(1, 0.0), 1.0)
	wv.apply_snapshot(_snap(2, 10.0), 1.1)
	var remotes := wv.remotes_at(1.15)   # render at 1.05 = halfway between the two
	assert_false(remotes.has(1), "local id excluded from remotes")
	assert_true(remotes.has(2), "remote id present")
	assert_almost_eq(remotes[2].pos.x, 5.0, 0.2, "remote lerped ~halfway")

func test_self_state_is_latest_authoritative() -> void:
	var wv := WorldView.new()
	wv.set_local_id(1)
	wv.apply_snapshot(_snap(1, 0.0), 1.0)
	var s := wv.self_state()
	assert_true(s != null, "self present after snapshot")
	assert_almost_eq(s.pos.x, 0.0, 0.1, "self authoritative pos")
	assert_eq(wv.last_header["last_input_tick"], 1, "header surfaced")
