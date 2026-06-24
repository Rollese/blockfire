extends TestCase
## F3 debug perf-overlay toggle (M7): set_perf_visible flips the green fps/draws readout without
## touching the rest of the HUD. Default on (preserves the dev workflow).

func test_perf_overlay_visible_by_default() -> void:
	var h := HudView.new()
	h._build_perf()
	assert_true(h._perf_label.visible, "perf overlay starts visible")
	h.free()

func test_set_perf_visible_toggles_the_label() -> void:
	var h := HudView.new()
	h._build_perf()
	h.set_perf_visible(false)
	assert_false(h._perf_label.visible, "F3 hides the perf overlay")
	h.set_perf_visible(true)
	assert_true(h._perf_label.visible, "F3 re-shows the perf overlay")
	h.free()

func test_set_perf_visible_is_safe_before_build() -> void:
	# Called before the label exists (scene not built yet) — must not crash.
	var h := HudView.new()
	h.set_perf_visible(false)
	assert_true(true, "no crash when _perf_label is null")
	h.free()
