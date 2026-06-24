extends TestCase
## Viewmodel locomotion (M7): subtle walk bob scaled by speed + a sprint-lower offset that drops
## the gun out of the aim. Pure helpers on ViewmodelAnim.

func test_no_bob_at_a_standstill() -> void:
	var b := ViewmodelAnim.walk_bob(0.0, 1.2)
	assert_eq(b["pos"], Vector3.ZERO, "no bob when not moving")
	assert_eq(b["rot"], Vector3.ZERO, "no roll sway when not moving")

func test_bob_scales_with_speed_and_stays_small() -> void:
	var slow := (ViewmodelAnim.walk_bob(0.3, PI * 0.5)["pos"] as Vector3).length()
	var fast := (ViewmodelAnim.walk_bob(1.0, PI * 0.5)["pos"] as Vector3).length()
	assert_true(fast > slow, "faster movement = more bob")
	assert_true(fast < 0.05, "bob stays subtle (<5 cm)")

func test_bob_dips_down_each_step() -> void:
	# Y is down-weighted (a footfall dip), so it should never push the gun UP.
	for i in 8:
		var phase := TAU * float(i) / 8.0
		var y: float = (ViewmodelAnim.walk_bob(1.0, phase)["pos"] as Vector3).y
		assert_true(y <= 0.0001, "bob never lifts the gun above rest")

func test_sprint_lower_drops_the_gun() -> void:
	assert_true(ViewmodelAnim.SPRINT_LOWER_POS.y < 0.0, "sprint lowers the gun (−Y)")
	assert_true(ViewmodelAnim.SPRINT_LOWER_ROT.x > 0.0, "sprint angles the muzzle down (+pitch)")
