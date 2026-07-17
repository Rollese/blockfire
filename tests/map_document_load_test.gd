extends TestCase
const MapDocument := preload("res://shared/mapedit/map_document.gd")

func test_load_real_town_map() -> void:
	var doc := MapDocument.load_from("res://maps/conquest_town.json")
	assert_ne(doc, null, "conquest_town loads")
	assert_eq(doc.map_name, "Town", "name read")
	assert_almost_eq(doc.world_half, 170.0, 0.001, "world_half read")
	assert_gt(doc.buildings.size(), 0, "buildings read")
	assert_gt(doc.points.size(), 0, "points read")
	assert_eq(doc.bases.size(), 2, "both bases read")
	assert_gt(doc.scenery.size(), 0, "scenery read")

func test_load_reads_the_heightmap() -> void:
	var doc := MapDocument.load_from("res://maps/conquest_town.json")
	assert_gt(doc.heights.size(), 0, "heightmap samples loaded")
	assert_eq(doc.heights.size(), doc.cols * doc.rows, "sample count matches dims")
	assert_almost_eq(doc.sample_spacing, 2.0, 0.001, "spacing read from terrain block")
	assert_almost_eq(doc.height_scale, 24.0, 0.001, "height_scale read")

func test_heights_are_normalised_0_to_1() -> void:
	var doc := MapDocument.load_from("res://maps/conquest_town.json")
	var lo := INF
	var hi := -INF
	for h in doc.heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	assert_true(lo >= 0.0 and lo <= 1.0, "min sample %f is normalised" % lo)
	assert_true(hi >= 0.0 and hi <= 1.0, "max sample %f is normalised" % hi)

func test_unknown_keys_are_preserved() -> void:
	# The editor must never silently drop data it does not understand.
	var doc := MapDocument.from_dict({
		"name": "X", "world_half": 50.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 5.0}],
		"bases": [{"team": 0, "pos": [0, 0, -40]}, {"team": 1, "pos": [0, 0, 40]}],
		"some_future_key": {"a": 1},
	}, "")
	assert_true(doc.extra.has("some_future_key"), "unknown top-level key kept for round-trip")

func test_flat_map_without_terrain_loads() -> void:
	var doc := MapDocument.from_dict({
		"name": "Flat", "world_half": 50.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 5.0}],
		"bases": [{"team": 0, "pos": [0, 0, -40]}, {"team": 1, "pos": [0, 0, 40]}],
	}, "")
	assert_ne(doc, null, "a flat (terrain-less) map loads")
	assert_eq(doc.heights.size(), 0, "no terrain -> no heightmap samples")

func test_load_missing_file_returns_null() -> void:
	tolerate_runtime_errors()
	assert_eq(MapDocument.load_from("res://maps/does_not_exist.json"), null, "missing map -> null, no crash")
