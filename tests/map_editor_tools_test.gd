extends TestCase
## Viewport interaction needs a live editor, so this covers the dock's PURE helpers: the ray/ground
## intersection maths and the document mutations the tools perform. Clicking is owner-gated.

const MapEditorDockScript := preload("res://addons/map_editor/ui/editor_dock.gd")
const MapDocument := preload("res://shared/mapedit/map_document.gd")
const MapValidator := preload("res://shared/mapedit/map_validator.gd")

func _doc() -> MapDocument:
	var d := MapDocument.from_dict({
		"name": "Tools", "world_half": 20.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 8.0}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
	}, "")
	d.cols = 21
	d.rows = 21
	d.sample_spacing = 2.0
	d.height_min = 0.0
	d.height_scale = 24.0
	d.heights.resize(441)
	d.heights.fill(0.5)
	return d

func test_ray_hits_the_ground_plane() -> void:
	# Straight down from 10 m up at (3, ?, -4) -> hits (3, -4).
	var hit := MapEditorDockScript.ray_to_ground(Vector3(3, 10, -4), Vector3(0, -1, 0), 0.0)
	assert_true(hit.has("hit"), "ray returns a result")
	assert_true(bool(hit["hit"]), "downward ray hits the ground plane")
	assert_almost_eq(float(hit["pos"].x), 3.0, 0.001, "x preserved")
	assert_almost_eq(float(hit["pos"].z), -4.0, 0.001, "z preserved")

func test_ray_parallel_to_ground_misses() -> void:
	var hit := MapEditorDockScript.ray_to_ground(Vector3(0, 10, 0), Vector3(1, 0, 0), 0.0)
	assert_false(bool(hit["hit"]), "a horizontal ray never hits the ground plane")

func test_ray_pointing_away_misses() -> void:
	var hit := MapEditorDockScript.ray_to_ground(Vector3(0, 10, 0), Vector3(0, 1, 0), 0.0)
	assert_false(bool(hit["hit"]), "an upward ray does not hit the ground below")

func test_snap_to_cell_grid() -> void:
	# Buildings are grid-snapped (BuildGrid.CELL_SIZE = 2.4).
	var c := MapEditorDockScript.snap_cell(Vector3(2.5, 0, -3.1))
	assert_eq(c.x, 1, "x snaps to cell 1 (2.5 / 2.4)")
	assert_eq(c.z, -2, "z snaps to cell -2 (-3.1 / 2.4 floors)")

func test_place_building_appends_to_doc() -> void:
	var d := _doc()
	MapEditorDockScript.doc_place_building(d, "cottage", Vector3i(2, 0, 3), 1)
	assert_eq(d.buildings.size(), 1, "building appended")
	assert_eq(String(d.buildings[0]["prefab"]), "cottage", "prefab recorded")
	assert_eq(d.buildings[0]["origin_cell"], Vector3i(2, 0, 3), "cell recorded")
	assert_eq(int(d.buildings[0]["yaw"]), 1, "yaw recorded")

func test_place_building_bakes_a_footprint() -> void:
	# Without a baked footprint the validator can only see ONE cell (so overlaps go undetected) and
	# terrain.gd flattens only one cell of the pad. Both are silent failures — hence this test.
	var d := _doc()
	MapEditorDockScript.doc_place_building(d, "cottage", Vector3i(0, 0, 0), 0)
	assert_true(d.buildings[0].has("footprint"), "footprint baked on placement")
	var f: Dictionary = d.buildings[0]["footprint"]
	assert_gt(float(f["max_x"]) - float(f["min_x"]), BuildGrid.CELL_SIZE, "footprint spans more than one cell")
	assert_gt(float(f["max_z"]) - float(f["min_z"]), 0.0, "footprint has depth")

func test_placed_buildings_overlap_is_caught_by_the_validator() -> void:
	# The end-to-end reason the footprint matters: two cottages on the same spot must be REPORTED.
	var d := _doc()
	MapEditorDockScript.doc_place_building(d, "cottage", Vector3i(0, 0, 0), 0)
	MapEditorDockScript.doc_place_building(d, "cottage", Vector3i(0, 0, 0), 0)
	var errs := MapValidator.check({"world_half": d.world_half, "buildings": d.buildings,
		"roads": d.roads, "points": d.points, "bases": d.bases})
	assert_gt(errs.size(), 0, "stacked buildings are reported")
	assert_contains(errs[0], "overlap", "reported as an overlap")

func test_unknown_prefab_places_without_a_footprint() -> void:
	var d := _doc()
	MapEditorDockScript.doc_place_building(d, "no_such_prefab", Vector3i(0, 0, 0), 0)
	assert_eq(d.buildings.size(), 1, "still placed (the owner may be mid-typing)")
	assert_false(d.buildings[0].has("footprint"), "no footprint for an unknown prefab, no crash")

func test_move_point_keeps_its_authored_height() -> void:
	var d := _doc()
	d.points[0]["pos"] = Vector3(0, 3.5, 0)
	MapEditorDockScript.doc_move_point(d, 0, Vector3(7, 99, -7))
	assert_almost_eq(d.points[0]["pos"].x, 7.0, 0.001, "x moved")
	assert_almost_eq(d.points[0]["pos"].z, -7.0, 0.001, "z moved")
	assert_almost_eq(d.points[0]["pos"].y, 3.5, 0.001, "y is NOT taken from the click ray")

func test_move_base_moves_the_right_base() -> void:
	var d := _doc()
	MapEditorDockScript.doc_move_base(d, 1, Vector3(4, 0, 12))
	assert_almost_eq(d.bases[1]["pos"].x, 4.0, 0.001, "base 1 moved")
	assert_almost_eq(d.bases[0]["pos"].z, -15.0, 0.001, "base 0 untouched")

func test_add_point_ids_follow_the_map_convention() -> void:
	var d := _doc()   # already has point "A"
	MapEditorDockScript.doc_add_point(d, Vector3(5, 0, 5), 12.0)
	assert_eq(d.points.size(), 2, "point added")
	assert_eq(String(d.points[1]["id"]), "B", "ids run A, B, C… like the shipping maps")
	assert_eq(int(d.points[1]["start_owner"]), -1, "new points start neutral")

func test_set_point_radius_rejects_zero() -> void:
	var d := _doc()
	MapEditorDockScript.doc_set_point_radius(d, 0, 0.0)
	assert_gt(float(d.points[0]["radius"]), 0.0, "a zero radius is clamped (MapDef would reject the map)")

func test_marker_ops_ignore_a_bad_index() -> void:
	var d := _doc()
	MapEditorDockScript.doc_move_point(d, 99, Vector3(1, 0, 1))
	MapEditorDockScript.doc_move_base(d, -1, Vector3(1, 0, 1))
	assert_eq(d.points.size(), 1, "out-of-range marker ops are no-ops, not crashes")

func test_erase_building_by_index() -> void:
	var d := _doc()
	MapEditorDockScript.doc_place_building(d, "cottage", Vector3i(0, 0, 0), 0)
	MapEditorDockScript.doc_place_building(d, "barn", Vector3i(5, 0, 5), 0)
	MapEditorDockScript.doc_erase_building(d, 0)
	assert_eq(d.buildings.size(), 1, "one removed")
	assert_eq(String(d.buildings[0]["prefab"]), "barn", "the right one survived")

func test_place_prop_appends_free_transform() -> void:
	var d := _doc()
	MapEditorDockScript.doc_place_prop(d, "tree_type3_02", Vector3(1.3, 0, -2.7), 0.5, 1.2)
	assert_eq(d.scenery.size(), 1, "prop appended")
	assert_almost_eq(float(d.scenery[0]["scale"]), 1.2, 0.001, "scale recorded")
	# Props are free-placed (NOT grid-snapped) — that is the difference from buildings.
	assert_almost_eq(float(d.scenery[0]["pos"].x), 1.3, 0.001, "x is not snapped")

func test_add_road_point_builds_a_spline() -> void:
	var d := _doc()
	MapEditorDockScript.doc_add_road_point(d, 0, Vector2(-10, 0), 8.0)
	MapEditorDockScript.doc_add_road_point(d, 0, Vector2(10, 0), 8.0)
	assert_eq(d.roads.size(), 1, "one road")
	assert_eq((d.roads[0]["spline"] as PackedVector2Array).size(), 2, "two control points")
	assert_almost_eq(float(d.roads[0]["width"]), 8.0, 0.001, "width recorded")

func test_sculpt_mutates_the_heightmap() -> void:
	var d := _doc()
	var before := d.heights[10 * 21 + 10]   # centre sample = world (0,0)
	MapEditorDockScript.doc_sculpt(d, Vector2(0, 0), 6.0, 1.0, 0)   # 0 = TerrainBrush.Mode.RAISE
	assert_gt(d.heights[10 * 21 + 10], before, "centre sample raised")

func test_sculpt_stays_normalised() -> void:
	# Heights are stored 0..1; a big stroke must CLAMP, not blow past the encodable range.
	var d := _doc()
	for i in 20:
		MapEditorDockScript.doc_sculpt(d, Vector2(0, 0), 6.0, 5.0, 0)
	assert_true(d.heights[10 * 21 + 10] <= 1.0, "sculpt clamps at 1.0 (stays encodable)")
	for i in 60:
		MapEditorDockScript.doc_sculpt(d, Vector2(0, 0), 6.0, 5.0, 1)   # 1 = LOWER
	assert_true(d.heights[10 * 21 + 10] >= 0.0, "sculpt clamps at 0.0")
