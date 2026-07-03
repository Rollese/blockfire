extends TestCase

func test_headshot_is_instant_kill() -> void:
	assert_true(Revive.is_instant_kill(true, Revive.Source.BULLET), "headshot bypasses DBNO")

func test_blast_is_instant_kill() -> void:
	assert_true(Revive.is_instant_kill(false, Revive.Source.BLAST), "explosives bypass DBNO")

func test_body_bullet_is_not_instant_kill() -> void:
	assert_false(Revive.is_instant_kill(false, Revive.Source.BULLET), "body gunfire downs, not kills")

func test_bleed_step_drains_toward_floor() -> void:
	assert_eq(Revive.bleed_step(0, -240), -Revive.BLEED_RATE)

func test_bleed_step_floors_at_bleedout() -> void:
	assert_eq(Revive.bleed_step(-239, -240), -240)
	assert_eq(Revive.bleed_step(-240, -240), -240, "clamps at the floor, never overshoots")

func test_is_bled_out_at_floor() -> void:
	assert_true(Revive.is_bled_out(-240, -240))
	assert_false(Revive.is_bled_out(-239, -240))

func test_bleed_frac_full_at_down() -> void:
	assert_eq(Revive.bleed_frac_u8(0, -240), 255, "just-downed pawn shows full bleed fraction")

func test_bleed_frac_zero_at_floor() -> void:
	assert_eq(Revive.bleed_frac_u8(-240, -240), 0, "at the bleed-out floor the marker is empty")

func test_bleed_frac_half_at_midpoint() -> void:
	assert_almost_eq(Revive.bleed_frac_u8(-120, -240), 128, 2, "midway is ~half")

func test_bleed_frac_guards_nonneg_floor() -> void:
	assert_eq(Revive.bleed_frac_u8(0, 0), 0, "a zero-length window (skipped down) yields 0, not a div-by-zero")

# --- halving bleedout (2026-07-03) --------------------------------------------
func test_first_down_window_is_60s() -> void:
	assert_eq(Revive.bleedout_window(1), Revive.INITIAL_BLEEDOUT_TICKS)
	assert_eq(Revive.bleedout_window(0), Revive.INITIAL_BLEEDOUT_TICKS, "n<=1 treated as the first down")

func test_window_halves_each_down() -> void:
	assert_eq(Revive.bleedout_window(2), Revive.INITIAL_BLEEDOUT_TICKS >> 1)
	assert_eq(Revive.bleedout_window(3), Revive.INITIAL_BLEEDOUT_TICKS >> 2)
	assert_eq(Revive.bleedout_window(4), Revive.INITIAL_BLEEDOUT_TICKS >> 3)

func test_window_reaches_zero_eventually() -> void:
	var n := 1
	while Revive.bleedout_window(n) > 0:
		n += 1
		assert_true(n < 64, "the window must reach zero")
	assert_eq(Revive.bleedout_window(n), 0, "a zero window means the next down is skipped -> outright kill")

func test_revive_crossover() -> void:
	# 6th down: too short for a non-medic revive (3 s) but a medic (1.5 s) can still just save it.
	assert_true(Revive.bleedout_window(6) < Revive.REVIVE_TICKS, "6th down unsaveable by non-medic")
	assert_true(Revive.bleedout_window(6) >= Revive.revive_ticks(true), "6th down still saveable by a medic")
	# 7th down: below even a medic revive — effectively instant.
	assert_true(Revive.bleedout_window(7) < Revive.revive_ticks(true), "7th down unsaveable by anyone")

func test_bleedout_floor_is_negative_window() -> void:
	assert_eq(Revive.bleedout_floor(Revive.bleedout_window(1)), -Revive.INITIAL_BLEEDOUT_TICKS)
	assert_eq(Revive.bleedout_floor(Revive.bleedout_window(2)), -(Revive.INITIAL_BLEEDOUT_TICKS >> 1))

func test_medic_revives_at_double_speed() -> void:
	assert_eq(Revive.revive_ticks(true), Revive.REVIVE_TICKS / 2)
	assert_eq(Revive.revive_ticks(false), Revive.REVIVE_TICKS)

func test_medic_carries_extra_bandages() -> void:
	assert_eq(Revive.bandage_count_for(true), Revive.BANDAGE_COUNT + Revive.MEDIC_EXTRA_BANDAGES)
	assert_eq(Revive.bandage_count_for(false), Revive.BANDAGE_COUNT)

func test_fall_is_instant_kill_not_downed() -> void:
	assert_true(Revive.is_instant_kill(false, Revive.Source.FALL), "a lethal fall kills outright, not DBNO")
	assert_false(Revive.is_instant_kill(false, Revive.Source.BULLET), "bullets still down")
