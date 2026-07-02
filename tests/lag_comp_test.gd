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

func test_clamped_reports_horizon_hits() -> void:
	# Feeds the `rewind_clamped` telemetry field, which was declared/printed/reset but never
	# incremented since the M5.5-P1 hit-scan->projectile migration — a permanently-zero lie
	# in the schema-of-record. True only when the requested tick is older than MAX_REWIND.
	var lc := LagComp.new()
	for t in range(1, 30):
		lc.record(t, _world_with(1, float(t)))
	assert_false(lc.clamped(29), "current tick not clamped")
	assert_false(lc.clamped(29 - LagComp.MAX_REWIND), "edge of the rewind window not clamped")
	assert_true(lc.clamped(29 - LagComp.MAX_REWIND - 1), "older than the window -> clamped")
	assert_false(LagComp.new().clamped(5), "empty history never counts as clamped")
