extends TestCase

func test_loads_shipped_catalog() -> void:
	var c := SceneryCatalog.load_file("res://data/scenery_catalog.json")
	assert_true(c != null, "catalog loads")
	assert_true(c.has_id("tree_type0_01"), "has a tree")
	assert_true(c.has_id("rock_type1_01"), "has a rock")
	assert_true(c.path_for("tree_type0_01").begins_with("res://assets/environment/"))

func test_rejects_empty_items() -> void:
	var res := SceneryCatalog.from_dict({"items": {}})
	assert_false(res["ok"])

func test_rejects_missing_path() -> void:
	var res := SceneryCatalog.from_dict({"items": {"x": {"id": "x"}}})
	assert_false(res["ok"])
