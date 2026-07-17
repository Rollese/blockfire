extends TestCase

func _base_map() -> Dictionary:
	return {
		"name": "roads_fixture",
		"world_half": 100.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 10.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -80]}, {"team": 1, "pos": [0, 0, 80]}],
	}

func test_legacy_aabb_road_still_parses() -> void:
	var d := _base_map()
	d["roads"] = [{"min": [-6, 0, -60], "max": [6, 0, 60]}]
	var res := MapDef.from_dict(d)
	assert_true(res["ok"], "legacy AABB road parses: %s" % res["error"])
	var m: MapDef = res["map"]
	assert_eq(m.roads.size(), 1, "one road")
	assert_eq(m.roads[0]["min"], Vector3(-6, 0, -60), "min round-trips")
	assert_false(m.roads[0].has("spline"), "an AABB road carries no spline key")

func test_spline_road_parses() -> void:
	var d := _base_map()
	d["roads"] = [{"spline": [[-50, 0], [0, 10], [50, 0]], "width": 9.0}]
	var res := MapDef.from_dict(d)
	assert_true(res["ok"], "spline road parses: %s" % res["error"])
	var m: MapDef = res["map"]
	assert_eq(m.roads.size(), 1, "one road")
	var sp: PackedVector2Array = m.roads[0]["spline"]
	assert_eq(sp.size(), 3, "3 control points")
	assert_almost_eq(sp[1].x, 0.0, 0.001, "control point x")
	assert_almost_eq(sp[1].y, 10.0, 0.001, "control point z lands in Vector2.y")
	assert_almost_eq(float(m.roads[0]["width"]), 9.0, 0.001, "width parsed")

func test_spline_road_defaults_width() -> void:
	var d := _base_map()
	d["roads"] = [{"spline": [[-50, 0], [50, 0]]}]
	var res := MapDef.from_dict(d)
	assert_true(res["ok"], "width is optional")
	assert_almost_eq(float(res["map"].roads[0]["width"]), MapDef.ROAD_DEFAULT_WIDTH, 0.001, "default width applied")

func test_mixed_road_forms_coexist() -> void:
	var d := _base_map()
	d["roads"] = [{"min": [-6, 0, -60], "max": [6, 0, 60]}, {"spline": [[-50, 0], [50, 0]], "width": 8.0}]
	var res := MapDef.from_dict(d)
	assert_true(res["ok"], "both forms in one map")
	assert_eq(res["map"].roads.size(), 2, "both roads kept")
	assert_true(res["map"].roads[0].has("min"), "first is the AABB form")
	assert_true(res["map"].roads[1].has("spline"), "second is the spline form")

func test_road_with_neither_form_is_rejected() -> void:
	var d := _base_map()
	d["roads"] = [{"width": 8.0}]
	var res := MapDef.from_dict(d)
	assert_false(res["ok"], "a road that is neither AABB nor spline is invalid")
	assert_contains(res["error"], "road", "error names the offender")

func test_spline_needs_two_points() -> void:
	var d := _base_map()
	d["roads"] = [{"spline": [[0, 0]], "width": 8.0}]
	var res := MapDef.from_dict(d)
	assert_false(res["ok"], "a 1-point spline is invalid")

func test_real_town_map_still_parses() -> void:
	# The live map must survive the parser change.
	var m := MapDef.load_file("res://maps/conquest_town.json")
	assert_ne(m, null, "conquest_town still loads")
	assert_gt(m.roads.size(), 0, "town still has its roads")
	assert_true(m.roads[0].has("min"), "town roads are still the legacy AABB form")
