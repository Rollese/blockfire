extends TestCase
## BuildingKit: procedural geometry for building piece types + rubble.

func _mesh_count(root: Node3D) -> int:
	var n := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D: n += 1
		for c in node.get_children(): stack.append(c)
	return n

func test_each_building_piece_builds_geometry() -> void:
	for id in ["bwall", "bwall_window", "bwall_door", "bfloor", "bstair", "bcolumn", "brailing", "prop_crate"]:
		assert_true(_mesh_count(BuildingKit.build(id, 3)) >= 1, "%s builds a mesh" % id)

func test_unknown_piece_falls_back() -> void:
	assert_true(BuildingKit.build("mystery", 3) is Node3D, "unknown id still builds")

func test_floor_skirt_adds_a_deck_slab() -> void:
	# The floor-skirt option drops one extra slab in the piece's own cell so a ground perimeter wall /
	# interior prop reads as standing on the floor (closes the floor-to-wall + under-prop gap).
	var plain := _mesh_count(BuildingKit.build("bwall", 3, false))
	var skirted := _mesh_count(BuildingKit.build("bwall", 3, true))
	assert_eq(skirted, plain + 1, "floor_skirt adds exactly one slab")

func test_each_prop_builds_geometry() -> void:
	# Regression: every interior prop must build real geometry in BuildingKit (the renderer routes all
	# prop_* here; StructureKit only knows wall/sandbag and would fall back to a 2.4 m concrete wall).
	for id in ["prop_crate", "prop_barrel", "prop_shelf", "prop_table", "prop_locker", "prop_chair"]:
		assert_true(_mesh_count(BuildingKit.build(id, 3)) >= 1, "%s builds a mesh" % id)

func test_rubble_builds() -> void:
	assert_true(_mesh_count(BuildingKit.build_rubble()) >= 1, "rubble has geometry")

func test_heavy_bucket_darker_than_pristine() -> void:
	var pv := _albedo(BuildingKit.build("bwall", 3))
	var hv := _albedo(BuildingKit.build("bwall", 0))
	assert_true(hv.v <= pv.v, "bucket 0 not brighter than bucket 3")

func _albedo(node: Node3D) -> Color:
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).material_override is StandardMaterial3D:
			return ((n as MeshInstance3D).material_override as StandardMaterial3D).albedo_color
		for c in n.get_children(): stack.append(c)
	return Color.BLACK
