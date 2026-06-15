extends TestCase

func test_headshot_is_instant_kill() -> void:
	assert_true(Revive.is_instant_kill(true, Revive.Source.BULLET), "headshot bypasses DBNO")

func test_blast_is_instant_kill() -> void:
	assert_true(Revive.is_instant_kill(false, Revive.Source.BLAST), "explosives bypass DBNO")

func test_body_bullet_is_not_instant_kill() -> void:
	assert_false(Revive.is_instant_kill(false, Revive.Source.BULLET), "body gunfire downs, not kills")

func test_bleed_step_drains_when_not_halted() -> void:
	assert_eq(Revive.bleed_step(0, false), -Revive.BLEED_RATE)

func test_bleed_step_holds_when_halted() -> void:
	assert_eq(Revive.bleed_step(-10, true), -10, "self-bandaged pawn stops draining")

func test_bleed_step_floors_at_bleedout() -> void:
	assert_eq(Revive.bleed_step(Revive.BLEEDOUT_FLOOR + 1, false), Revive.BLEEDOUT_FLOOR)

func test_is_bled_out_at_floor() -> void:
	assert_true(Revive.is_bled_out(Revive.BLEEDOUT_FLOOR))
	assert_false(Revive.is_bled_out(Revive.BLEEDOUT_FLOOR + 1))

func test_medic_revives_at_double_speed() -> void:
	assert_eq(Revive.revive_ticks(true), Revive.REVIVE_TICKS / 2)
	assert_eq(Revive.revive_ticks(false), Revive.REVIVE_TICKS)

func test_medic_carries_extra_bandages() -> void:
	assert_eq(Revive.bandage_count_for(true), Revive.BANDAGE_COUNT + Revive.MEDIC_EXTRA_BANDAGES)
	assert_eq(Revive.bandage_count_for(false), Revive.BANDAGE_COUNT)
