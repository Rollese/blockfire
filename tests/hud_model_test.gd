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

func test_tickets_passthrough_and_capture_when_on_point() -> void:
	var m := HudModel.new()
	var ms := {"points": [{"owner": -1, "attacker": 0, "cap": 0.4}], "tickets": [120, 95]}
	var out := m.build({"match_state": ms, "self_pos": Vector3(5, 0, 5),
		"point_positions": [Vector3(6, 0, 6)], "capture_radius": 8.0, "tick": 0})
	assert_eq(out["tickets"], [120, 95])
	assert_almost_eq(out["capture"]["cap"], 0.4, 0.001, "on the point -> progress shown")

func test_no_capture_when_off_point() -> void:
	var m := HudModel.new()
	var ms := {"points": [{"owner": -1, "attacker": 0, "cap": 0.4}], "tickets": [120, 95]}
	var out := m.build({"match_state": ms, "self_pos": Vector3(500, 0, 500),
		"point_positions": [Vector3(6, 0, 6)], "capture_radius": 8.0, "tick": 0})
	assert_eq(out["capture"], null, "off point -> no capture readout")

func test_killfeed_entries_decay_out() -> void:
	var m := HudModel.new()
	m.push_kill({"killer": 1, "victim": 2, "headshot": true, "weapon": Weapon.AR}, 10.0)
	var out := m.build({"now": 10.5, "tick": 0})
	assert_eq(out["killfeed"].size(), 1, "fresh entry present")
	assert_true(out["killfeed"][0]["headshot"])
	var out2 := m.build({"now": 10.0 + HudModel.KILLFEED_TTL + 0.1, "tick": 0})
	assert_eq(out2["killfeed"].size(), 0, "expired entry dropped")
