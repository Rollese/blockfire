extends TestCase

func test_ammo_from_weapon_predictor() -> void:
	var wp := WeaponPredictor.new(); wp.set_weapon(Weapon.AR); wp.mag = 7
	var m := HudModel.new()
	var out := m.build({"weapon_predictor": wp, "tick": 0})
	assert_eq(out["ammo"]["mag"], 7)
	assert_false(out["ammo"]["reloading"])
	assert_true(out["ammo"]["low"], "7 of 30 is low ammo")
