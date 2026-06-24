extends TestCase
## ViewmodelAnim: pure swing/swap offset curves.

func test_rest_outside_phase_range() -> void:
	for kind in [ViewmodelAnim.SWING, ViewmodelAnim.SWAP]:
		var before: Dictionary = ViewmodelAnim.sample(kind, -0.1)
		var after: Dictionary = ViewmodelAnim.sample(kind, 1.0)
		var way_after: Dictionary = ViewmodelAnim.sample(kind, 2.0)
		assert_true(before["pos"] == Vector3.ZERO and before["rot"] == Vector3.ZERO, "rest before start")
		assert_true(after["pos"] == Vector3.ZERO and after["rot"] == Vector3.ZERO, "rest at/after end")
		assert_true(way_after["pos"] == Vector3.ZERO, "rest well past end")

func test_swing_returns_to_rest_at_both_ends_and_peaks_mid() -> void:
	var start: Dictionary = ViewmodelAnim.sample(ViewmodelAnim.SWING, 0.0)
	assert_almost_eq(float(start["rot"].y), 0.0, 0.001, "swing starts from rest")
	var mid: Dictionary = ViewmodelAnim.sample(ViewmodelAnim.SWING, 0.5)
	assert_true(mid["rot"] != Vector3.ZERO and mid["pos"] != Vector3.ZERO, "mid-swing is active (thrust + rotate)")
	assert_true(mid["pos"].z < 0.0, "thrusts the muzzle forward (-Z)")

func test_swap_starts_lowered_and_rises_to_rest() -> void:
	var start: Dictionary = ViewmodelAnim.sample(ViewmodelAnim.SWAP, 0.0)
	assert_true(start["pos"].y < -0.1, "weapon starts lowered out of frame")
	var late: Dictionary = ViewmodelAnim.sample(ViewmodelAnim.SWAP, 0.95)
	assert_true(late["pos"].y > start["pos"].y, "rises back toward rest over time")
