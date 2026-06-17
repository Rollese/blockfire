extends TestCase

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1},{"id":"B","pos":[200,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func _map() -> MapDef:
	return MapDef.from_json_string(MAP_JSON)["map"]

func test_squadmate_candidate_array_validates_through_deployspawn() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	# mate has pawn id 5; ref is keyed by that id (SQUADMATE_BASE + 5), not array position.
	var mates := [{"id": 5, "pos": Vector3(25, 0, 5), "team": 0, "alive": true, "downed": false}]
	var ref := DeploySpawn.SQUADMATE_BASE + 5
	assert_true(DeploySpawn.is_valid(0, ref, m, c, mates), "server re-validates the requested mate ref")
	var pos := DeploySpawn.resolve(0, ref, m, c, mates)
	assert_almost_eq(pos.distance_to(Vector3(25, 0, 5)), 0.0, DeploySpawn.JITTER * sqrt(2.0) + 0.01)

func test_request_for_dead_mate_is_rejected() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	var mates := [{"id": 5, "pos": Vector3(25, 0, 5), "team": 0, "alive": false, "downed": false}]
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.SQUADMATE_BASE + 5, m, c, mates))
