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

const GEOM := '{"name":"g","points":[{"id":"A","pos":[0,0,0],"radius":10}],"bases":[{"team":0,"pos":[-9,0,0],"radius":4},{"team":1,"pos":[9,0,0],"radius":4}],"ladders":[{"bottom":[5,0,5],"top":[5,4,5],"radius":0.6}],"platforms":[{"min":[0,0,0],"max":[10,4,10]}],"prebuilt":[{"type":"sandbag","cell":[3,0,3]}]}'

func test_parses_ladders_platforms_prebuilt() -> void:
	var r := MapDef.from_json_string(GEOM)
	assert_true(r["ok"], r["error"])
	var m: MapDef = r["map"]
	assert_eq(m.ladders.size(), 1)
	assert_eq(m.ladders[0]["bottom"], Vector3(5, 0, 5))
	assert_eq(m.ladders[0]["top"], Vector3(5, 4, 5))
	assert_almost_eq(m.ladders[0]["radius"], 0.6)
	assert_eq(m.platforms.size(), 1)
	assert_eq(m.platforms[0]["max"], Vector3(10, 4, 10))
	assert_eq(m.prebuilt.size(), 1)
	assert_eq(m.prebuilt[0]["type"], "sandbag")
	assert_eq(m.prebuilt[0]["cell"], Vector3i(3, 0, 3))

func test_geometry_arrays_default_empty() -> void:
	var r := MapDef.from_json_string(VALID)   # VALID has no ladders/platforms/prebuilt
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].ladders.size(), 0)
	assert_eq(r["map"].platforms.size(), 0)
	assert_eq(r["map"].prebuilt.size(), 0)

func test_proving_grounds_loads_with_geometry() -> void:
	var m := MapDef.load_file("res://maps/conquest_proving_grounds.json")
	assert_true(m != null, "proving grounds map loads")
	assert_true(m.ladders.size() >= 1, "has a ladder")
	assert_true(m.platforms.size() >= 1, "has a platform")
	assert_true(m.prebuilt.size() >= 1, "has prebuilt geometry")
