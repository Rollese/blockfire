extends TestCase
## Procedural building materials must use NEAREST texture filtering for the game-wide pixel-cutout
## look (matching the foliage/rock kits). Headless-safe — asserts material properties only, never
## rendered pixels (AGENTS.md §10). Builds pieces via BuildingKit.build (the renderer's entry point).

func _descendants(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

func _textured_mats(root: Node) -> Array:
	# Every material_override that actually carries an albedo_texture (the ones _box/_cyl set a tex on).
	var out: Array = []
	for n in _descendants(root):
		if n is MeshInstance3D:
			var m := (n as MeshInstance3D).material_override
			if m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture != null:
				out.append(m)
	return out

func test_box_wall_material_is_nearest() -> void:
	# bwall_brick -> a single textured box ("brick").
	var piece := BuildingKit.build("bwall_brick", 3)
	autofree(piece)
	var mats := _textured_mats(piece)
	assert_gt(mats.size(), 0, "brick wall has a textured material")
	for m in mats:
		assert_eq((m as BaseMaterial3D).texture_filter,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST, "textured wall material uses NEAREST")

func test_cylinder_prop_material_is_nearest() -> void:
	# prop_barrel -> a _cyl with a "metal" texture (the second albedo_texture assignment).
	var piece := BuildingKit.build("prop_barrel", 3)
	autofree(piece)
	var mats := _textured_mats(piece)
	assert_gt(mats.size(), 0, "barrel has a textured material")
	for m in mats:
		assert_eq((m as BaseMaterial3D).texture_filter,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST, "textured barrel material uses NEAREST")
