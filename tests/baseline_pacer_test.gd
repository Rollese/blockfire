extends TestCase

func _c(region: Vector2i, dist2: float, pieces: int) -> Dictionary:
	return {"region": region, "dist2": dist2, "pieces": pieces}

func test_empty_candidates_returns_empty() -> void:
	assert_eq(BaselinePacer.pick([], 500).size(), 0, "nothing to send -> empty")

func test_under_budget_sends_all_nearest_first() -> void:
	var got := BaselinePacer.pick([
		_c(Vector2i(2, 0), 400.0, 100),
		_c(Vector2i(0, 0), 10.0, 100),
		_c(Vector2i(1, 0), 100.0, 100),
	], 500)
	assert_eq(got.size(), 3, "all three fit under the 500 budget")
	assert_eq(got[0]["region"], Vector2i(0, 0), "nearest region first")
	assert_eq(got[2]["region"], Vector2i(2, 0), "farthest region last")

func test_over_budget_stops_at_cap() -> void:
	var got := BaselinePacer.pick([
		_c(Vector2i(0, 0), 1.0, 300),
		_c(Vector2i(1, 0), 2.0, 300),
		_c(Vector2i(2, 0), 3.0, 300),
	], 500)
	assert_eq(got.size(), 1, "300 + 300 > 500 -> only the first region this tick")
	assert_eq(got[0]["region"], Vector2i(0, 0), "the nearest one streams first")

func test_single_region_larger_than_budget_still_streams() -> void:
	# A region with more pieces than the whole budget must still send (forward progress), else it would
	# never replicate and the client would be permanently missing those structures.
	var got := BaselinePacer.pick([_c(Vector2i(0, 0), 1.0, 9000)], 500)
	assert_eq(got.size(), 1, "an over-budget lone region still streams to guarantee progress")

func test_packs_multiple_small_regions_up_to_budget() -> void:
	var cands: Array = []
	for i in 10:
		cands.append(_c(Vector2i(i, 0), float(i), 90))   # 90 each
	var got := BaselinePacer.pick(cands, 500)
	assert_eq(got.size(), 5, "5 * 90 = 450 <= 500; the 6th (540) would exceed -> deferred")
