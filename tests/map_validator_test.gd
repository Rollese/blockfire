extends TestCase
const MapValidator := preload("res://shared/mapedit/map_validator.gd")

func _doc(buildings: Array, roads: Array = [], points: Array = []) -> Dictionary:
	return {
		"world_half": 100.0,
		"buildings": buildings,
		"roads": roads,
		"points": points if not points.is_empty() else [{"id": "A", "pos": Vector3(0, 0, 0), "radius": 15.0}],
		"bases": [{"team": 0, "pos": Vector3(0, 0, -80), "radius": 20.0}, {"team": 1, "pos": Vector3(0, 0, 80), "radius": 20.0}],
	}

func _b(name: String, x0: float, z0: float, x1: float, z1: float) -> Dictionary:
	return {"prefab": name, "origin_cell": Vector3i(0, 0, 0),
		"footprint": {"min_x": x0, "max_x": x1, "min_z": z0, "max_z": z1}}

func test_clean_map_has_no_errors() -> void:
	var errs := MapValidator.check(_doc([_b("a", -20, -20, -10, -10), _b("b", 10, 10, 20, 20)]))
	assert_eq(errs.size(), 0, "non-overlapping buildings inside bounds are clean: %s" % str(errs))

func test_overlapping_buildings_are_reported() -> void:
	var errs := MapValidator.check(_doc([_b("a", -20, -20, 0, 0), _b("b", -5, -5, 10, 10)]))
	assert_eq(errs.size(), 1, "one overlap reported: %s" % str(errs))
	assert_contains(errs[0], "overlap", "message says overlap")
	assert_contains(errs[0], "a", "message names the first building")

func test_touching_buildings_are_not_an_overlap() -> void:
	# Shared edge = terraced housing, not a bug.
	var errs := MapValidator.check(_doc([_b("a", -20, -20, 0, 0), _b("b", 0, -20, 20, 0)]))
	assert_eq(errs.size(), 0, "edge-to-edge buildings are legal: %s" % str(errs))

func test_building_out_of_bounds_is_reported() -> void:
	var errs := MapValidator.check(_doc([_b("a", 90, 90, 130, 130)]))
	assert_gt(errs.size(), 0, "a building past world_half is reported")
	assert_contains(errs[0], "bounds", "message says bounds")

func test_building_on_an_aabb_road_is_reported() -> void:
	var errs := MapValidator.check(
		_doc([_b("a", -5, -5, 5, 5)], [{"min": Vector3(-6, 0, -60), "max": Vector3(6, 0, 60)}]))
	assert_gt(errs.size(), 0, "a building sitting on a road is reported")
	assert_contains(errs[0], "road", "message says road")

func test_building_on_a_spline_road_is_reported() -> void:
	var errs := MapValidator.check(
		_doc([_b("a", -4, -4, 4, 4)], [{"spline": PackedVector2Array([Vector2(-50, 0), Vector2(50, 0)]), "width": 8.0}]))
	assert_gt(errs.size(), 0, "a building on a spline road corridor is reported")
	assert_contains(errs[0], "road", "message says road")

func test_building_clear_of_a_spline_road_is_clean() -> void:
	var errs := MapValidator.check(
		_doc([_b("a", -4, 30, 4, 40)], [{"spline": PackedVector2Array([Vector2(-50, 0), Vector2(50, 0)]), "width": 8.0}]))
	assert_eq(errs.size(), 0, "a building well off the road is clean: %s" % str(errs))

func test_point_out_of_bounds_is_reported() -> void:
	var errs := MapValidator.check(_doc([], [], [{"id": "A", "pos": Vector3(200, 0, 0), "radius": 15.0}]))
	assert_gt(errs.size(), 0, "a capture point outside the map is reported")
	assert_contains(errs[0], "A", "message names the point")

func test_zero_radius_point_is_reported() -> void:
	var errs := MapValidator.check(_doc([], [], [{"id": "B", "pos": Vector3(0, 0, 0), "radius": 0.0}]))
	assert_gt(errs.size(), 0, "a zero-radius point is reported")

func test_missing_team_base_is_reported() -> void:
	var d := _doc([])
	d["bases"] = [{"team": 0, "pos": Vector3(0, 0, -80), "radius": 20.0}]
	var errs := MapValidator.check(d)
	assert_gt(errs.size(), 0, "a map missing team 1's base is reported")
	assert_contains(errs[0], "base", "message says base")

func test_no_points_is_reported() -> void:
	var d := _doc([])
	d["points"] = []
	var errs := MapValidator.check(d)
	assert_gt(errs.size(), 0, "a map with no capture points is reported")
