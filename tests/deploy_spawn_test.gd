extends TestCase

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1},{"id":"B","pos":[200,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func _map() -> MapDef:
	return MapDef.from_json_string(MAP_JSON)["map"]

func _conquest(owner0_pt: int) -> ConquestState:
	var c := ConquestState.new(_map())
	if owner0_pt >= 0:
		c.points[owner0_pt]["owner"] = 0
	return c

func test_contested_owned_point_not_valid_or_offered() -> void:
	var m := _map()
	var c := _conquest(0)            # team 0 owns point A (ref 1)
	assert_true(DeploySpawn.is_valid(0, 1, m, c), "owned + uncontested point is valid")
	assert_true(DeploySpawn.enumerate(0, m, c).has(1), "and offered in the deploy menu")
	c.points[0]["n1"] = 1            # an enemy steps onto A (as step() caches)
	assert_false(DeploySpawn.is_valid(0, 1, m, c), "can't deploy on a contested point")
	assert_false(DeploySpawn.enumerate(0, m, c).has(1), "contested point dropped from the deploy menu")
	assert_true(DeploySpawn.enumerate(0, m, c).has(0), "HQ still offered as a fallback")

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

func test_high_pawn_id_squadmate_ref_does_not_alias_into_vehicle_or_fob_space() -> void:
	# Regression (pre-M8-P3): pawn ids are monotonic and NEVER reused across disconnects, so on
	# a persistent server they exceed 128. With the old bases (200/400/600) a mate with pawn id
	# 200 produced ref 400 == VEHICLE_BASE — is_valid parsed it as a vehicle slot and the deploy
	# silently failed (or hit the wrong entity). Ids up to ~39k must stay in squadmate space.
	var m := _map()
	var c := _conquest(-1)
	for pid in [200, 400, 5000]:
		var mates := [{"id": pid, "pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
		var ref: int = DeploySpawn.SQUADMATE_BASE + pid
		assert_true(ref < DeploySpawn.VEHICLE_BASE, "ref for pawn id %d stays below vehicle space" % pid)
		assert_true(DeploySpawn.is_valid(0, ref, m, c, mates), "mate with pawn id %d is spawnable" % pid)
		var pos := DeploySpawn.resolve(0, ref, m, c, mates)
		assert_almost_eq(pos.distance_to(Vector3(20, 0, 5)), 0.0, DeploySpawn.JITTER * sqrt(2.0) + 0.01,
			"resolves near the mate, not a phantom vehicle/FOB")

func test_ref_spaces_fit_the_u16_deploy_wire() -> void:
	# DEPLOY_REQUEST carries the ref as u16; the top of FOB space must stay addressable.
	assert_true(DeploySpawn.FOB_BASE > DeploySpawn.VEHICLE_BASE and DeploySpawn.VEHICLE_BASE > DeploySpawn.SQUADMATE_BASE,
		"space ordering preserved (is_valid checks FOB, then vehicle, then squadmate)")
	assert_true(DeploySpawn.FOB_BASE + 64 <= 0xFFFF, "FOB refs fit in u16")

func test_squadmate_ref_valid_when_mate_alive_standing() -> void:
	var m := _map()
	var c := _conquest(-1)
	# Refs are keyed by the mate's stable pawn id, NOT array position.
	var mates := [{"id": 7, "pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
	assert_true(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 7, m, c, mates),
		"alive standing same-team mate is a valid spawn")
	var pos := DeploySpawn.resolve(0, DeploySpawn.SQUADMATE_BASE + 7, m, c, mates)
	assert_almost_eq(pos.distance_to(Vector3(20, 0, 5)), 0.0, DeploySpawn.JITTER * sqrt(2.0) + 0.01,
		"resolves near the mate (within jitter)")

func test_squadmate_ref_invalid_when_downed_or_dead() -> void:
	var m := _map()
	var c := _conquest(-1)
	var downed := [{"id": 7, "pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": true}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 7, m, c, downed), "downed mate rejected")
	var dead := [{"id": 7, "pos": Vector3(20, 0, 5), "team": 0, "alive": false, "downed": false}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 7, m, c, dead), "dead mate rejected")

func test_squadmate_ref_resolves_by_id_regardless_of_array_order() -> void:
	# Regression: client and server build the mates array in different order/membership.
	# A ref keyed by pawn id must resolve to the SAME mate no matter the array layout.
	var m := _map()
	var c := _conquest(-1)
	var mate_a := {"id": 3, "pos": Vector3(10, 0, 0), "team": 0, "alive": true, "downed": false}
	var mate_b := {"id": 9, "pos": Vector3(50, 0, 0), "team": 0, "alive": true, "downed": false}
	var server_order := [mate_a, mate_b]
	var client_order := [mate_b, mate_a]   # different order
	var ref := DeploySpawn.SQUADMATE_BASE + 9   # always mate_b
	var p_server := DeploySpawn.resolve(0, ref, m, c, server_order)
	var p_client_view := DeploySpawn.resolve(0, ref, m, c, client_order)
	assert_almost_eq(p_server.distance_to(Vector3(50, 0, 0)), 0.0, DeploySpawn.JITTER * sqrt(2.0) + 0.01,
		"server resolves ref 9 to mate_b")
	assert_almost_eq(p_client_view.distance_to(Vector3(50, 0, 0)), 0.0, DeploySpawn.JITTER * sqrt(2.0) + 0.01,
		"same ref resolves to mate_b even when the array is ordered differently")

func test_squadmate_ref_invalid_when_id_absent() -> void:
	var m := _map()
	var c := _conquest(-1)
	var mates := [{"id": 7, "pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 4, m, c, mates),
		"ref for an id not in the candidate set is rejected (not a positional fallback)")

func test_vehicle_ref_valid_with_free_seat_same_team() -> void:
	var m := _map()
	var c := _conquest(-1)
	# Refs are keyed by the vehicle's stable slot, NOT array position.
	var veh := [{"slot": 0, "pos": Vector3(30, 0, 30), "team": 0, "free_seats": 2}]
	assert_true(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], veh), "free-seat friendly vehicle valid")
	var full := [{"slot": 0, "pos": Vector3(30, 0, 30), "team": 0, "free_seats": 0}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], full), "full vehicle rejected")
	var enemy := [{"slot": 0, "pos": Vector3(30, 0, 30), "team": 1, "free_seats": 2}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], enemy), "enemy vehicle rejected")
	# slot-keyed: a vehicle at slot 1 is addressed by VEHICLE_BASE+1 even if it's array index 0
	var veh1 := [{"slot": 1, "pos": Vector3(30, 0, 30), "team": 0, "free_seats": 1}]
	assert_true(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 1, m, c, [], veh1), "vehicle addressed by slot, not index")
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.VEHICLE_BASE + 0, m, c, [], veh1), "wrong slot rejected")

func test_enumerate_includes_valid_squadmate_and_vehicle_refs() -> void:
	var m := _map()
	var c := _conquest(0)
	var mates := [{"id": 5, "pos": Vector3(20, 0, 5), "team": 0, "alive": true, "downed": false}]
	var veh := [{"slot": 0, "pos": Vector3(30, 0, 30), "team": 0, "free_seats": 1}]
	var refs := DeploySpawn.enumerate(0, m, c, mates, veh)
	assert_true(refs.has(DeploySpawn.SQUADMATE_BASE + 5), "valid mate ref offered (keyed by id)")
	assert_true(refs.has(DeploySpawn.VEHICLE_BASE + 0), "valid vehicle ref offered (keyed by slot)")
	assert_true(refs.has(0), "HQ still offered")
