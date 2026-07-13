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
	# prebuilt test structures removed 2026-07-03 (HQ sandbags blocked bot spawns; no longer testing
	# static deployables) — proving_grounds now matches the other gameplay maps with an empty prebuilt.
	assert_eq(m.prebuilt.size(), 0, "no leftover prebuilt test structures")

func test_parses_roads() -> void:
	var r := MapDef.from_json_string('{"name":"r","world_half":50,"points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"roads":[{"min":[-6,0,-40],"max":[6,0,40]}]}')
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].roads.size(), 1)
	assert_eq(r["map"].roads[0]["max"], Vector3(6, 0, 40))

func test_town_map_loads_with_full_layout() -> void:
	var m := MapDef.load_file("res://maps/conquest_town.json")
	assert_true(m != null, "town map loads")
	assert_eq(m.points.size(), 5, "five capture points")
	assert_eq(m.bases.size(), 2, "two main bases")
	assert_true(m.roads.size() >= 4, "has a road network")
	assert_true(m.buildings.size() >= 20, "has a town's worth of buildings")

# Vehicles are DEFERRED (owner-directed 2026-07-05 — see docs/TASKS.md banner + AGENTS.md §12), so
# the shipping maps ship with NO vehicle spawns. This test verifies the PARSER from an inline JSON
# string (decoupled from map content) so coverage survives until the Vehicles milestone reopens.
func test_parses_vehicle_spawns() -> void:
	var r := MapDef.from_json_string('{"name":"v","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"vehicle_spawns":[{"team":0,"type":"transport","pos":[-14,0,-150],"heading":0.0},{"team":1,"type":"transport","pos":[14,0,150],"heading":3.14159}]}')
	assert_true(r["ok"], r["error"])
	var m: MapDef = r["map"]
	assert_true(m.vehicle_spawns.size() >= 2)   # at least one per team
	var s: Dictionary = m.vehicle_spawns[0]
	assert_true(s.has("team"))
	assert_true(s.has("pos"))
	assert_true(s.has("type"))

# Guards the deferral: the shipping maps must contain NO vehicle spawns until vehicles are reopened.
func test_shipping_maps_have_no_vehicle_spawns() -> void:
	for name in ["conquest_town", "conquest_suburb", "conquest_proving_grounds", "conquest_arena_buildings", "conquest_caspian"]:
		var m := MapDef.load_file("res://maps/%s.json" % name)
		assert_true(m != null, name)
		assert_eq(m.vehicle_spawns.size(), 0, "%s ships with no vehicle spawns (vehicles deferred)" % name)

func test_parses_scenery() -> void:
	var r := MapDef.from_json_string('{"name":"s","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"scenery":[{"id":"tree_type0_01","pos":[1,0,2],"yaw":0.5,"scale":1.2}]}')
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].scenery.size(), 1)
	assert_eq(r["map"].scenery[0]["id"], "tree_type0_01")
	assert_eq(r["map"].scenery[0]["pos"], Vector3(1, 0, 2))
	assert_almost_eq(r["map"].scenery[0]["yaw"], 0.5)
	assert_almost_eq(r["map"].scenery[0]["scale"], 1.2)

func test_scenery_defaults_yaw_and_scale() -> void:
	var r := MapDef.from_json_string('{"name":"s","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"scenery":[{"id":"rock_type1_01","pos":[0,0,0]}]}')
	assert_true(r["ok"], r["error"])
	assert_almost_eq(r["map"].scenery[0]["yaw"], 0.0)
	assert_almost_eq(r["map"].scenery[0]["scale"], 1.0)

func test_rejects_bad_scenery_scale() -> void:
	var r := MapDef.from_json_string('{"name":"s","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"scenery":[{"id":"x","pos":[0,0,0],"scale":0}]}')
	assert_false(r["ok"])

func test_proving_grounds_has_scenery_smoke_placements() -> void:
	var m := MapDef.load_file("res://maps/conquest_proving_grounds.json")
	assert_true(m != null)
	assert_true(m.scenery.size() >= 1, "proving grounds has scenery smoke placements")

func test_parses_scenery_palette() -> void:
	var r := MapDef.from_json_string('{"name":"s","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"scenery_palette":{"tree":"dry","rock":"sand","storage":"yellow","vehicle_static":"red"}}')
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].scenery_palette["tree"], "dry")
	assert_eq(r["map"].scenery_palette["rock"], "sand")
	assert_eq(r["map"].scenery_palette["storage"], "yellow")
	assert_eq(r["map"].scenery_palette["vehicle_static"], "red")

func test_scenery_palette_defaults_empty() -> void:
	var r := MapDef.from_json_string('{"name":"s","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}]}')
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].scenery_palette.size(), 0)

func test_parses_scenery_instance_palette() -> void:
	var r := MapDef.from_json_string('{"name":"s","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"scenery":[{"id":"tree_type0_01","pos":[0,0,0],"palette":"cold"}]}')
	assert_true(r["ok"], r["error"])
	assert_eq(r["map"].scenery[0]["palette"], "cold")

func test_scenery_palette_key_absent_when_not_set() -> void:
	var r := MapDef.from_json_string('{"name":"s","points":[{"id":"A","pos":[0,0,0],"radius":5}],"bases":[{"team":0,"pos":[-10,0,0],"radius":5},{"team":1,"pos":[10,0,0],"radius":5}],"scenery":[{"id":"rock_type1_01","pos":[0,0,0]}]}')
	assert_true(r["ok"], r["error"])
	assert_false(r["map"].scenery[0].has("palette"))
