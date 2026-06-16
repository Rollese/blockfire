extends TestCase

func test_clamp_axis_bounds() -> void:
	assert_almost_eq(InputValidate.clamp_axis(5.0), 1.0, 0.0001)
	assert_almost_eq(InputValidate.clamp_axis(-9.0), -1.0, 0.0001)
	assert_almost_eq(InputValidate.clamp_axis(0.3), 0.3, 0.0001)

func test_sanitize_move_renormalizes_overlong() -> void:
	var m := InputValidate.sanitize_move(1.0, 1.0)   # len ~1.41 -> normalized
	assert_almost_eq(Vector2(m.x, m.y).length(), 1.0, 0.001)

func test_sanitize_move_keeps_short_vectors() -> void:
	var m := InputValidate.sanitize_move(0.3, 0.4)
	assert_almost_eq(m.x, 0.3, 0.0001)
	assert_almost_eq(m.y, 0.4, 0.0001)

func test_view_rate_ok_flags_teleporting_aim() -> void:
	assert_true(InputValidate.view_rate_ok(0.0, 0.1, 0.0, 0.05, 0.5))
	assert_false(InputValidate.view_rate_ok(0.0, 3.0, 0.0, 0.0, 0.5))   # 3 rad in one tick
