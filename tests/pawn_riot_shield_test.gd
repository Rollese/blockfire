extends TestCase
## M19 P5 Task 3: riot shield movement/fire-lockout cost — server sets cmd.shielded (mirrors
## the stimmed flag pattern); pawn.step() applies a pure speed penalty + sprint suppression from
## that flag. Shield HP/damage logic is Task 4 and is NOT covered here.

func _cmd(mx := 0.0, my := 0.0, shielded := false, buttons := 0) -> Dictionary:
	return {"move_x": mx, "move_y": my, "yaw": 0.0, "pitch": 0.0, "buttons": buttons, "shielded": shielded}

func _fwd_speed(shielded: bool, buttons := 0) -> float:
	var p := Pawn.new(1)
	p.step(0.1, _cmd(0.0, 1.0, shielded, buttons))
	return Vector2(p.velocity.x, p.velocity.z).length()

func test_shielded_flag_decreases_move_speed() -> void:
	var base := _fwd_speed(false)
	var shielded := _fwd_speed(true)
	assert_true(base > 0.0, "baseline forward speed is a real nonzero value")
	assert_true(shielded < base, "shielded pawn moves slower than unshielded (got %f vs %f)" % [shielded, base])
	assert_true(abs((shielded / base) - RiotShield.SHIELD_SPEED_MULT) < 0.01,
		"shielded speed scales down by exactly SHIELD_SPEED_MULT (got ratio %f)" % (shielded / base))

func test_shielded_flag_suppresses_sprint_bonus() -> void:
	var walk := _fwd_speed(true, 0)
	var sprint := _fwd_speed(true, InputCommand.BTN_SPRINT)
	assert_eq(walk, sprint, "sprint gives no extra distance while shielded")

func test_unshielded_sprint_still_works() -> void:
	var walk := _fwd_speed(false, 0)
	var sprint := _fwd_speed(false, InputCommand.BTN_SPRINT)
	assert_true(sprint > walk, "sprint still boosts speed when not shielded")

func test_fire_suppressed_by_shield_true_when_shielded_and_firing() -> void:
	assert_true(Pawn.fire_suppressed_by_shield(InputCommand.BTN_FIRE, true),
		"firing is suppressed while the shield is up")

func test_fire_suppressed_by_shield_false_when_not_shielded() -> void:
	assert_false(Pawn.fire_suppressed_by_shield(InputCommand.BTN_FIRE, false),
		"firing is not suppressed when the shield is down")

func test_fire_suppressed_by_shield_false_when_not_firing() -> void:
	assert_false(Pawn.fire_suppressed_by_shield(0, true),
		"no fire button held means nothing to suppress, even shielded")
