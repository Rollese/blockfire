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
