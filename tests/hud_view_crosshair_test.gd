extends TestCase
## Dynamic crosshair (M7): the 4 reticle ticks sit at BASE_GAP+spread from centre and hide when dead.

func test_build_makes_four_ticks_and_a_dot() -> void:
	var h := HudView.new()
	h._build_crosshair()
	assert_eq(h._ch_ticks.size(), 4, "four reticle ticks")
	assert_true(h._ch_dot != null, "centre dot exists")
	h.free()

func test_resting_gap_is_base_gap() -> void:
	var h := HudView.new()
	h._build_crosshair()
	h.update_crosshair(0.0, false)
	# top tick (index 0): its inner (bottom) edge sits at -BASE_GAP above centre.
	assert_almost_eq(h._ch_ticks[0].offset_bottom, -HudView.CH_BASE_GAP, 0.01, "rest gap = base gap")
	h.free()

func test_spread_pushes_ticks_outward() -> void:
	var h := HudView.new()
	h._build_crosshair()
	h.update_crosshair(0.0, false)
	var rest: float = h._ch_ticks[3].offset_left   # right tick inner edge at rest
	h.update_crosshair(12.0, false)
	assert_true(h._ch_ticks[3].offset_left > rest, "more spread pushes the right tick further out")
	assert_almost_eq(h._ch_ticks[3].offset_left, HudView.CH_BASE_GAP + 12.0, 0.01, "inner edge = gap+spread")
	h.free()

func test_hidden_pulls_the_reticle() -> void:
	var h := HudView.new()
	h._build_crosshair()
	h.update_crosshair(5.0, true)
	assert_false(h._ch_ticks[0].visible, "dead/deploy hides the reticle")
	assert_false(h._ch_dot.visible, "dot hidden too")
	h.update_crosshair(5.0, false)
	assert_true(h._ch_ticks[0].visible, "shown again when alive")
	h.free()
