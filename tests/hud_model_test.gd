extends TestCase

func test_ammo_from_weapon_predictor() -> void:
	var wp := WeaponPredictor.new(); wp.set_weapon(Weapon.AR); wp.mag = 7
	var m := HudModel.new()
	var out := m.build({"weapon_predictor": wp, "tick": 0})
	assert_eq(out["ammo"]["mag"], 7)
	assert_false(out["ammo"]["reloading"])
	assert_true(out["ammo"]["low"], "7 of 30 is low ammo")
	assert_eq(out["ammo"]["fire_mode"], Weapon.mode_name(wp.fire_mode), "ammo block surfaces the fire-mode glyph")
	wp.cycle_fire_mode()
	var out2 := m.build({"weapon_predictor": wp, "tick": 0})
	assert_eq(out2["ammo"]["fire_mode"], Weapon.mode_name(wp.fire_mode), "glyph tracks the cycled mode")

func test_compass_relative_bearing_to_objective() -> void:
	var m := HudModel.new()
	# yaw 0 -> the camera looks -Z (sim-yaw + PI); objective due +X is to the camera's right -> +90.
	var out := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0,
		"objectives": [{"pos": Vector3(10, 0, 0), "owner": -1}], "tick": 0})
	assert_almost_eq(absf(rad_to_deg(out["compass"]["heading"])), 180.0, 0.5)  # camera points -Z
	assert_almost_eq(rad_to_deg(out["compass"]["markers"][0]["rel_bearing"]), 90.0, 1.0)

func test_grenade_danger_none_when_no_grenades() -> void:
	var m := HudModel.new()
	var out := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0, "tick": 0})
	assert_true((out["grenade_danger"] as Dictionary).is_empty(), "no grenades -> no danger indicator")

func test_throw_charge_meter_visible_only_while_charging() -> void:
	var m := HudModel.new()
	var idle := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0, "tick": 0})
	assert_false(bool((idle["throw_charge"] as Dictionary).get("visible", true)), "no charge -> meter hidden")
	var mid := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0, "tick": 0, "throw_charge": 0.6})
	var tc: Dictionary = mid["throw_charge"]
	assert_true(bool(tc["visible"]), "charging -> meter shown")
	assert_almost_eq(float(tc["charge"]), 0.6, 0.001, "meter reflects the hold strength")

func test_stamina_bar_hidden_at_full_shown_when_spent() -> void:
	var m := HudModel.new()
	var full := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0, "tick": 0})   # no stamina_frac -> defaults full
	assert_false(bool((full["stamina"] as Dictionary).get("visible", true)), "full stamina -> bar hidden")
	var full2 := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0, "tick": 0, "stamina_frac": 1.0})
	assert_false(bool((full2["stamina"] as Dictionary)["visible"]), "exactly full -> bar hidden")
	var spent := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0, "tick": 0, "stamina_frac": 0.4})
	var st: Dictionary = spent["stamina"]
	assert_true(bool(st["visible"]), "spent stamina -> bar shown")
	assert_almost_eq(float(st["frac"]), 0.4, 0.001, "bar reflects the stamina fraction")

func test_grenade_danger_ignores_far_grenade() -> void:
	var m := HudModel.new()
	var out := m.build({"self_pos": Vector3.ZERO, "self_eye": Vector3.ZERO, "self_yaw": 0.0,
		"grenades": [Vector3(40, 0, 0)], "tick": 0})
	assert_true((out["grenade_danger"] as Dictionary).is_empty(), "a grenade beyond the radius isn't a danger")

func test_grenade_danger_points_at_nearby_grenade() -> void:
	var m := HudModel.new()
	# yaw 0 -> camera looks -Z; a grenade due +X is to the camera's right -> rel_bearing +90 (as compass).
	var out := m.build({"self_pos": Vector3.ZERO, "self_eye": Vector3.ZERO, "self_yaw": 0.0,
		"grenades": [Vector3(5, 0, 0)], "tick": 0})
	var dg: Dictionary = out["grenade_danger"]
	assert_false(dg.is_empty(), "a grenade within the radius raises the indicator")
	assert_almost_eq(rad_to_deg(dg["rel_bearing"]), 90.0, 1.0, "indicator points at the grenade")
	assert_true(dg["proximity"] > 0.0 and dg["proximity"] <= 1.0, "proximity is a 0..1 closeness")

func test_grenade_danger_picks_nearest() -> void:
	var m := HudModel.new()
	var out := m.build({"self_pos": Vector3.ZERO, "self_eye": Vector3.ZERO, "self_yaw": 0.0,
		"grenades": [Vector3(6, 0, 0), Vector3(2, 0, 0)], "tick": 0})
	var dg: Dictionary = out["grenade_danger"]
	# nearer grenade (2 m) -> higher proximity than the 6 m one would give.
	assert_true(dg["proximity"] > 0.5, "the nearest grenade drives the strongest warning")

func test_compass_bearing_wraps_behind() -> void:
	var m := HudModel.new()
	# yaw 0 -> camera looks -Z, so an objective at +Z is directly behind -> +/-180 deg.
	var out := m.build({"self_pos": Vector3.ZERO, "self_yaw": 0.0,
		"objectives": [{"pos": Vector3(0, 0, 10), "owner": -1}], "tick": 0})
	assert_almost_eq(absf(rad_to_deg(out["compass"]["markers"][0]["rel_bearing"])), 180.0, 1.0)

func test_match_status_band_and_capture_when_on_point() -> void:
	# Match-status band: viewer on team 0 with 120 vs enemy 95, timer at 1:23 -> WINNING.
	var m := HudModel.new()
	var ms := {"points": [{"owner": -1, "attacker": 0, "cap": 0.4}], "tickets": [120, 95], "elapsed": 83}
	var out := m.build({"match_state": ms, "self_team": 0, "self_pos": Vector3(5, 0, 5),
		"point_positions": [Vector3(6, 0, 6)], "point_radii": [8.0], "tick": 0})
	var st: Dictionary = out["tickets"]
	assert_eq(st["my_tickets"], 120, "team 0 -> t0 is mine")
	assert_eq(st["enemy_tickets"], 95)
	assert_eq(st["timer_str"], "01:23")
	assert_eq(st["status"], "WINNING")
	assert_almost_eq(out["capture"]["cap"], 0.4, 0.001, "on the point -> progress shown")

func test_match_status_viewer_relative_for_team1() -> void:
	# The team-1 viewer sees t1 (95) as "mine" and t0 (120) as enemy -> LOSING.
	var m := HudModel.new()
	var ms := {"tickets": [120, 95], "elapsed": 0}
	var out := m.build({"match_state": ms, "self_team": 1, "self_pos": Vector3(500, 0, 500),
		"point_positions": [], "point_radii": [], "tick": 0})
	var st: Dictionary = out["tickets"]
	assert_eq(st["my_tickets"], 95)
	assert_eq(st["enemy_tickets"], 120)
	assert_eq(st["status"], "LOSING")

func test_format_timer_and_ticket_status_pure() -> void:
	assert_eq(HudModel.format_timer(0), "00:00")
	assert_eq(HudModel.format_timer(9), "00:09")
	assert_eq(HudModel.format_timer(83), "01:23")
	assert_eq(HudModel.format_timer(600), "10:00")
	assert_eq(HudModel.format_timer(-5), "00:00", "negatives clamp to 0")
	assert_eq(HudModel.ticket_status(120, 95), "WINNING")
	assert_eq(HudModel.ticket_status(95, 120), "LOSING")
	assert_eq(HudModel.ticket_status(50, 50), "TIED")

func test_capture_uses_true_point_radius_not_a_constant() -> void:
	# Regression (2026-07-03): the widget must trigger at the point's real radius (== ground ring +
	# server), not a hardcoded 8 m. At 10 m from a 12 m point you ARE in the zone.
	var m := HudModel.new()
	var ms := {"points": [{"owner": 0, "attacker": -1, "cap": 0.0}], "tickets": [1, 1]}
	var out := m.build({"match_state": ms, "self_pos": Vector3(10, 0, 0),
		"point_positions": [Vector3(0, 0, 0)], "point_radii": [12.0], "tick": 0})
	assert_true(out["capture"] != null, "10 m from a 12 m point -> in the zone (was falsely out at r=8)")

func test_no_capture_when_off_point() -> void:
	var m := HudModel.new()
	var ms := {"points": [{"owner": -1, "attacker": 0, "cap": 0.4}], "tickets": [120, 95]}
	var out := m.build({"match_state": ms, "self_pos": Vector3(500, 0, 500),
		"point_positions": [Vector3(6, 0, 6)], "point_radii": [8.0], "tick": 0})
	assert_eq(out["capture"], null, "off point -> no capture readout")

func test_killfeed_resolves_names_and_friendliness() -> void:
	var m := HudModel.new()
	var roster := [{"id": 1, "name": "Alice", "team": 0, "squad": 0, "score": 0},
		{"id": 2, "name": "Bob", "team": 1, "squad": 0, "score": 0}]
	m.push_kill({"killer": 1, "victim": 2, "headshot": true, "weapon": Weapon.AR}, 10.0)
	var out := m.build({"now": 10.0, "tick": 0, "roster": roster, "self_id": 1})
	var e: Dictionary = out["killfeed"][0]
	assert_eq(e["killer_name"], "Alice", "killer id resolved to name")
	assert_eq(e["victim_name"], "Bob", "victim id resolved to name")
	assert_true(e["killer_friendly"], "killer is on the local team (self_id 1 -> team 0)")
	assert_false(e["victim_friendly"], "victim is the enemy team")
	assert_true(e["headshot"], "headshot flag carried through")

func test_killfeed_unknown_id_falls_back() -> void:
	var m := HudModel.new()
	m.push_kill({"killer": 99, "victim": 2, "headshot": false, "weapon": Weapon.AR}, 5.0)
	var out := m.build({"now": 5.0, "tick": 0, "roster": [], "self_id": 1})
	var e: Dictionary = out["killfeed"][0]
	assert_true(String(e["killer_name"]).contains("99"), "unknown id falls back to a #id label")
	assert_false(e["killer_friendly"], "no roster -> not friendly")

func test_killfeed_entries_decay_out() -> void:
	var m := HudModel.new()
	m.push_kill({"killer": 1, "victim": 2, "headshot": true, "weapon": Weapon.AR}, 10.0)
	var out := m.build({"now": 10.5, "tick": 0})
	assert_eq(out["killfeed"].size(), 1, "fresh entry present")
	assert_true(out["killfeed"][0]["headshot"])
	var out2 := m.build({"now": 10.0 + HudModel.KILLFEED_TTL + 0.1, "tick": 0})
	assert_eq(out2["killfeed"].size(), 0, "expired entry dropped")

func test_scoreboard_groups_by_team_and_sorts_by_score_then_name() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 1, "name": "Zoe", "team": 0, "squad": 0, "kills": 5, "deaths": 1, "score": 500},
		{"id": 2, "name": "Al",  "team": 0, "squad": 0, "kills": 5, "deaths": 1, "score": 500},
		{"id": 3, "name": "Ed",  "team": 1, "squad": 0, "kills": 2, "deaths": 4, "score": 200},
	]
	var out := m.build({"roster": roster, "match_state": {"tickets": [120, 95]}, "tick": 0})
	var sb: Dictionary = out["scoreboard"]
	assert_eq(sb["teams"][0]["rows"].size(), 2)
	assert_eq(sb["teams"][0]["rows"][0]["name"], "Al", "score tie -> name asc")
	assert_eq(sb["teams"][0]["tickets"], 120)
	assert_eq(sb["teams"][1]["rows"][0]["name"], "Ed")
	assert_eq(sb["teams"][1]["tickets"], 95)

func test_squad_roster_lists_squadmates_with_status() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 1, "name": "Me",  "team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
		{"id": 2, "name": "Mate","team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
		{"id": 3, "name": "Other","team": 0, "squad": 5, "kills": 0, "deaths": 0, "score": 0},
	]
	var ents := {2: {"alive": true, "is_downed": true, "pos": Vector3(10, 0, 0)}}
	var out := m.build({"roster": roster, "self_id": 1, "entities": ents, "tick": 0})
	var sq: Array = out["squad_roster"]
	assert_eq(sq.size(), 1, "only same-squad, excluding self")
	assert_eq(sq[0]["name"], "Mate")
	assert_eq(sq[0]["status"], "downed", "downed status from entities")

func test_squad_roster_marks_dead_when_absent_or_not_alive() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 1, "name": "Me", "team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
		{"id": 2, "name": "Gone","team": 0, "squad": 2, "kills": 0, "deaths": 0, "score": 0},
	]
	var out := m.build({"roster": roster, "self_id": 1, "entities": {}, "tick": 0})
	var sq: Array = out["squad_roster"]
	assert_eq(sq[0]["status"], "dead", "no entity -> dead/out of view")

func test_prompt_prefers_revive_over_vehicle() -> void:
	var m := HudModel.new()
	var out := m.build({
		"downed_mates": [{"id": 5, "dist": 2.0}],
		"vehicles_near": [{"vid": 9, "seat": 1, "dist": 1.0}],
		"tick": 0})
	var p: Dictionary = out["interaction_prompt"]
	assert_eq(p["action"], "revive")
	assert_eq(p["target"], 5)

func test_prompt_enter_vehicle_when_no_downed_mate() -> void:
	var m := HudModel.new()
	var out := m.build({"downed_mates": [], "vehicles_near": [{"vid": 9, "seat": 1, "dist": 1.0}], "tick": 0})
	var p: Dictionary = out["interaction_prompt"]
	assert_eq(p["action"], "enter_vehicle")
	assert_eq(p["target"], 9)

func test_prompt_none_when_nothing_in_range() -> void:
	var m := HudModel.new()
	var out := m.build({"downed_mates": [], "vehicles_near": [], "tick": 0})
	assert_eq(out["interaction_prompt"], null)

func test_prompt_exit_vehicle_when_seated() -> void:
	var m := HudModel.new()
	# Seated in vehicle 9 -> the prompt is "exit", overriding a nearby vehicle / downed mate.
	var out := m.build({"in_vehicle": 9, "downed_mates": [{"id": 5, "dist": 2.0}],
		"vehicles_near": [{"vid": 9, "seat": 0, "dist": 0.0}], "tick": 0})
	var p: Dictionary = out["interaction_prompt"]
	assert_eq(p["action"], "exit_vehicle", "seated -> F exits")
	assert_eq(p["target"], 9)

func test_prompt_mount_nest_when_friendly_nest_in_range() -> void:
	var m := HudModel.new()
	# M19 P4: on foot, a friendly unoccupied nest in mount range -> "man the gun" (below vehicles).
	var out := m.build({"downed_mates": [], "vehicles_near": [],
		"nests_near": [{"id": 0x50000001, "dist": 1.2}], "tick": 0})
	var p: Dictionary = out["interaction_prompt"]
	assert_eq(p["action"], "mount_nest")
	assert_eq(p["target"], 0x50000001)

func test_prompt_dismount_nest_when_mounted() -> void:
	var m := HudModel.new()
	# M19 P4: manning a nest -> the prompt is "dismount".
	var out := m.build({"mounted_nest": 0x50000002, "tick": 0})
	var p: Dictionary = out["interaction_prompt"]
	assert_eq(p["action"], "dismount_nest")
	assert_eq(p["target"], 0x50000002)

func test_prompt_dismount_nest_priority_over_everything() -> void:
	var m := HudModel.new()
	# M19 P4: while mounted, dismount overrides a downed mate / nearby vehicle / nearby nest.
	var out := m.build({"mounted_nest": 0x50000003, "in_vehicle": -1,
		"downed_mates": [{"id": 5, "dist": 1.0}],
		"vehicles_near": [{"vid": 9, "seat": 0, "dist": 0.5}],
		"nests_near": [{"id": 0x50000009, "dist": 0.4}], "tick": 0})
	var p: Dictionary = out["interaction_prompt"]
	assert_eq(p["action"], "dismount_nest", "mounted -> dismount beats all")
	assert_eq(p["target"], 0x50000003)

func test_throwables_passthrough_and_active_cycle() -> void:
	var m := HudModel.new()
	var thr := [{"kind": 0, "count": 1}, {"kind": 1, "count": 2}, {"kind": 2, "count": 0}]
	var out := m.build({"throwables": thr, "tick": 0})
	var t: Dictionary = out["throwables"]
	assert_eq(t["list"].size(), 3)
	assert_eq(t["active"], 0, "defaults to first slot")
	m.cycle_throwable(thr.size())
	var out2 := m.build({"throwables": thr, "tick": 0})
	var t2: Dictionary = out2["throwables"]
	assert_eq(t2["active"], 1, "cycle advances active slot")
	m.cycle_throwable(thr.size()); m.cycle_throwable(thr.size())
	var out3 := m.build({"throwables": thr, "tick": 0})
	var t3: Dictionary = out3["throwables"]
	assert_eq(t3["active"], 0, "wraps around")

func test_death_recap_resolves_names_from_roster() -> void:
	var m := HudModel.new()
	var roster := [
		{"id": 7, "name": "Killer", "team": 1, "squad": 0, "kills": 1, "deaths": 0, "score": 100},
		{"id": 9, "name": "Helper", "team": 1, "squad": 0, "kills": 0, "deaths": 0, "score": 0},
	]
	m.set_death_info({"killer": 7, "weapon": Weapon.AR, "distance": 42.5, "killer_hp": 35,
		"attackers": [{"id": 7, "dmg": 80}, {"id": 9, "dmg": 20}]})
	var out := m.build({"roster": roster, "tick": 0})
	var dr: Dictionary = out["death_recap"]
	assert_eq(dr["killer_name"], "Killer")
	assert_almost_eq(dr["distance"], 42.5, 0.1)
	assert_eq(dr["killer_hp"], 35)
	assert_eq(dr["attackers"][0]["name"], "Killer")
	assert_eq(dr["attackers"][0]["dmg"], 80)
	assert_eq(dr["attackers"][1]["name"], "Helper")

func test_death_recap_null_until_set_and_after_clear() -> void:
	var m := HudModel.new()
	assert_eq(m.build({"tick": 0})["death_recap"], null)
	m.set_death_info({"killer": 7, "weapon": 0, "distance": 1.0, "killer_hp": 100, "attackers": []})
	m.clear_death_info()
	assert_eq(m.build({"tick": 0})["death_recap"], null)

func test_damage_arc_relative_and_fades() -> void:
	var m := HudModel.new()
	# yaw 0 -> camera looks -Z; damage from world bearing 0 (+Z) comes from directly behind -> 180 deg.
	m.push_damage(0.0, 25, 10.0)
	var out := m.build({"self_yaw": 0.0, "now": 10.0, "tick": 0})
	assert_eq(out["damage_arcs"].size(), 1)
	assert_almost_eq(absf(rad_to_deg(out["damage_arcs"][0]["rel_bearing"])), 180.0, 1.0)
	assert_true(out["vignette"] > 0.0, "fresh damage raises vignette")
	var faded := m.build({"self_yaw": 0.0, "now": 10.0 + HudModel.DAMAGE_TTL + 0.1, "tick": 0})
	assert_eq(faded["damage_arcs"].size(), 0, "arc expired")
	assert_almost_eq(faded["vignette"], 0.0, 0.01, "vignette decayed to ~0")

func test_blind_intensity_saturates_then_fades() -> void:
	# Saturated white while >= BLIND_FULL_TICKS remain; linear fade to 0; clamped.
	assert_almost_eq(HudModel.blind_intensity(90), 1.0, 0.001)   # fresh flash -> full white
	assert_almost_eq(HudModel.blind_intensity(45), 1.0, 0.001)   # still saturated at the knee
	assert_almost_eq(HudModel.blind_intensity(0), 0.0, 0.001)    # cleared
	var mid := HudModel.blind_intensity(22)                      # mid-fade in (0,1)
	assert_true(mid > 0.0 and mid < 1.0, "mid-tail fades between full and clear")


func test_suppression_intensity_threshold_and_ramp() -> void:
	# A6: veil off below the onset, pow(0.7) ramp to full at SUPPRESS_FX_FULL; clamped.
	assert_almost_eq(HudModel.suppression_intensity(0.0), 0.0, 0.001)    # idle -> nothing
	assert_almost_eq(HudModel.suppression_intensity(0.09), 0.0, 0.001)   # below the onset -> off
	# A single dead-on near-miss (~0.15) must now be clearly visible (not buried near zero as smoothstep did).
	assert_true(HudModel.suppression_intensity(0.15) > 0.2, "one near-miss reads on screen")
	assert_true(HudModel.suppression_intensity(0.24) > 0.0, "realistic near-miss suppression shows a veil")
	assert_almost_eq(HudModel.suppression_intensity(0.35), 1.0, 0.001)   # full at the sustained-fire level
	assert_almost_eq(HudModel.suppression_intensity(1.0), 1.0, 0.001)    # clamped at full above that
	var lo := HudModel.suppression_intensity(0.15)
	var hi := HudModel.suppression_intensity(0.3)
	assert_true(lo > 0.0 and lo < 1.0, "above threshold ramps in (0,1)")
	assert_true(hi > lo, "monotonic increasing with suppression")

func test_repair_heat_hidden_when_idle() -> void:
	var m := HudModel.new()
	var out := m.build({"tick": 0})
	assert_false(out["repair_heat"]["visible"], "no gauge for non-engineers / not repairing")

func test_repair_heat_visible_while_heating() -> void:
	var m := HudModel.new()
	var out := m.build({"tick": 0, "repair_heat": 0.4})
	assert_true(out["repair_heat"]["visible"], "gauge shows while heat accrues")
	assert_false(out["repair_heat"]["overheated"], "not overheated below lockout")
	assert_eq(out["repair_heat"]["heat"], 0.4)

func test_repair_heat_overheated_during_cooldown() -> void:
	var m := HudModel.new()
	var out := m.build({"tick": 0, "repair_heat": 0.0, "repair_cooldown": 0.8})
	assert_true(out["repair_heat"]["visible"], "gauge stays up during the lockout")
	assert_true(out["repair_heat"]["overheated"], "cooldown>0 reads as overheated")
	assert_eq(out["repair_heat"]["cooldown"], 0.8)

func test_mg_gauge_hidden_on_foot() -> void:
	var m := HudModel.new().build({"mounted_nest": 0, "tick": 0})
	assert_false(bool(m["mg_gauge"]["visible"]))

func test_mg_gauge_shows_heat_belt_when_mounted() -> void:
	var g: Dictionary = HudModel.new().build({"mounted_nest": 5, "mg_heat": 128, "mg_ammo": 90,
		"mg_overheated": false, "tick": 0})["mg_gauge"]
	assert_true(bool(g["visible"]))
	assert_almost_eq(float(g["heat_frac"]), 0.502, 0.01)
	assert_eq(int(g["ammo"]), 90)
	assert_eq(int(g["belt_max"]), 150)
	assert_false(bool(g["reloading"]))

func test_mg_gauge_reloading_and_overheat_flags() -> void:
	var g: Dictionary = HudModel.new().build({"mounted_nest": 5, "mg_heat": 255, "mg_ammo": 0,
		"mg_overheated": true, "tick": 0})["mg_gauge"]
	assert_true(bool(g["overheated"]))
	assert_true(bool(g["reloading"]))

func test_bandage_hidden_when_out() -> void:
	# M16/M1: no bandages (or the field absent -> defaults 0) -> the readout is hidden.
	var absent: Dictionary = HudModel.new().build({"tick": 0})["bandage"]
	assert_false(bool(absent["visible"]), "no bandage_count -> readout hidden")
	assert_eq(int(absent["count"]), 0)
	var zero: Dictionary = HudModel.new().build({"bandage_count": 0, "tick": 0})["bandage"]
	assert_false(bool(zero["visible"]), "0 bandages -> readout hidden (out signal)")

func test_bandage_shows_count_when_held() -> void:
	var bd: Dictionary = HudModel.new().build({"bandage_count": 3, "tick": 0})["bandage"]
	assert_true(bool(bd["visible"]), "holding bandages -> readout shown")
	assert_eq(int(bd["count"]), 3, "count surfaced for the HUD label")


## G2c: pure shield-block flash predicate + the fade-over-TTL fx read.
func test_shield_flash_absorb_and_break() -> void:
	# A drop while up = an absorbed hit (mild); a drop to 0 = a break (strong).
	assert_eq(HudModel.shield_flash_strength(255, 200, true), 0.5, "absorb pulses mildly")
	assert_eq(HudModel.shield_flash_strength(40, 0, true), 1.0, "break pulses strongly")

func test_shield_flash_no_pulse_cases() -> void:
	assert_eq(HudModel.shield_flash_strength(200, 200, true), 0.0, "no change = no pulse")
	assert_eq(HudModel.shield_flash_strength(100, 200, true), 0.0, "a re-arm (increase) never pulses")
	assert_eq(HudModel.shield_flash_strength(255, 100, false), 0.0, "shield down = no pulse")

func test_shield_flash_fx_fades_over_ttl() -> void:
	var m := HudModel.new()
	m.push_shield_flash(1.0, 10.0)
	assert_eq(m.build({"now": 10.0})["shield_flash"], 1.0, "full strength at the instant of the pulse")
	var mid: float = m.build({"now": 10.0 + HudModel.SHIELD_FLASH_TTL * 0.5})["shield_flash"]
	assert_true(mid > 0.4 and mid < 0.6, "roughly half-faded at half the TTL")
	assert_eq(m.build({"now": 10.0 + HudModel.SHIELD_FLASH_TTL + 0.01})["shield_flash"], 0.0, "gone after the TTL")
