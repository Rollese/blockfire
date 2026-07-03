extends TestCase

func _mesh_count(root: Node3D) -> int:
	var n := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			n += 1
		for c in node.get_children():
			stack.append(c)
	return n

func test_known_tree_loads_mesh() -> void:
	var node := SceneryKit.build("tree_type0_01")
	autofree(node)
	assert_true(node != null, "known tree id builds")
	assert_true(_mesh_count(node) >= 1, "tree has geometry")

func test_known_rock_loads_mesh() -> void:
	var node := SceneryKit.build("rock_type1_01")
	autofree(node)
	assert_true(node != null, "known rock id builds")
	assert_true(_mesh_count(node) >= 1, "rock has geometry")

func test_unknown_id_returns_null() -> void:
	assert_eq(SceneryKit.build("not_a_scenery_id"), null)

func test_map_palette_swaps_tree_colorsheet() -> void:
	var dry := SceneryKit.build("tree_type0_01", {"tree": "dry"})
	autofree(dry)
	assert_true(dry != null)
	assert_true(
		SceneryKit.albedo_texture_path(dry).ends_with("dry.png"),
		"map tree palette selects dry colorsheet")

func test_map_palette_swaps_rock_colorsheet() -> void:
	var sand := SceneryKit.build("rock_type1_01", {"rock": "sand"})
	autofree(sand)
	assert_true(sand != null)
	assert_true(
		SceneryKit.albedo_texture_path(sand).ends_with("sand.png"),
		"map rock palette selects sand colorsheet")

func test_empty_map_palette_uses_catalog_defaults() -> void:
	var tree := SceneryKit.build("tree_type0_01", {})
	autofree(tree)
	assert_true(SceneryKit.albedo_texture_path(tree).ends_with("normal.png"))

func test_instance_palette_overrides_map_default() -> void:
	var tree := SceneryKit.build("tree_type0_01", {"tree": "normal"}, "fall")
	autofree(tree)
	assert_true(SceneryKit.albedo_texture_path(tree).ends_with("fall.png"))

func test_instance_palette_overrides_only_its_category() -> void:
	var rock := SceneryKit.build("rock_type1_01", {"rock": "grey"}, "sand")
	autofree(rock)
	assert_true(SceneryKit.albedo_texture_path(rock).ends_with("sand.png"))

func test_storage_palette_applies() -> void:
	var barrel := SceneryKit.build("storage_barrel_01", {"storage": "red"})
	autofree(barrel)
	assert_true(SceneryKit.albedo_texture_path(barrel).ends_with("red.png"))

func test_prop_builds_without_palette_category() -> void:
	var prop := SceneryKit.build("prop_assaultrifleammo_box")
	autofree(prop)
	assert_true(prop != null)
	assert_true(_mesh_count(prop) >= 1)
