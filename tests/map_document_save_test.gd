extends TestCase
const MapDocument := preload("res://shared/mapedit/map_document.gd")
const MapEditorDock := preload("res://addons/map_editor/ui/editor_dock.gd")

const TMP := "user://m22_map_document_save_test"

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(TMP.path_join("heightmaps"))

func teardown() -> void:
	for sub in ["heightmaps", ""]:
		var d := DirAccess.open(TMP.path_join(sub))
		if d != null:
			d.list_dir_begin()
			var f := d.get_next()
			while f != "":
				if not d.current_is_dir():
					d.remove(TMP.path_join(sub).path_join(f))
				f = d.get_next()
			d.list_dir_end()

func _fixture() -> MapDocument:
	var doc := MapDocument.from_dict({
		"name": "Saveme", "world_half": 20.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 8.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
		"buildings": [{"prefab": "cottage", "origin_cell": [0, 0, 0], "yaw": 0}],
		"roads": [{"spline": [[-15, 0], [15, 0]], "width": 8.0}],
		"custom_future_key": 42,
	}, "")
	doc.source_path = TMP.path_join("saveme.json")
	doc.base_dir = TMP
	# 21x21 terrain for world_half 20 @ spacing 2
	doc.cols = 21
	doc.rows = 21
	doc.sample_spacing = 2.0
	doc.height_min = -10.0
	doc.height_scale = 24.0
	doc.heightmap_rel = "heightmaps/saveme.exr"
	doc.heights.resize(441)
	for i in 441:
		doc.heights[i] = 0.4 + float(i) * 0.0001
	return doc

func test_save_writes_json_and_heightmap() -> void:
	var doc := _fixture()
	assert_eq(doc.save(), OK, "save succeeds")
	assert_true(FileAccess.file_exists(TMP.path_join("saveme.json")), "json written")
	assert_true(FileAccess.file_exists(TMP.path_join("heightmaps/saveme.exr")), "EXR heightmap written")

func test_saved_map_parses_as_a_valid_mapdef() -> void:
	# THE BAR: the game must be able to load what the editor saves.
	var doc := _fixture()
	doc.save()
	var text := FileAccess.get_file_as_string(TMP.path_join("saveme.json"))
	var res := MapDef.from_json_string(text)
	assert_true(res["ok"], "editor output is a valid MapDef: %s" % res["error"])
	assert_eq(res["map"].roads.size(), 1, "spline road survived")
	assert_true(res["map"].roads[0].has("spline"), "road round-tripped as a spline")

func test_round_trip_is_stable() -> void:
	var doc := _fixture()
	doc.save()
	var again := MapDocument.load_from(TMP.path_join("saveme.json"))
	assert_ne(again, null, "reload succeeds")
	assert_eq(again.map_name, doc.map_name, "name stable")
	assert_almost_eq(again.world_half, doc.world_half, 0.001, "world_half stable")
	assert_eq(again.buildings.size(), doc.buildings.size(), "buildings stable")
	assert_eq(again.points.size(), doc.points.size(), "points stable")
	assert_eq(again.roads.size(), doc.roads.size(), "roads stable")
	assert_eq(again.cols, doc.cols, "terrain cols stable")
	assert_eq(again.rows, doc.rows, "terrain rows stable")

func test_heights_survive_the_round_trip_exactly() -> void:
	# The whole point of EXR: sub-8-bit-quantum detail must survive a save/load cycle.
	var doc := _fixture()
	doc.save()
	var again := MapDocument.load_from(TMP.path_join("saveme.json"))
	var worst := 0.0
	for i in doc.heights.size():
		worst = maxf(worst, absf(again.heights[i] - doc.heights[i]))
	assert_true(worst < 0.0001, "heights round-trip within %f (EXR is lossless)" % worst)
	# Same data through the OLD 8-bit path would have collapsed these 0.0001 steps entirely.
	assert_true(absf(again.heights[1] - again.heights[0]) > 0.00005, "a sub-8-bit step survived")

func test_unknown_keys_survive_the_round_trip() -> void:
	var doc := _fixture()
	doc.save()
	var text := FileAccess.get_file_as_string(TMP.path_join("saveme.json"))
	var data: Dictionary = JSON.parse_string(text)
	assert_true(data.has("custom_future_key"), "unknown key written back")
	assert_eq(int(data["custom_future_key"]), 42, "unknown key value intact")

func test_save_double_round_trip_is_idempotent() -> void:
	var doc := _fixture()
	doc.save()
	var first := FileAccess.get_file_as_string(TMP.path_join("saveme.json"))
	var again := MapDocument.load_from(TMP.path_join("saveme.json"))
	again.save()
	var second := FileAccess.get_file_as_string(TMP.path_join("saveme.json"))
	assert_eq(first, second, "load->save->load->save produces byte-identical JSON (no drift)")

func test_editor_placed_vectors_survive_save_and_runtime_load() -> void:
	# THE BAR: content placed the way the editor places it (origin_cell as Vector3i,
	# prop pos as Vector3) must survive save() and reload through the runtime parser.
	# Before the fix, JSON.stringify emitted those vectors as "(x, y, z)" STRINGS, which
	# map_def.gd rejects (origin_cell/pos must each be a 3-element Array).
	var doc := _fixture()
	MapEditorDock.doc_place_building(doc, "cottage", Vector3i(3, 0, 5), 2)
	MapEditorDock.doc_place_prop(doc, "tree_type3_02", Vector3(10.0, 0.0, 12.0), 0.0, 1.0)
	assert_eq(doc.save(), OK, "editor-authored map saves")

	var text := FileAccess.get_file_as_string(TMP.path_join("saveme.json"))
	var res := MapDef.from_json_string(text)
	assert_true(res["ok"], "editor-placed building/prop load as a valid MapDef: %s" % res["error"])
	var map = res["map"]
	# Prove the actual values survived, not merely that it parsed.
	var placed: Dictionary = map.buildings[map.buildings.size() - 1]
	assert_eq(placed["origin_cell"], Vector3i(3, 0, 5), "building origin_cell survives as Vector3i(3,0,5)")
	var prop: Dictionary = map.scenery[map.scenery.size() - 1]
	assert_true(prop["pos"].distance_to(Vector3(10.0, 0.0, 12.0)) < 0.001,
		"prop pos survives as Vector3(10,0,12), got %s" % str(prop["pos"]))

func test_saving_a_flat_map_omits_terrain() -> void:
	var doc := MapDocument.from_dict({
		"name": "Flat", "world_half": 20.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 8.0}],
		"bases": [{"team": 0, "pos": [0, 0, -15]}, {"team": 1, "pos": [0, 0, 15]}],
	}, "")
	doc.source_path = TMP.path_join("flat.json")
	doc.base_dir = TMP
	assert_eq(doc.save(), OK, "flat map saves")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TMP.path_join("flat.json")))
	assert_false(data.has("terrain"), "a map with no heightmap writes no terrain block")
