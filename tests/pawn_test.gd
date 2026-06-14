extends TestCase

func _cmd(mx := 0.0, my := 0.0, yaw := 0.0, pitch := 0.0, buttons := 0) -> Dictionary:
	return {"move_x": mx, "move_y": my, "yaw": yaw, "pitch": pitch, "buttons": buttons}

func test_walks_at_stand_speed() -> void:
	var p := Pawn.new(1)
	p.step(1.0, _cmd(1.0, 0.0))
	assert_almost_eq(p.pos.x, Stance.speed(Stance.STAND), 0.001)
	assert_almost_eq(p.pos.y, 0.0, 0.001, "stays grounded")

func test_crouch_is_slower() -> void:
	var p := Pawn.new(1)
	p.step(1.0, _cmd(1.0, 0.0, 0.0, 0.0, InputCommand.BTN_CROUCH))
	assert_eq(p.stance, Stance.CROUCH)
	assert_almost_eq(p.pos.x, Stance.speed(Stance.CROUCH), 0.001)

func test_jump_rises_then_gravity_returns_to_ground() -> void:
	var p := Pawn.new(1)
	p.step(0.1, _cmd(0, 0, 0, 0, InputCommand.BTN_JUMP))
	assert_true(p.pos.y > 0.0, "leaves ground after jump")
	for i in 60:
		p.step(1.0 / 30.0, _cmd())
	assert_almost_eq(p.pos.y, 0.0, 0.001, "gravity returns to ground")
	assert_true(p.grounded)

func test_sprint_drains_stamina_and_is_faster() -> void:
	var p := Pawn.new(1)
	p.step(1.0, _cmd(1.0, 0.0, 0.0, 0.0, InputCommand.BTN_SPRINT))
	assert_almost_eq(p.pos.x, Stance.speed(Stance.STAND) * Pawn.SPRINT_MULT, 0.01)
	assert_true(p.stamina < Pawn.STAMINA_MAX, "sprint drained stamina")

func test_pitch_clamped() -> void:
	var p := Pawn.new(1)
	p.step(0.1, _cmd(0, 0, 0, 10.0))  # absurd pitch
	assert_true(absf(p.pitch) <= Pawn.MAX_PITCH + 0.001)
