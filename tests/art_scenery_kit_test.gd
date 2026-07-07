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

# Trees/rocks are generated procedurally by TreeKit/RockKit, routed by id PREFIX (no GLB). The full
# geometry/material contract is covered in art_foliage_kit_test; here we only prove SceneryKit routes.
func _find(root: Node3D, pred: Callable) -> Node:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if pred.call(node):
			return node
		for c in node.get_children():
			stack.append(c)
	return null

func test_tree_id_builds_procedural_frond_tree() -> void:
	var tree := SceneryKit.build("tree_type0_01", {}, "", 7)
	autofree(tree)
	assert_true(tree != null, "tree id builds")
	assert_true(_mesh_count(tree) >= 1, "tree has geometry")
	var trunk := _find(tree, func(n): return n is MeshInstance3D and n.name == "trunk")
	assert_ne(trunk, null, "procedural tree has a trunk (TreeKit, not a GLB)")
	var frond := _find(tree, func(n): return n is MeshInstance3D and String(n.name).begins_with("frond"))
	assert_ne(frond, null, "procedural tree has frond planes")

func test_rock_id_builds_procedural_boulder() -> void:
	var rock := SceneryKit.build("rock_type1_01", {}, "", 4)
	autofree(rock)
	assert_true(rock != null, "rock id builds")
	var boulder := _find(rock, func(n): return n is MeshInstance3D and n.name == "boulder")
	assert_ne(boulder, null, "procedural rock is a RockKit boulder")

func test_tree_build_is_seed_deterministic() -> void:
	var a := SceneryKit.build("tree_type3_02", {}, "", 42)
	var b := SceneryKit.build("tree_type3_02", {}, "", 42)
	autofree(a); autofree(b)
	assert_eq(_mesh_count(a), _mesh_count(b), "same seed → same tree")

func test_unknown_id_returns_null() -> void:
	assert_eq(SceneryKit.build("not_a_scenery_id"), null)

func _first_override(root: Node3D) -> Material:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and (node as MeshInstance3D).material_override != null:
			return (node as MeshInstance3D).material_override
		for c in node.get_children():
			stack.append(c)
	return null

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
