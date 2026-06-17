extends TestCase

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1},{"id":"B","pos":[200,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func _map() -> MapDef:
	return MapDef.from_json_string(MAP_JSON)["map"]

func _conquest(owner0_pt: int) -> ConquestState:
	var c := ConquestState.new(_map())
	if owner0_pt >= 0:
		c.points[owner0_pt]["owner"] = 0
	return c

func test_hq_ref_is_always_valid_and_resolves_to_base() -> void:
	var m := _map()
	var c := _conquest(-1)
	assert_true(DeploySpawn.is_valid(0, 0, m, c), "HQ ref valid for team 0")
	var pos := DeploySpawn.resolve(0, 0, m, c)
	var base := m.base_for(0)
	assert_almost_eq(pos.x, base["pos"].x, 12.0, "HQ resolves near team base (within jitter)")

func test_owned_point_ref_valid_enemy_point_invalid() -> void:
	var m := _map()
	var c := _conquest(0)   # point index 0 owned by team 0 -> ref 1
	assert_true(DeploySpawn.is_valid(0, 1, m, c), "owned point ref valid")
	assert_false(DeploySpawn.is_valid(1, 1, m, c), "team 1 cannot spawn on a team-0 point")

func test_enumerate_lists_hq_plus_owned_points() -> void:
	var m := _map()
	var c := _conquest(0)
	var refs := DeploySpawn.enumerate(0, m, c)
	assert_true(refs.has(0), "HQ always offered")
	assert_true(refs.has(1), "owned point offered")
	assert_false(refs.has(2), "non-owned point not offered")

func test_squadmate_ref_valid_when_mate_alive_standing() -> void:
	var m := _map()
	var c := _conquest(-1)
	var mates := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
	assert_true(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, mates),
		"alive standing same-team mate is a valid spawn")
	var pos := DeploySpawn.resolve(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, mates)
	assert_almost_eq(pos.distance_to(Vector3(20, 0, 5)), 0.0, DeploySpawn.JITTER * sqrt(2.0) + 0.01,
		"resolves near the mate (within jitter)")

func test_squadmate_ref_invalid_when_downed_or_dead() -> void:
	var m := _map()
	var c := _conquest(-1)
	var downed := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": true}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, downed), "downed mate rejected")
	var dead := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": false, "downed": false}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 0, m, c, dead), "dead mate rejected")

func test_vehicle_ref_valid_with_free_seat_same_team() -> void:
	var m := _map()
	var c := _conquest(-1)
	var veh := [{"pos": Vector3(30, 0, 30), "team": 0, "free_seats": 2}]
	assert_true(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], veh), "free-seat friendly vehicle valid")
	var full := [{"pos": Vector3(30, 0, 30), "team": 0, "free_seats": 0}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], full), "full vehicle rejected")
	var enemy := [{"pos": Vector3(30, 0, 30), "team": 1, "free_seats": 2}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], enemy), "enemy vehicle rejected")

func test_enumerate_includes_valid_squadmate_and_vehicle_refs() -> void:
	var m := _map()
	var c := _conquest(0)
	var mates := [{"pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
	var veh := [{"pos": Vector3(30, 0, 30), "team": 0, "free_seats": 1}]
	var refs := DeploySpawn.enumerate(0, m, c, mates, veh)
	assert_true(refs.has(DeploySpawn.SQUADMATE_BASE + 0), "valid mate ref offered")
	assert_true(refs.has(DeploySpawn.VEHICLE_BASE + 0), "valid vehicle ref offered")
	assert_true(refs.has(0), "HQ still offered")
