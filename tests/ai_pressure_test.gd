extends TestCase
const Perception := preload("res://bots/ai/perception.gd")
func test_health_drop_raises_pressure() -> void:
	var p := Perception.infer_pressure(100.0, 70.0, true)
	assert_true(p > 0.5, "health loss + aimed-at -> elevated pressure")
func test_no_damage_no_aim_is_calm() -> void:
	var p := Perception.infer_pressure(100.0, 100.0, false)
	assert_almost_eq(p, 0.0, 0.001, "no loss, not aimed at -> calm")
func test_pressure_clamped_to_one() -> void:
	var p := Perception.infer_pressure(100.0, 0.0, true)
	assert_true(p <= 1.0, "pressure never exceeds 1.0")
