extends TestCase
## M7.5-P3 Task 1: AiSupport pure support/survival decisions. Fabricated dicts, no server.
const Support := preload("res://bots/ai/behaviors/support.gd")

func _downed(id: int, dist: float) -> Dictionary:
	return {"id": id, "pos": Vector3(dist, 0, 0), "dist": dist}

# --- should_self_bandage --------------------------------------------------

func test_self_bandage_when_downed_with_bandage() -> void:
	assert_true(Support.should_self_bandage(true, 1, false, false),
		"downed + bandage + still bleeding + nobody reviving -> bandage")

func test_self_bandage_refused_in_every_disqualifying_state() -> void:
	assert_false(Support.should_self_bandage(false, 1, false, false), "not downed -> no")
	assert_false(Support.should_self_bandage(true, 0, false, false), "no bandages -> no")
	assert_false(Support.should_self_bandage(true, 1, true, false), "bleed already halted -> no")
	assert_false(Support.should_self_bandage(true, 1, false, true), "being revived -> don't waste it")

# --- pick_revive_target ---------------------------------------------------

func test_revive_picks_nearest_within_range() -> void:
	var picked := Support.pick_revive_target([_downed(1, 9.0), _downed(2, 4.0), _downed(3, 6.0)], false)
	assert_eq(int(picked["id"]), 2, "nearest downed ally wins")

func test_revive_empty_when_all_beyond_range() -> void:
	var picked := Support.pick_revive_target([_downed(1, Support.NONMEDIC_REVIVE_RANGE + 0.1)], false)
	assert_true(picked.is_empty(), "non-medic ignores a downed ally just beyond 12m")

func test_medic_reaches_farther_than_nonmedic() -> void:
	var far := [_downed(1, 30.0)]
	assert_eq(int(Support.pick_revive_target(far, true)["id"]), 1, "medic commits out to 40m")
	assert_true(Support.pick_revive_target(far, false).is_empty(), "non-medic won't cross the map")

func test_revive_boundary_inclusive_and_empty_input() -> void:
	assert_eq(int(Support.pick_revive_target([_downed(1, Support.NONMEDIC_REVIVE_RANGE)], false)["id"]), 1,
		"exactly at range still counts")
	assert_true(Support.pick_revive_target([], true).is_empty(), "no downed allies -> {}")

# --- wants_supply ---------------------------------------------------------

func test_wants_supply_thresholds() -> void:
	assert_eq(Support.wants_supply(0.54, 1.0), "heal", "hp below 0.55 -> heal")
	assert_eq(Support.wants_supply(1.0, 0.33), "ammo", "ammo below 0.34 -> ammo")
	assert_eq(Support.wants_supply(Support.BAG_SEEK_HP_FRAC, Support.BAG_SEEK_AMMO_FRAC), "",
		"exactly at both thresholds -> content")

func test_wants_supply_heal_outranks_ammo() -> void:
	assert_eq(Support.wants_supply(0.2, 0.1), "heal", "when both are low, health first")

# --- pick_supply_bag ------------------------------------------------------

func test_pick_supply_bag_nearest_friendly_of_kind() -> void:
	var bags := [
		{"kind": "heal", "pos": Vector3(10, 0, 0), "team": 0},
		{"kind": "heal", "pos": Vector3(3, 0, 0), "team": 0},
		{"kind": "ammo", "pos": Vector3(1, 0, 0), "team": 0},
		{"kind": "heal", "pos": Vector3(2, 0, 0), "team": 1},
	]
	var picked := Support.pick_supply_bag(bags, Vector3.ZERO, 0, "heal")
	assert_eq(picked["pos"], Vector3(3, 0, 0), "nearest friendly heal bag; enemy + ammo bags skipped")

func test_pick_supply_bag_empty_when_no_match() -> void:
	assert_true(Support.pick_supply_bag([], Vector3.ZERO, 0, "heal").is_empty(), "no bags -> {}")
	var enemy_only := [{"kind": "heal", "pos": Vector3.ZERO, "team": 1}]
	assert_true(Support.pick_supply_bag(enemy_only, Vector3.ZERO, 0, "heal").is_empty(),
		"enemy bag of the right kind is not ours")

# --- should_deploy_bag ----------------------------------------------------

func test_deploy_bag_class_gate() -> void:
	assert_true(Support.should_deploy_bag(Loadout.MEDIC, 2, 1000, 0), "medic deploys")
	assert_true(Support.should_deploy_bag(Loadout.SUPPORT, 2, 1000, 0), "support deploys")
	assert_false(Support.should_deploy_bag(Loadout.ASSAULT, 5, 1000, 0), "assault has no bag")
	assert_false(Support.should_deploy_bag(Loadout.ENGINEER, 5, 1000, 0), "engineer has no bag")

func test_deploy_bag_needs_two_needy_and_cooldown() -> void:
	assert_false(Support.should_deploy_bag(Loadout.MEDIC, 1, 1000, 0), "one needy ally isn't worth the bag")
	assert_false(Support.should_deploy_bag(Loadout.MEDIC, 2, 449, 0), "cooldown not elapsed")
	assert_true(Support.should_deploy_bag(Loadout.MEDIC, 2, Support.BAG_DEPLOY_COOLDOWN_TICKS, 0),
		"exactly at cooldown -> allowed")

# --- danger_zones ---------------------------------------------------------

func test_danger_zones_grenades_expire() -> void:
	var nades := [{"pos": Vector3(1, 0, 0), "tick": 100}, {"pos": Vector3(2, 0, 0), "tick": 0}]
	var zones := Support.danger_zones(nades, [], 0, 100 + Support.GRENADE_DANGER_TICKS)
	assert_eq(zones.size(), 1, "stale grenade event dropped, live one kept (boundary inclusive)")
	assert_eq(zones[0]["pos"], Vector3(1, 0, 0), "the live zone is the fresh grenade")
	assert_almost_eq(float(zones[0]["radius"]), Support.GRENADE_DANGER_RADIUS, 0.001, "grenade radius")

func test_danger_zones_enemy_mines_only() -> void:
	var mines := [{"pos": Vector3(5, 0, 0), "team": 1}, {"pos": Vector3(6, 0, 0), "team": 0}]
	var zones := Support.danger_zones([], mines, 0, 0)
	assert_eq(zones.size(), 1, "own team's mines are safe (they don't trigger on us)")
	assert_eq(zones[0]["pos"], Vector3(5, 0, 0), "enemy mine is the danger")
	assert_almost_eq(float(zones[0]["radius"]), Support.MINE_DANGER_RADIUS, 0.001, "mine radius")

func test_danger_zones_empty_inputs() -> void:
	assert_true(Support.danger_zones([], [], 0, 0).is_empty(), "nothing dangerous -> no zones")

# --- flee_vector ----------------------------------------------------------

func test_flee_vector_zero_when_clear() -> void:
	var zones := [{"pos": Vector3(100, 0, 0), "radius": 8.0}]
	assert_eq(Support.flee_vector(Vector3.ZERO, zones), Vector3.ZERO, "outside every zone -> ZERO")
	assert_eq(Support.flee_vector(Vector3.ZERO, []), Vector3.ZERO, "no zones -> ZERO")

func test_flee_vector_points_away_from_nearest_zone() -> void:
	var zones := [
		{"pos": Vector3(3, 0, 0), "radius": 8.0},   # nearest — flee -X
		{"pos": Vector3(0, 0, 4), "radius": 8.0},
	]
	var v := Support.flee_vector(Vector3.ZERO, zones)
	assert_almost_eq(v.length(), 1.0, 0.001, "normalized")
	assert_almost_eq(v.x, -1.0, 0.001, "away from the nearest zone, nearest dominates")
	assert_almost_eq(v.y, 0.0, 0.001, "flee stays in the ground plane")

func test_flee_vector_degenerate_on_top_of_zone() -> void:
	var zones := [{"pos": Vector3(0, 5, 0), "radius": 8.0}]   # same XZ, only Y differs
	assert_eq(Support.flee_vector(Vector3.ZERO, zones), Vector3(0, 0, 1),
		"standing exactly on the zone -> arbitrary but fixed escape heading")
