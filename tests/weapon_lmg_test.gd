extends TestCase

func test_lmg_enum_and_def_exist() -> void:
	assert_eq(Weapon.LMG, 5, "LMG is the next weapon id after PISTOL")
	var d := Weapon.get_def(Weapon.LMG)
	assert_eq(String(d["name"]), "LMG")

func test_lmg_has_large_mag() -> void:
	assert_gt(int(Weapon.get_def(Weapon.LMG)["mag_size"]), 90, "LMG mag is very large")

func test_lmg_is_full_auto_only() -> void:
	assert_true(Weapon.mode_allowed(Weapon.LMG, Weapon.MODE_AUTO))
	assert_false(Weapon.mode_allowed(Weapon.LMG, Weapon.MODE_SEMI), "LMG is auto-only")

func test_lmg_suppresses_harder_than_ar() -> void:
	assert_gt(Weapon.suppression_mult(Weapon.LMG), Weapon.suppression_mult(Weapon.AR),
		"LMG suppression multiplier exceeds the AR baseline")

func test_default_weapon_suppression_is_one() -> void:
	assert_almost_eq(Weapon.suppression_mult(Weapon.AR), 1.0)
	assert_almost_eq(Weapon.suppression_mult(Weapon.SMG), 1.0)
