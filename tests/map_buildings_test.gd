extends TestCase
## MapDef.buildings: [{prefab:String, origin_cell:Vector3i, yaw:int}].

func test_buildings_parse() -> void:
	var res := MapDef.from_dict({
		"name": "m", "world_half": 100.0,
		"points": [{"id": "A", "pos": [0,0,0], "radius": 10.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [-40,0,0], "radius": 10.0}, {"team": 1, "pos": [40,0,0], "radius": 10.0}],
		"buildings": [{"prefab": "bunker", "origin_cell": [5, 0, -3], "yaw": 2}]
	})
	assert_true(res["ok"], "map with buildings ok")
	var m: MapDef = res["map"]
	assert_eq(m.buildings.size(), 1, "one building")
	assert_eq(m.buildings[0]["prefab"], "bunker", "prefab name")
	assert_eq(m.buildings[0]["origin_cell"], Vector3i(5, 0, -3), "origin as Vector3i")
	assert_eq(m.buildings[0]["yaw"], 2, "yaw kept")

func test_building_bad_origin_rejected() -> void:
	var res := MapDef.from_dict({
		"name": "m", "world_half": 100.0,
		"points": [{"id": "A", "pos": [0,0,0], "radius": 10.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [-40,0,0], "radius": 10.0}, {"team": 1, "pos": [40,0,0], "radius": 10.0}],
		"buildings": [{"prefab": "bunker", "origin_cell": [5, 0], "yaw": 0}]
	})
	assert_false(res["ok"], "non-3 origin rejected")

func test_no_buildings_key_is_empty() -> void:
	var res := MapDef.load_file("res://maps/conquest_dev_arena.json")
	assert_true(res != null, "existing map still loads")
	assert_eq(res.buildings.size(), 0, "no buildings key -> empty array")
