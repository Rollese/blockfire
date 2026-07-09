extends TestCase
## MeshMerge: collapses a TreeKit tree's ~50 discrete MeshInstance3D nodes into one merged instance per
## material (draw-call optimiser). Must preserve geometry (triangle count + bounds) and the exact
## materials (so the pixel-cutout / NEAREST / double-sided foliage look is untouched). Headless-safe —
## asserts mesh/material structure, never rendered pixels (AGENTS.md §10).

func setup() -> void:
	TreeKit.reset_cache_for_tests()

func _mesh_instances(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and not (n as Node).is_queued_for_deletion():
			out.append(n)
		for c in n.get_children():
			if not (c as Node).is_queued_for_deletion():
				stack.append(c)
	return out

func _total_tris(root: Node) -> int:
	var t := 0
	for mi in _mesh_instances(root):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh != null:
			t += mesh.get_faces().size() / 3
	return t

func _material_ids(root: Node) -> Dictionary:
	var ids := {}
	for mi in _mesh_instances(root):
		var m: Material = (mi as MeshInstance3D).material_override
		if m != null:
			ids[m.get_instance_id()] = true
	return ids

func test_merge_collapses_tree_to_few_instances() -> void:
	var tree: Node3D = autofree(TreeKit.build(1))
	var before := _mesh_instances(tree).size()
	assert_gt(before, 20, "a raw tree is dozens of separate MeshInstances")
	MeshMerge.merge_by_material(tree)
	var after := _mesh_instances(tree).size()
	assert_true(after < before, "merge reduces the instance count")
	# One instance per distinct material (4 leaf variants + 1 bark = at most 5, fewer if a variant is
	# absent for this seed). Never more than a handful.
	assert_true(after <= 6, "merged tree is a handful of instances, not dozens")

func test_merge_preserves_triangle_count() -> void:
	var tree: Node3D = autofree(TreeKit.build(3))
	var before := _total_tris(tree)
	assert_gt(before, 0, "tree has geometry")
	MeshMerge.merge_by_material(tree)
	assert_eq(_total_tris(tree), before, "merge is loss-less: same triangle count")

func test_merge_preserves_material_set() -> void:
	var tree: Node3D = autofree(TreeKit.build(2))
	var before := _material_ids(tree)
	MeshMerge.merge_by_material(tree)
	var after := _material_ids(tree)
	assert_eq(after.size(), before.size(), "same distinct materials after merge")
	for k in before:
		assert_true(after.has(k), "each original material survives the merge")

func test_merge_keeps_cutout_leaf_material() -> void:
	# The whole foliage look rides on the leaf material's flags — they must survive on the merged node.
	var tree: Node3D = autofree(TreeKit.build(2))
	MeshMerge.merge_by_material(tree)
	var leaf: StandardMaterial3D = null
	for mi in _mesh_instances(tree):
		var m := (mi as MeshInstance3D).material_override
		if m is StandardMaterial3D and (m as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			leaf = m
			break
	assert_ne(leaf, null, "a merged instance still carries the alpha-cutout leaf material")
	assert_eq(leaf.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "leaves stay NEAREST (pixelated)")
	assert_eq(leaf.cull_mode, BaseMaterial3D.CULL_DISABLED, "leaf cards stay double-sided")

func test_merge_preserves_bounds() -> void:
	# Merged geometry occupies the same world volume (append_from bakes each node's transform in).
	var tree: Node3D = autofree(TreeKit.build(4))
	var before := _world_aabb(tree)
	MeshMerge.merge_by_material(tree)
	var after := _world_aabb(tree)
	assert_almost_eq(after.position.y, before.position.y, 0.05, "same base height")
	assert_almost_eq(after.size.y, before.size.y, 0.05, "same overall height")
	assert_almost_eq(after.size.x, before.size.x, 0.1, "same canopy spread (x)")
	assert_almost_eq(after.size.z, before.size.z, 0.1, "same canopy spread (z)")

func _world_aabb(root: Node) -> AABB:
	var acc := AABB()
	var first := true
	for mi in _mesh_instances(root):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		# AABB of this mesh in the tree-root frame.
		var box := _xform_aabb(m.transform, m.mesh.get_aabb())
		if first:
			acc = box
			first = false
		else:
			acc = acc.merge(box)
	return acc

func _xform_aabb(t: Transform3D, box: AABB) -> AABB:
	# Transform the 8 corners and rebuild an axis-aligned box (Godot's AABB has no xform helper here).
	var out := AABB(t * box.position, Vector3.ZERO)
	for i in range(1, 8):
		var corner := box.position + Vector3(
			box.size.x if (i & 1) else 0.0,
			box.size.y if (i & 2) else 0.0,
			box.size.z if (i & 4) else 0.0)
		out = out.expand(t * corner)
	return out

func test_merge_on_empty_node_is_safe() -> void:
	var n: Node3D = autofree(Node3D.new())
	MeshMerge.merge_by_material(n)
	assert_eq(_mesh_instances(n).size(), 0, "no instances, no crash")
	MeshMerge.merge_by_material(null)  # null is a no-op, not a crash
	assert_true(true, "null root tolerated")
