extends TestCase
## M19 P2b: Combat Stim buff — server sets stim_until_tick; caller derives cmd.stimmed;
## pawn.step() applies a pure speed + stamina-regen boost from that flag.

func _cmd(mx := 0.0, my := 0.0, stimmed := false) -> Dictionary:
	return {"move_x": mx, "move_y": my, "yaw": 0.0, "pitch": 0.0, "buttons": 0, "stimmed": stimmed}

func _fwd_speed(stimmed: bool) -> float:
	var p := Pawn.new(1)
	p.step(0.1, _cmd(0.0, 1.0, stimmed))
	return Vector2(p.velocity.x, p.velocity.z).length()

func _regen_gain(stimmed: bool) -> float:
	var p := Pawn.new(1)
	p.stamina = 10.0
	var dt := 1.0 / 30.0
	# clear the post-drain regen delay deterministically with idle ticks (no sprint/jump == cooldown only ticks down)
	for _i in 60:
		p.step(dt, _cmd(0.0, 0.0, false))
	var before := p.stamina
	p.step(dt, _cmd(0.0, 0.0, stimmed))
	return p.stamina - before

func test_stim_flag_increases_move_speed() -> void:
	var base := _fwd_speed(false)
	var boosted := _fwd_speed(true)
	assert_true(boosted > base * 1.05, "stimmed pawn moves faster (got %f vs %f)" % [boosted, base])

func test_no_stim_flag_is_baseline_speed() -> void:
	assert_true(abs(_fwd_speed(false) - _fwd_speed(false)) < 0.001, "deterministic")

func test_stim_flag_boosts_stamina_regen() -> void:
	assert_true(_regen_gain(true) > _regen_gain(false), "stimmed regen faster")

func test_stim_until_tick_defaults_zero() -> void:
	assert_eq(Pawn.new(1).stim_until_tick, 0)
