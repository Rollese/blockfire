extends TestCase

func test_weapons_exist_with_sane_stats() -> void:
	for wid in [Weapon.AR, Weapon.SMG, Weapon.DMR]:
		var w := Weapon.get_def(wid)
		assert_true(w["damage_body"] > 0)
		assert_true(w["headshot_mult"] >= 1.0)
		assert_true(w["mag_size"] > 0)
		assert_true(w["rpm"] > 0)

func test_fire_interval_from_rpm() -> void:
	assert_almost_eq(Weapon.fire_interval(Weapon.AR), 0.1, 0.001)

func test_hitscan_weapons_carry_a_finite_reserve() -> void:
	# Reserve-ammo economy: every hit-scan weapon has a spare-bullet pool separate from the loaded
	# mag, sized as a few spare mags (BattleBit-default). RPG is gadget-managed, out of scope.
	for wid in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.PISTOL]:
		var w := Weapon.get_def(wid)
		assert_true(w.has("reserve_ammo"), "weapon %d defines reserve_ammo" % wid)
		var reserve: int = int(w["reserve_ammo"])
		var mag: int = int(w["mag_size"])
		assert_true(reserve >= mag * 3, "reserve is at least a few spare mags (w %d)" % wid)
		assert_true(reserve <= mag * 10, "reserve is not absurdly large (w %d)" % wid)

func test_reserve_ammo_helper_returns_pool() -> void:
	assert_eq(Weapon.reserve_ammo(Weapon.AR), int(Weapon.get_def(Weapon.AR)["reserve_ammo"]))
	# Unknown weapon falls back to the AR default like get_def.
	assert_eq(Weapon.reserve_ammo(9999), int(Weapon.get_def(Weapon.AR)["reserve_ammo"]))

func test_reload_fill_moves_missing_rounds_no_discard() -> void:
	# 30-round mag with 20 loaded, 100 in reserve: top to 30, reserve drops by exactly the 10 loaded.
	var r := Weapon.reload_fill(20, 30, 100)
	assert_eq(int(r[0]), 30, "mag topped to full")
	assert_eq(int(r[1]), 90, "reserve drops by the 10 rounds loaded, no partial-mag discard")

func test_reload_fill_limited_by_reserve() -> void:
	var r := Weapon.reload_fill(0, 30, 7)
	assert_eq(int(r[0]), 7, "only what's in reserve loads")
	assert_eq(int(r[1]), 0, "reserve emptied")

func test_reload_fill_unlimited_reserve_sentinel() -> void:
	# reserve < 0 = legacy "unlimited": mag tops to full, reserve untouched.
	var r := Weapon.reload_fill(5, 30, -1)
	assert_eq(int(r[0]), 30)
	assert_eq(int(r[1]), -1)

func test_effective_def_applies_multipliers() -> void:
	var base := Weapon.get_def(Weapon.AR)
	var m := {"spread_mult": 0.5, "recoil_mult": 0.5, "range_mult": 0.5,
		"move_spread_mult": 0.5, "prone_spread_zero": true}
	var eff := Weapon.effective_def(Weapon.AR, m)
	assert_almost_eq(eff["spread_base_deg"], base["spread_base_deg"] * 0.5, 0.001)
	assert_almost_eq(eff["recoil_pitch_deg"], base["recoil_pitch_deg"] * 0.5, 0.001)
	assert_almost_eq(eff["range_m"], base["range_m"] * 0.5, 0.001)
	assert_almost_eq(eff["move_spread_mult"], 0.5, 0.001)
	assert_true(eff["prone_spread_zero"])

func test_effective_def_neutral_matches_base_stats() -> void:
	var base := Weapon.get_def(Weapon.SMG)
	var eff := Weapon.effective_def(Weapon.SMG, {"spread_mult": 1.0, "recoil_mult": 1.0, "range_mult": 1.0, "move_spread_mult": 1.0, "prone_spread_zero": false})
	assert_eq(eff["damage_body"], base["damage_body"])
	assert_almost_eq(eff["spread_base_deg"], base["spread_base_deg"], 0.001)

func test_rpg_is_a_weapon_id() -> void:
	assert_true(Weapon.RPG != Weapon.AR and Weapon.RPG != Weapon.SMG and Weapon.RPG != Weapon.DMR)

func test_ballistics_fields_present() -> void:
	var d := Weapon.get_def(Weapon.AR)
	assert_true(d.has("muzzle_velocity") and float(d["muzzle_velocity"]) > 0.0)
	assert_true(d.has("gravity_scale") and float(d["gravity_scale"]) > 0.0)
	assert_true(int(Weapon.projectile_ttl_ticks(Weapon.AR)) > 0)

func test_pistol_exists_and_is_weaker_faster() -> void:
	var p := Weapon.get_def(Weapon.PISTOL)
	assert_eq(p["name"], "PISTOL")
	assert_true(int(p["damage_body"]) < int(Weapon.get_def(Weapon.AR)["damage_body"]))

func test_fire_allowed_semi() -> void:
	assert_true(Weapon.fire_allowed(Weapon.MODE_SEMI, 0, 3))
	assert_false(Weapon.fire_allowed(Weapon.MODE_SEMI, 1, 3))

func test_fire_allowed_burst() -> void:
	assert_true(Weapon.fire_allowed(Weapon.MODE_BURST, 0, 3))
	assert_true(Weapon.fire_allowed(Weapon.MODE_BURST, 2, 3))
	assert_false(Weapon.fire_allowed(Weapon.MODE_BURST, 3, 3))

func test_fire_allowed_auto() -> void:
	assert_true(Weapon.fire_allowed(Weapon.MODE_AUTO, 99, 3))

func test_default_mode_is_first_available() -> void:
	assert_eq(Weapon.default_mode(Weapon.AR), Weapon.MODE_AUTO)
	assert_eq(Weapon.default_mode(Weapon.DMR), Weapon.MODE_SEMI)

func test_mode_allowed_rejects_unlisted() -> void:
	assert_false(Weapon.mode_allowed(Weapon.DMR, Weapon.MODE_AUTO))
	assert_true(Weapon.mode_allowed(Weapon.AR, Weapon.MODE_SEMI))

func test_archetype_name_nonempty_for_every_enum() -> void:
	# Loadout-UI category headers read this — every archetype must yield a non-empty label.
	for arch in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.RPG, Weapon.PISTOL, Weapon.LMG]:
		assert_true(Weapon.archetype_name(arch).length() > 0, "archetype %d has a name" % arch)
	assert_eq(Weapon.archetype_name(Weapon.AR), "Assault Rifles")

func test_spawn_mags_builds_full_spare_mags() -> void:
	# Reserve divides evenly into whole spare mags; each starts full. Loaded mag is tracked separately.
	for wid in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.PISTOL, Weapon.LMG]:
		var ms := int(Weapon.get_def(wid)["mag_size"])
		var expected_n := Weapon.reserve_ammo(wid) / ms
		var mags := Weapon.spawn_mags(wid)
		assert_eq(mags.size(), expected_n, "spare mag count for w %d" % wid)
		for m in mags:
			assert_eq(int(m), ms, "each spare mag full for w %d" % wid)

func test_spawn_mags_scales_with_reserve_mult() -> void:
	var ms := int(Weapon.get_def(Weapon.AR)["mag_size"])
	var base := Weapon.spawn_mags(Weapon.AR, 1.0).size()
	var boosted := Weapon.spawn_mags(Weapon.AR, 1.5).size()
	assert_eq(boosted, int(round(Weapon.reserve_ammo(Weapon.AR) * 1.5)) / ms)
	assert_true(boosted > base)

func test_has_loadable_spare() -> void:
	assert_false(Weapon.has_loadable_spare([]))
	assert_false(Weapon.has_loadable_spare([0, 0]))
	assert_true(Weapon.has_loadable_spare([0, 5]))

func test_reload_swap_is_fifo_and_returns_partial_to_tail() -> void:
	# Loaded mag has 8 left; spares [30, 30]. Tap reload: 8 goes to tail, load head 30.
	var res := Weapon.reload_swap(8, [30, 30])
	assert_eq(int(res[0]), 30)          # new loaded mag
	assert_eq(res[1], [30, 8])          # partial returned to the tail
	assert_true(bool(res[2]))           # ok

func test_reload_swap_skips_empty_mags() -> void:
	# Never chamber an empty: leading 0-mags are discarded until a non-empty head is found.
	var res := Weapon.reload_swap(5, [0, 0, 20])
	assert_eq(int(res[0]), 20)
	assert_eq(res[1], [5])              # the two empties discarded; partial 5 kept at tail
	assert_true(bool(res[2]))

func test_load_next_loads_head_without_returning_current() -> void:
	# Fast reload: current mag was dropped by the caller, so no partial returns to the tail.
	var res := Weapon.load_next([30, 12])
	assert_eq(int(res[0]), 30)
	assert_eq(res[1], [12])
	assert_true(bool(res[2]))

func test_load_next_reports_not_ok_when_no_spare() -> void:
	var res := Weapon.load_next([0, 0])
	assert_false(bool(res[2]))

func test_redistribute_step_pours_emptiest_into_fullest() -> void:
	# mag_size 30. Emptiest non-empty (5) pours into fullest non-full (20) -> [25], 5-mag emptied+dropped.
	var out := Weapon.redistribute_step([20, 5], 30)
	assert_eq(out, [25])

func test_redistribute_step_leaves_partial_when_dest_fills() -> void:
	# Emptiest (20) pours into fullest-non-full (25, space 5): 25->30, 20->15 (kept in place, not dropped).
	var out := Weapon.redistribute_step([20, 25], 30)
	assert_eq(out, [15, 30])

func test_redistribute_step_noop_when_nothing_to_consolidate() -> void:
	assert_eq(Weapon.redistribute_step([30, 30], 30), [30, 30])
	assert_eq(Weapon.redistribute_step([7], 30), [7])

func test_resupply_step_tops_loaded_then_fills_emptiest_first() -> void:
	# One mag (30) of rounds: top loaded 10->30 (20 used), remaining 10 into emptiest spare (0->10).
	var res := Weapon.resupply_step(10, [0, 30], Weapon.AR)
	assert_eq(int(res[0]), 30)
	assert_eq(res[1], [10, 30])

func test_resupply_step_caps_at_max_mag_count() -> void:
	# Full loaded + full spares already at max: adding rounds cannot exceed the spawn count.
	var full := Weapon.spawn_mags(Weapon.AR)
	var res := Weapon.resupply_step(30, full, Weapon.AR)
	assert_eq(int(res[0]), 30)
	assert_eq(res[1].size(), full.size())
