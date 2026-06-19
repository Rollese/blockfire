extends TestCase
## BuildingCatalog: parse + validate a prefab {name, pieces:[{type, offset, yaw, structural?}]}.

func _cat() -> PieceCatalog:
	return PieceCatalog.load_file("res://pieces/pieces.json")

func test_valid_prefab_parses_pieces() -> void:
	var res := BuildingCatalog.from_dict({
		"name": "t",
		"pieces": [{"type": "bwall", "offset": [0, 0, 0], "yaw": 0},
				   {"type": "bcolumn", "offset": [1, 0, 0], "yaw": 2}]
	}, _cat())
	assert_true(res["ok"], "valid prefab ok")
	var p = res["prefab"]
	assert_eq(p["name"], "t", "name kept")
	assert_eq(p["pieces"].size(), 2, "two pieces")
	assert_eq(p["pieces"][1]["offset"], Vector3i(1, 0, 0), "offset is Vector3i")
	assert_eq(p["pieces"][1]["yaw"], 2, "yaw kept")

func test_unknown_piece_type_rejected() -> void:
	var res := BuildingCatalog.from_dict({"name": "t", "pieces": [{"type": "nope", "offset": [0,0,0], "yaw": 0}]}, _cat())
	assert_false(res["ok"], "unknown type rejected")

func test_bad_offset_rejected() -> void:
	var res := BuildingCatalog.from_dict({"name": "t", "pieces": [{"type": "bwall", "offset": [0,0], "yaw": 0}]}, _cat())
	assert_false(res["ok"], "non-3 offset rejected")

func test_empty_pieces_rejected() -> void:
	var res := BuildingCatalog.from_dict({"name": "t", "pieces": []}, _cat())
	assert_false(res["ok"], "empty prefab rejected")

func test_missing_name_rejected() -> void:
	var res := BuildingCatalog.from_dict({"pieces": [{"type": "bwall", "offset": [0,0,0], "yaw": 0}]}, _cat())
	assert_false(res["ok"], "missing name rejected")

func test_yaw_out_of_range_rejected() -> void:
	var res := BuildingCatalog.from_dict({"name": "t", "pieces": [{"type": "bwall", "offset": [0,0,0], "yaw": 99}]}, _cat())
	assert_false(res["ok"], "yaw 99 rejected")

func test_non_numeric_offset_rejected() -> void:
	var res := BuildingCatalog.from_dict({"name": "t", "pieces": [{"type": "bwall", "offset": ["x","y","z"], "yaw": 0}]}, _cat())
	assert_false(res["ok"], "non-numeric offset rejected")

func test_structural_defaults_from_catalog_and_overrides() -> void:
	# brailing is non-structural in the catalog; explicit override to true must win.
	var res := BuildingCatalog.from_dict({"name": "t", "pieces": [
		{"type": "bwall", "offset": [0,0,0], "yaw": 0},
		{"type": "brailing", "offset": [1,0,0], "yaw": 0, "structural": true}
	]}, _cat())
	assert_true(res["ok"], "ok")
	assert_true(res["prefab"]["pieces"][0]["structural"], "bwall defaults structural=true from catalog")
	assert_true(res["prefab"]["pieces"][1]["structural"], "explicit structural=true overrides catalog false")

func test_shipped_prefabs_load() -> void:
	for name in ["bunker", "house", "tower"]:
		var res := BuildingCatalog.load_file("res://buildings/%s.json" % name, _cat())
		assert_true(res["ok"], "%s loads: %s" % [name, res["error"]])
		assert_true(res["prefab"]["pieces"].size() >= 4, "%s has pieces" % name)

func test_tower_loads_with_structural_walls() -> void:
	# Tower redesign: a tall walled box (perimeter walls, no bare columns).
	var res := BuildingCatalog.load_file("res://buildings/tower.json", _cat())
	var walls := 0
	for p in res["prefab"]["pieces"]:
		if _cat().name_of(p["type"]) in ["bwall", "bwall_window", "bwall_door"]:
			walls += 1
	assert_true(walls >= 8, "tower is enclosed by structural walls")
