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
