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

func test_health_drop_alone() -> void:
	# 50 HP lost == PRESSURE_HP_REF, no aim -> exactly 1.0
	assert_almost_eq(Perception.infer_pressure(100.0, 50.0, false), 1.0, 0.001, "full-ref damage alone -> 1.0")

func test_aimed_at_alone() -> void:
	assert_almost_eq(Perception.infer_pressure(100.0, 100.0, true), 0.5, 0.001, "aimed-at with no damage -> 0.5")
