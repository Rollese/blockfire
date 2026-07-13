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
		assert_true(_mesh_count(autofree(BuildingKit.build(id, 3))) >= 1, "%s builds a mesh" % id)

func test_unknown_piece_falls_back() -> void:
	assert_true(autofree(BuildingKit.build("mystery", 3)) is Node3D, "unknown id still builds")

func test_floor_skirt_adds_a_deck_slab() -> void:
	# The floor-skirt option drops one extra slab in the piece's own cell so a ground perimeter wall /
	# interior prop reads as standing on the floor (closes the floor-to-wall + under-prop gap).
	var plain := _mesh_count(autofree(BuildingKit.build("bwall", 3, false)))
	var skirted := _mesh_count(autofree(BuildingKit.build("bwall", 3, true)))
	assert_eq(skirted, plain + 1, "floor_skirt adds exactly one slab")

func test_each_prop_builds_geometry() -> void:
	# Regression: every interior prop must build real geometry in BuildingKit (the renderer routes all
	# prop_* here; StructureKit only knows wall/sandbag and would fall back to a 2.4 m concrete wall).
	for id in ["prop_crate", "prop_barrel", "prop_shelf", "prop_table", "prop_locker", "prop_chair"]:
		assert_true(_mesh_count(autofree(BuildingKit.build(id, 3))) >= 1, "%s builds a mesh" % id)

func test_rubble_builds() -> void:
	assert_true(_mesh_count(autofree(BuildingKit.build_rubble())) >= 1, "rubble has geometry")

func test_heavy_bucket_darker_than_pristine() -> void:
	var pv := _albedo(autofree(BuildingKit.build("bwall", 3)))
	var hv := _albedo(autofree(BuildingKit.build("bwall", 0)))
	assert_true(hv.v <= pv.v, "bucket 0 not brighter than bucket 3")

func test_corner_is_l_not_centred_cross() -> void:
	var root: Node3D = autofree(BuildingKit.build("bwall_corner", 3, false, 0))
	var names: Array[String] = []
	for c in root.get_children():
		if c is MeshInstance3D:
			names.append(c.name)
	# Two edge arms (an L) — plus quoin relief up the corner edge. NOT a centred cross slab.
	var arms := 0
	for nm in names:
		if nm.begins_with("Arm"):
			arms += 1
	assert_eq(arms, 2, "corner is two edge arms")
	assert_true("ArmS" in names or "ArmN" in names, "has a span arm")
	assert_false("CornX" in names, "no centred cross slab")

func test_roof_floor_slab_inset_prevents_wall_zfight() -> void:
	# Anti-z-fight guard (Z1): the bfloor deck slab must be strictly narrower than a full cell in X and Z
	# so its outer vertical edges sit INSIDE the full-cell wall exterior faces below it, instead of exactly
	# coplanar (which dithered a band under the roof soffit). Mesh-only — collision stays server-side.
	var root: Node3D = autofree(BuildingKit.build("bfloor", 3))
	var slab := _find_mesh(root, "Floor")
	assert_true(slab != null, "bfloor builds a Floor slab")
	var sz := (slab.mesh as BoxMesh).size
	assert_true(sz.x < BuildingKit.CELL - 0.001, "floor slab X inset below full cell")
	assert_true(sz.z < BuildingKit.CELL - 0.001, "floor slab Z inset below full cell")
	# Keep the seam invisible: inset must stay small (no visible gap to adjacent decks).
	assert_true(sz.x >= BuildingKit.CELL - 0.1, "floor slab inset stays small (no visible floor gap)")

func test_floor_skirt_slab_inset_prevents_wall_zfight() -> void:
	# Same Z1 guard for the floor-skirt variant: the "Skirt" deck it drops under a ground perimeter wall /
	# interior prop must carry the identical inset so its outer edges clear the full-cell wall exterior
	# faces (else the coplanar band reappears on ground-floor perimeters). Mesh-only — collision server-side.
	var root: Node3D = autofree(BuildingKit.build("bwall", 3, true))
	var skirt := _find_mesh(root, "Skirt")
	assert_true(skirt != null, "floor_skirt builds a Skirt slab")
	var sz := (skirt.mesh as BoxMesh).size
	assert_true(sz.x < BuildingKit.CELL - 0.001, "skirt slab X inset below full cell")
	assert_true(sz.z < BuildingKit.CELL - 0.001, "skirt slab Z inset below full cell")
	assert_true(sz.x >= BuildingKit.CELL - 0.1, "skirt slab inset stays small (no visible floor gap)")

func _find_mesh(root: Node3D, mesh_name: String) -> MeshInstance3D:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and n.name == mesh_name:
			return n
		for c in n.get_children(): stack.append(c)
	return null

func _albedo(node: Node3D) -> Color:
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).material_override is StandardMaterial3D:
			return ((n as MeshInstance3D).material_override as StandardMaterial3D).albedo_color
		for c in n.get_children(): stack.append(c)
	return Color.BLACK
