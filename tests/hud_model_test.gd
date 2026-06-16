extends TestCase

func test_ammo_from_weapon_predictor() -> void:
	var wp := WeaponPredictor.new(); wp.set_weapon(Weapon.AR); wp.mag = 7
	var m := HudModel.new()
	var out := m.build({"weapon_predictor": wp, "tick": 0})
	assert_eq(out["ammo"]["mag"], 7)
	assert_false(out["ammo"]["reloading"])
	assert_true(out["ammo"]["low"], "7 of 30 is low ammo")

func test_compass_relative_bearing_to_objective() -> void:
	var m := HudModel.new()
	# local at origin facing +Z (yaw 0); objective due +X (right) -> +90 deg relative.
	var out := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0,
		"objectives": [{"pos": Vector3(10, 0, 0), "owner": -1}], "tick": 0})
	assert_almost_eq(rad_to_deg(out["compass"]["heading"]), 0.0, 0.5)
	assert_almost_eq(rad_to_deg(out["compass"]["markers"][0]["rel_bearing"]), 90.0, 1.0)

func test_compass_bearing_wraps_behind() -> void:
	var m := HudModel.new()
	# objective due -Z (behind) -> +/-180 deg.
	var out := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0,
		"objectives": [{"pos": Vector3(0, 0, -10), "owner": -1}], "tick": 0})
	assert_almost_eq(absf(rad_to_deg(out["compass"]["markers"][0]["rel_bearing"])), 180.0, 1.0)
