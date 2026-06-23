extends TestCase

func _cmd(mx := 0.0, my := 0.0, yaw := 0.0, pitch := 0.0, buttons := 0) -> Dictionary:
	return {"move_x": mx, "move_y": my, "yaw": yaw, "pitch": pitch, "buttons": buttons}

func test_walks_at_stand_speed() -> void:
	var p := Pawn.new(1)
	p.step(1.0, _cmd(1.0, 0.0))
	assert_almost_eq(p.pos.x, Stance.speed(Stance.STAND), 0.001)
	assert_almost_eq(p.pos.y, 0.0, 0.001, "stays grounded")

func test_step_clamps_to_supplied_world_half() -> void:
	# Small-map regression: pawns must stay inside the map's world_half, not the 1000 m default.
	var p := Pawn.new(1)
	for _i in 600:   # walk +x for ~10 s — well past a 60 m arena edge
		p.step(0.0166667, _cmd(1.0, 0.0), 60.0)
	assert_true(p.pos.x <= 60.0 + 0.001, "x clamped to world_half=60 (was %f)" % p.pos.x)
	# and the downed crawl path clamps too
	var d := Pawn.new(2)
	d.is_downed = true
	for _i in 600:
		d.step(0.0166667, _cmd(1.0, 0.0), 60.0)
	assert_true(d.pos.x <= 60.0 + 0.001, "downed crawl also clamps to world_half")

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

func test_to_state_copies_team_and_squad() -> void:
	var p := Pawn.new(1)
	p.team = 1; p.squad = 3
	var e := p.to_state()
	assert_eq(e.team, 1)
	assert_eq(e.squad, 3)

func test_downed_pawn_crawls_at_crawl_speed() -> void:
	var p := Pawn.new(1)
	p.is_downed = true
	p.step(1.0, _cmd(1.0, 0.0))
	assert_almost_eq(p.pos.x, Revive.DOWNED_CRAWL_SPEED, 0.001, "downed moves at crawl speed")

func test_downed_pawn_cannot_sprint() -> void:
	var p := Pawn.new(1)
	p.is_downed = true
	p.step(1.0, _cmd(1.0, 0.0, 0.0, 0.0, InputCommand.BTN_SPRINT))
	assert_almost_eq(p.pos.x, Revive.DOWNED_CRAWL_SPEED, 0.001, "no sprint while downed")

func test_downed_pawn_cannot_jump() -> void:
	var p := Pawn.new(1)
	p.is_downed = true
	p.step(0.1, _cmd(0, 0, 0, 0, InputCommand.BTN_JUMP))
	assert_almost_eq(p.pos.y, 0.0, 0.05, "downed cannot jump off the ground")

func test_default_bandage_count() -> void:
	var p := Pawn.new(1)
	assert_eq(p.bandage_count, Revive.BANDAGE_COUNT)

func test_to_state_copies_downed() -> void:
	var p := Pawn.new(1)
	p.is_downed = true
	assert_true(p.to_state().is_downed)

func test_step_skips_normal_movement_while_climbing() -> void:
	var p := Pawn.new(1)
	p.pos = Vector3(5, 2, 5)
	p.climbing = true
	p.step(1.0 / 30.0, {"move_x": 1.0, "move_y": 1.0, "yaw": 0.7})
	assert_eq(p.pos, Vector3(5, 2, 5), "climbing: SimLoop owns position, step() must not move the pawn")
	assert_almost_eq(p.yaw, 0.7, 0.001, "look still applies while climbing")

func test_step_skips_normal_movement_while_vaulting() -> void:
	var p := Pawn.new(1)
	p.pos = Vector3(0, 0, 0)
	p.vaulting = true
	p.step(1.0 / 30.0, {"move_x": 1.0, "move_y": 1.0})
	assert_eq(p.pos, Vector3(0, 0, 0), "vaulting: SimLoop owns position")

func test_climb_vault_fields_default() -> void:
	var p := Pawn.new(1)
	assert_false(p.climbing)
	assert_false(p.vaulting)
	assert_eq(p.last_stance_change_tick, -1000)

func test_armor_class_defaults_light() -> void:
	assert_eq(Pawn.new(1).armor_class, Armor.LIGHT)
	assert_almost_eq(Pawn.new(1).suppression, 0.0)

func test_heavy_armor_moves_slower_than_light() -> void:
	var light := Pawn.new(1); light.armor_class = Armor.LIGHT
	var heavy := Pawn.new(2); heavy.armor_class = Armor.HEAVY
	light.step(1.0, _cmd(1.0, 0.0))
	heavy.step(1.0, _cmd(1.0, 0.0))
	assert_true(absf(heavy.pos.x) < absf(light.pos.x), "heavy armor reduces move speed")
	assert_almost_eq(light.pos.x, Stance.speed(Stance.STAND), 0.001, "light armor = unmodified stance speed")
