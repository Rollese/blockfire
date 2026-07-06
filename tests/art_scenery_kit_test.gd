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

# The tree/rock GLBs import with no usable UVs, so neither their baked atlas nor a palette LUT maps
# (flat dark/grey/pink on every GPU - 2026-07-06 playtest). SceneryKit overrides tree + rock with a
# PROCEDURAL material (height-gradient foliage / mottled stone). Categories that DO texture correctly
# (storage/props) keep their own atlas + NEAREST filtering.
func _first_override(root: Node3D) -> Material:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and (node as MeshInstance3D).material_override != null:
			return (node as MeshInstance3D).material_override
		for c in node.get_children():
			stack.append(c)
	return null

func test_tree_gets_procedural_material() -> void:
	var tree := SceneryKit.build("tree_type0_01", {"tree": "dry"})
	autofree(tree)
	assert_true(tree != null)
	assert_true(_first_override(tree) is ShaderMaterial, "tree uses a procedural material override (not the broken atlas)")

func test_rock_gets_procedural_material() -> void:
	var rock := SceneryKit.build("rock_type1_01", {"rock": "sand"})
	autofree(rock)
	assert_true(rock != null)
	assert_true(_first_override(rock) is ShaderMaterial, "rock uses a procedural material override")

func test_non_tree_rock_scenery_builds() -> void:
	# Storage/other categories don't get the procedural override — they keep their own texture path.
	var barrel := SceneryKit.build("storage_barrel_01")
	autofree(barrel)
	assert_true(barrel != null and _mesh_count(barrel) >= 1, "storage prop builds with geometry")
	assert_false(_first_override(barrel) is ShaderMaterial, "non tree/rock scenery is NOT procedurally overridden")

func test_prop_builds_without_palette_category() -> void:
	var prop := SceneryKit.build("prop_assaultrifleammo_box")
	autofree(prop)
	assert_true(prop != null)
	assert_true(_mesh_count(prop) >= 1)
