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
