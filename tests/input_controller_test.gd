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

func test_move_basis_matches_aim_convention() -> void:
	# Combat._forward defines forward(yaw)=(sin,cos), right(yaw)=(cos,-sin) on XZ; the user's
	# aim follows it. Pressing W (local_z=+1) must move along forward, D (local_x=+1) along right.
	var hpi := PI / 2.0
	# yaw=0: W -> +Z forward (both conventions agree here; sanity anchor)
	var f0 := InputController.move_world(0.0, 1.0, 0.0)
	assert_almost_eq(f0.x, 0.0, 0.001, "W at yaw=0 has no X component")
	assert_almost_eq(f0.y, 1.0, 0.001, "W at yaw=0 moves +Z forward")
	# yaw=90deg faces +X: W must move toward +X (where you aim), not -X
	var fwd := InputController.move_world(0.0, 1.0, hpi)
	assert_almost_eq(fwd.x, 1.0, 0.001, "W at yaw=90 moves toward +X (aim direction)")
	assert_almost_eq(fwd.y, 0.0, 0.001, "W at yaw=90 has no Z component")
	# yaw=90deg: D (right) must strafe toward -Z = right(90deg)=(0,-1)
	var rgt := InputController.move_world(1.0, 0.0, hpi)
	assert_almost_eq(rgt.x, 0.0, 0.001, "D at yaw=90 has no X component")
	assert_almost_eq(rgt.y, -1.0, 0.001, "D at yaw=90 strafes toward -Z")
	# yaw=180deg faces -Z: W -> -Z. yaw=-90deg faces -X: W -> -X. (A +yaw sign error vanishes at
	# yaw=90 but not here, so these pin the handedness independently.)
	var f180 := InputController.move_world(0.0, 1.0, PI)
	assert_almost_eq(f180.x, 0.0, 0.001, "W at yaw=180 has no X component")
	assert_almost_eq(f180.y, -1.0, 0.001, "W at yaw=180 moves -Z")
	var fneg := InputController.move_world(0.0, 1.0, -hpi)
	assert_almost_eq(fneg.x, -1.0, 0.001, "W at yaw=-90 moves toward -X")
	assert_almost_eq(fneg.y, 0.0, 0.001, "W at yaw=-90 has no Z component")

func test_invert_y_flips_pitch_direction() -> void:
	var s := ClientSettings.new()
	var up := _ic(); up.apply_look(Vector2(0, -50), s)
	s.invert_y = true
	var inv := _ic(); inv.apply_look(Vector2(0, -50), s)
	assert_true(signf(up.pitch) != signf(inv.pitch), "invert_y flips pitch sign")
