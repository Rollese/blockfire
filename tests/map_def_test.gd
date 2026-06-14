extends TestCase

const VALID := '{"name":"t","world_half":1000,"points":[{"id":"A","pos":[1,0,2],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func test_loads_valid_map() -> void:
	var r := MapDef.from_json_string(VALID)
	assert_true(r["ok"], r["error"])
	var m: MapDef = r["map"]
	assert_eq(m.points.size(), 1)
	assert_eq(m.points[0]["pos"], Vector3(1, 0, 2))
	assert_almost_eq(m.points[0]["radius"], 30.0)
	assert_eq(m.base_for(1)["pos"], Vector3(900, 0, 0))

func test_rejects_empty_points() -> void:
	assert_eq(MapDef.from_json_string('{"points":[],"bases":[]}')["ok"], false)

func test_rejects_bad_radius() -> void:
	assert_eq(MapDef.from_json_string('{"points":[{"pos":[0,0,0],"radius":0}],"bases":[]}')["ok"], false)

func test_rejects_missing_team_base() -> void:
	var r := MapDef.from_json_string('{"points":[{"pos":[0,0,0],"radius":10}],"bases":[{"team":0,"pos":[0,0,0],"radius":10}]}')
	assert_eq(r["ok"], false)

func test_start_owner_defaults_neutral() -> void:
	var r := MapDef.from_json_string('{"points":[{"pos":[0,0,0],"radius":10}],"bases":[{"team":0,"pos":[0,0,0],"radius":1},{"team":1,"pos":[1,0,0],"radius":1}]}')
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].points[0]["start_owner"], -1)
