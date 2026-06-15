extends TestCase

# Mirrors server _apply_pawn_damage for a victim, isolated to Pawn + Revive
# so the down-vs-dead decision is unit-tested without the full server harness.
func _apply(victim: Pawn, dmg: int, headshot: bool, source: int) -> void:
	if victim.is_downed:
		if Revive.is_instant_kill(headshot, source):
			victim.alive = false; victim.is_downed = false
		else:
			victim.bleed_health -= dmg
			if Revive.is_bled_out(victim.bleed_health):
				victim.alive = false; victim.is_downed = false
		return
	victim.health -= dmg
	if victim.health > 0:
		return
	victim.health = 0
	if Revive.is_instant_kill(headshot, source):
		victim.alive = false
	else:
		victim.is_downed = true
		victim.bleed_health = 0
		victim.bleed_halted = false

func test_body_shot_to_zero_downs_not_kills() -> void:
	var p := Pawn.new(1); p.health = 10
	_apply(p, 40, false, Revive.Source.BULLET)
	assert_true(p.is_downed, "body lethal hit downs")
	assert_true(p.alive, "downed pawn is still alive")

func test_headshot_to_zero_kills_outright() -> void:
	var p := Pawn.new(1); p.health = 10
	_apply(p, 40, true, Revive.Source.BULLET)
	assert_false(p.alive, "headshot bypasses DBNO")
	assert_false(p.is_downed)

func test_blast_to_zero_kills_outright() -> void:
	var p := Pawn.new(1); p.health = 10
	_apply(p, 40, false, Revive.Source.BLAST)
	assert_false(p.alive)

func test_finishing_headshot_on_downed_kills() -> void:
	var p := Pawn.new(1); p.is_downed = true; p.alive = true; p.bleed_health = 0
	_apply(p, 10, true, Revive.Source.BULLET)
	assert_false(p.alive, "headshot finishes a downed pawn")
	assert_false(p.is_downed, "killed pawn clears is_downed")

func test_finishing_body_fire_accelerates_bleed() -> void:
	var p := Pawn.new(1); p.is_downed = true; p.alive = true
	p.bleed_health = Revive.BLEEDOUT_FLOOR + 5
	_apply(p, 10, false, Revive.Source.BULLET)  # +5 - 10 pushes past the floor
	assert_false(p.alive, "enough body fire finishes a downed pawn")
	assert_false(p.is_downed, "killed pawn clears is_downed")

func test_non_lethal_body_shot_leaves_pawn_standing() -> void:
	var p := Pawn.new(1); p.health = 100
	_apply(p, 30, false, Revive.Source.BULLET)
	assert_true(p.alive)
	assert_false(p.is_downed)
	assert_eq(p.health, 70)

func test_downed_bleeds_out_after_enough_ticks() -> void:
	var bh := 0
	var ticks := 0
	while not Revive.is_bled_out(bh):
		bh = Revive.bleed_step(bh, false)
		ticks += 1
		assert_true(ticks < 1000, "must terminate")
	# 50 HP / 2 per tick = 25 ticks to floor
	assert_eq(ticks, -Revive.BLEEDOUT_FLOOR / Revive.BLEED_RATE)

func test_halted_pawn_never_bleeds_out() -> void:
	var bh := -10
	for _i in 100:
		bh = Revive.bleed_step(bh, true)
	assert_false(Revive.is_bled_out(bh), "self-bandaged pawn holds")

func test_revive_threshold_non_medic_is_revive_ticks() -> void:
	assert_eq(Revive.revive_ticks(false), Revive.REVIVE_TICKS)

func test_medic_revive_threshold_is_half() -> void:
	assert_eq(Revive.revive_ticks(true) * 2, Revive.revive_ticks(false))

# Mirrors server _step_revives accumulation + _complete_revive restore for one
# in-range teammate reviver, isolated to Pawn + Revive (server node isn't headless-instantiable).
func _drive_revive(reviver: Pawn, target: Pawn, is_medic: bool, ticks: int) -> void:
	var acc := 0
	for _i in ticks:
		# validity gate (mirror of _step_revives)
		if not reviver.alive or reviver.is_downed: continue
		if not target.is_downed: continue
		if reviver.team != target.team: continue
		if reviver.pos.distance_to(target.pos) > Revive.REVIVE_RANGE: continue
		acc += 1
		if acc >= Revive.revive_ticks(is_medic):
			# _complete_revive restore
			target.is_downed = false
			target.health = Revive.REVIVE_HP
			target.bleed_health = 0
			target.bleed_halted = false
			return

func test_revive_completes_and_restores_after_threshold() -> void:
	var medic := Pawn.new(1); medic.team = 0; medic.alive = true; medic.pos = Vector3.ZERO
	var downed := Pawn.new(2); downed.team = 0; downed.is_downed = true; downed.health = 0
	downed.bleed_health = -20; downed.pos = Vector3(1.0, 0.0, 0.0)  # within REVIVE_RANGE=2.0
	_drive_revive(medic, downed, false, Revive.REVIVE_TICKS)
	assert_false(downed.is_downed, "completes after full hold")
	assert_eq(downed.health, Revive.REVIVE_HP)
	assert_eq(downed.bleed_health, 0)

func test_revive_blocked_when_not_teammate() -> void:
	var enemy := Pawn.new(1); enemy.team = 1; enemy.alive = true; enemy.pos = Vector3.ZERO
	var downed := Pawn.new(2); downed.team = 0; downed.is_downed = true
	downed.pos = Vector3(1.0, 0.0, 0.0)
	_drive_revive(enemy, downed, false, Revive.REVIVE_TICKS * 2)
	assert_true(downed.is_downed, "enemy cannot revive — stays downed")

func test_revive_blocked_when_out_of_range() -> void:
	var medic := Pawn.new(1); medic.team = 0; medic.alive = true; medic.pos = Vector3.ZERO
	var downed := Pawn.new(2); downed.team = 0; downed.is_downed = true
	downed.pos = Vector3(0.0, 0.0, Revive.REVIVE_RANGE + 1.0)  # out of range
	_drive_revive(medic, downed, false, Revive.REVIVE_TICKS * 2)
	assert_true(downed.is_downed, "out-of-range reviver makes no progress")
