extends TestCase
## BuildSite (M12-P2): pure progressive-construction math — builder eligibility, progress accrual
## gated by min_builders, completion, decay. Deterministic; the server drives sites with these.

func test_solo_advances_small_site() -> void:
	var p := BuildSite.progress_step(0.0, 90, 1, 1, SimLoop.DT)
	assert_true(p > 0.0, "solo builder advances a min_builders=1 site")

func test_solo_blocked_on_large_site() -> void:
	var p := BuildSite.progress_step(100.0, 600, 1, 2, SimLoop.DT)
	assert_eq(p, 100.0, "a large (min 2) site does NOT advance with one builder")

func test_two_builders_advance_large_site() -> void:
	var p := BuildSite.progress_step(100.0, 600, 2, 2, SimLoop.DT)
	assert_true(p > 100.0, "two builders advance a min 2 site")

func test_progress_clamps_at_build_cost() -> void:
	var p := BuildSite.progress_step(599.0, 600, 4, 2, 1.0)
	assert_eq(p, 600.0, "progress never exceeds build_cost")

func test_more_builders_build_faster_up_to_cap() -> void:
	var two := BuildSite.progress_step(0.0, 10000, 2, 1, SimLoop.DT)
	var four := BuildSite.progress_step(0.0, 10000, 4, 1, SimLoop.DT)
	var eight := BuildSite.progress_step(0.0, 10000, 8, 1, SimLoop.DT)
	assert_true(four > two, "4 builders faster than 2")
	assert_almost_eq(eight, four, 0.001, "builders past MAX_BUILDERS_PER_SITE add nothing")

func test_is_complete() -> void:
	assert_true(BuildSite.is_complete(600.0, 600), "progress >= cost is complete")
	assert_false(BuildSite.is_complete(599.9, 600), "just under is not complete")

func test_eligibility_range_and_facing() -> void:
	var site := Vector3(0, 0, 5)
	assert_true(BuildSite.eligible(Vector3(0, 0, 2), Vector3(0, 0, 1), site), "in range + facing -> eligible")
	assert_false(BuildSite.eligible(Vector3(0, 0, 2), Vector3(0, 0, -1), site), "facing away -> not eligible")
	assert_false(BuildSite.eligible(Vector3(0, 0, -50), Vector3(0, 0, 1), site), "out of range -> not eligible")

func test_decay() -> void:
	assert_false(BuildSite.decayed(100, 100), "fresh work -> not decayed")
	assert_true(BuildSite.decayed(100 + BuildSite.BUILD_SITE_DECAY_TICKS, 100), "no work for the window -> decayed")

func test_dismantle_reduces_progress_floored_at_zero() -> void:
	var p := BuildSite.dismantle_step(50.0, 1, SimLoop.DT)
	assert_true(p < 50.0, "an enemy digging reduces progress")
	assert_eq(BuildSite.dismantle_step(5.0, 4, 1.0), 0.0, "dismantle floors at 0, never negative")
