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
