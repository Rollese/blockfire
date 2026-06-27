extends TestCase

func test_maps_actions_to_button_bits() -> void:
	var bits := InputMap2.buttons_from({"sprint": true, "jump": true, "fire": true})
	assert_true(bits & InputCommand.BTN_SPRINT)
	assert_true(bits & InputCommand.BTN_JUMP)
	assert_true(bits & InputCommand.BTN_FIRE)
	assert_false(bits & InputCommand.BTN_PRONE)

func test_empty_is_zero() -> void:
	assert_eq(InputMap2.buttons_from({}), 0)

func test_aim_maps_to_aim_bit() -> void:
	assert_true(InputMap2.buttons_from({"aim": true}) & InputCommand.BTN_AIM, "aim action -> BTN_AIM")
	assert_false(InputMap2.buttons_from({"fire": true}) & InputCommand.BTN_AIM, "non-aim doesn't set it")
