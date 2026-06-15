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

func test_finishing_body_fire_accelerates_bleed() -> void:
	var p := Pawn.new(1); p.is_downed = true; p.alive = true; p.bleed_health = -40
	_apply(p, 20, false, Revive.Source.BULLET)  # -40 - 20 = -60 < floor
	assert_false(p.alive, "enough body fire finishes a downed pawn")
