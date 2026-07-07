extends TestCase

func test_loads_shipped_catalog() -> void:
	var c := SceneryCatalog.load_file("res://data/scenery_catalog.json")
	assert_true(c != null, "catalog loads")
	# Trees/rocks are procedural now (TreeKit/RockKit, routed by id prefix) — no longer in the catalog.
	assert_false(c.has_id("tree_type0_01"), "trees are NOT in the catalog (procedural)")
	assert_false(c.has_id("rock_type1_01"), "rocks are NOT in the catalog (procedural)")
	assert_true(c.has_id("cliff_clifftile_concave"), "has a cliff tile")
	assert_true(c.has_id("road_freeway_straight_1"), "has a road piece")
	assert_true(c.has_id("storage_barrel_01"), "has storage prop")
	assert_true(c.has_id("vehicle_static_car_1"), "has static vehicle")
	assert_true(c.has_id("prop_assaultrifleammo_box"), "has weapon ammo prop")
	assert_true(c.path_for("cliff_clifftile_concave").begins_with("res://assets/environment/"))
	assert_eq(c.default_palette_for("cliff"), "grey")
	assert_eq(c.default_palette_for("storage"), "blue")
	assert_true(c.has_palette("vehicle_static", "silver"))

func test_rejects_empty_items() -> void:
	var res := SceneryCatalog.from_dict({"items": {}})
	assert_false(res["ok"])

func test_rejects_missing_path() -> void:
	var res := SceneryCatalog.from_dict({"items": {"x": {"id": "x"}}})
	assert_false(res["ok"])

func test_rejects_non_object_palette_group() -> void:
	var res := SceneryCatalog.from_dict({
		"items": {"t": {"id": "t", "path": "res://x.glb"}},
		"palettes": {"tree": []},
	})
	assert_false(res["ok"])
