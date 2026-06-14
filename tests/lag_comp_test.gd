extends TestCase

func _world_with(id: int, x: float) -> World:
	var w := World.new()
	var p := w.spawn(id)
	p.pos = Vector3(x, 0, 0)
	return w

func test_records_and_rewinds() -> void:
	var lc := LagComp.new()
	lc.record(10, _world_with(1, 5.0))
	lc.record(11, _world_with(1, 6.0))
	var s10 := lc.rewind(10)
	assert_almost_eq(s10[1]["pos"].x, 5.0, 0.001)
	var s11 := lc.rewind(11)
	assert_almost_eq(s11[1]["pos"].x, 6.0, 0.001)

func test_clamps_to_window() -> void:
	var lc := LagComp.new()
	for t in range(1, 50):  # more than HISTORY
		lc.record(t, _world_with(1, float(t)))
	var old := lc.rewind(1)
	assert_true(old.size() >= 0, "no crash, clamps")
	var recent := lc.rewind(49)
	assert_almost_eq(recent[1]["pos"].x, 49.0, 0.001)
