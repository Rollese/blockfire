extends TestCase

func test_input_round_trip() -> void:
	var bytes := InputCommand.encode(123, 45, 1.0, -0.5, 1.2, -0.3, 0b101)
	var d := InputCommand.decode(bytes)
	assert_eq(d["client_tick"], 123)
	assert_eq(d["ack_seq"], 45)
	assert_almost_eq(d["move_x"], 1.0, 0.001)
	assert_almost_eq(d["move_y"], -0.5, 0.001)
	assert_almost_eq(d["yaw"], 1.2, 0.001)
	assert_eq(d["buttons"], 0b101)

func test_move_is_clamped_to_unit() -> void:
	var d := InputCommand.decode(InputCommand.encode(0, 0, 5.0, 0.0, 0.0, 0.0, 0))
	assert_almost_eq(d["move_x"], 1.0, 0.001, "over-unit input clamps to 1.0")
