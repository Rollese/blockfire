extends TestCase

func test_maps_actions_to_button_bits() -> void:
	var bits := InputMap2.buttons_from({"sprint": true, "jump": true, "fire": true})
	assert_true(bits & InputCommand.BTN_SPRINT)
	assert_true(bits & InputCommand.BTN_JUMP)
	assert_true(bits & InputCommand.BTN_FIRE)
	assert_false(bits & InputCommand.BTN_PRONE)

func test_empty_is_zero() -> void:
	assert_eq(InputMap2.buttons_from({}), 0)
