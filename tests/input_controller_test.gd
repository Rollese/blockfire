extends TestCase

func _ic() -> InputController:
	return InputController.new()

func test_gather_returns_full_command_shape_with_no_input() -> void:
	var ic := _ic()
	var s := ClientSettings.new()
	var cmd := ic.gather(s)
	for k in ["move_x", "move_y", "yaw", "pitch", "buttons"]:
		assert_true(cmd.has(k), "command has %s" % k)
	assert_eq(cmd["buttons"], 0, "no buttons pressed headless")
	assert_almost_eq(cmd["move_x"], 0.0, 0.001, "no movement headless")
	assert_almost_eq(cmd["move_y"], 0.0, 0.001)

func test_pitch_clamps_to_max() -> void:
	var ic := _ic()
	var s := ClientSettings.new()
	ic.apply_look(Vector2(0, -100000), s)   # huge upward look
	assert_true(ic.pitch <= Pawn.MAX_PITCH + 0.001 and ic.pitch >= -Pawn.MAX_PITCH - 0.001, "pitch clamped")
	assert_almost_eq(absf(ic.pitch), Pawn.MAX_PITCH, 0.001, "saturates at MAX_PITCH")

func test_invert_y_flips_pitch_direction() -> void:
	var s := ClientSettings.new()
	var up := _ic(); up.apply_look(Vector2(0, -50), s)
	s.invert_y = true
	var inv := _ic(); inv.apply_look(Vector2(0, -50), s)
	assert_true(signf(up.pitch) != signf(inv.pitch), "invert_y flips pitch sign")
