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
