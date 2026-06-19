extends TestCase
const Fall := preload("res://shared/sim/fall.gd")

func test_safe_fall_no_damage() -> void:
	assert_eq(Fall.damage_for(0.0), 0, "no fall, no damage")
	assert_eq(Fall.damage_for(4.0), 0, "at the safe threshold, no damage")
	assert_eq(Fall.damage_for(3.5), 0, "below threshold, no damage")

func test_damage_scales_above_threshold() -> void:
	assert_true(Fall.damage_for(6.0) > 0, "above threshold deals damage")
	assert_true(Fall.damage_for(9.0) > Fall.damage_for(6.0), "more height -> more damage")

func test_big_fall_is_lethal() -> void:
	assert_true(Fall.damage_for(12.0) >= 100, "a ~12m fall is lethal (>=100)")
