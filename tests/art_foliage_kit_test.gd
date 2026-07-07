extends TestCase
## PROTOTYPE TreeKit / RockKit: geometry + the material contract that makes the pixelated-foliage look
## work (alpha-CUTOUT leaves, NEAREST filtering). Headless-safe — asserts mesh/material structure, never
## rendered pixels (AGENTS.md §10).

func setup() -> void:
	TreeKit.reset_cache_for_tests()
	RockKit.reset_cache_for_tests()

func _descendants(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

func _first_leaf_mat(root: Node) -> StandardMaterial3D:
	for n in _descendants(root):
		if n is MeshInstance3D and String(n.name).begins_with("frond"):
			return (n as MeshInstance3D).material_override as StandardMaterial3D
	return null

# --- TreeKit ---------------------------------------------------------------

func test_tree_has_branching_trunk_and_fronds() -> void:
	var tree := TreeKit.build(1)
	autofree(tree)
	var nodes := _descendants(tree)
	var trunks := 0
	var limbs := 0
	var fronds := 0
	for n in nodes:
		if n is MeshInstance3D and n.name == "trunk":
			trunks += 1
		if n is MeshInstance3D and String(n.name).begins_with("limb"):
			limbs += 1
		if n is MeshInstance3D and String(n.name).begins_with("frond"):
			fronds += 1
	assert_eq(trunks, 1, "exactly one trunk")
	assert_gt(limbs, 2, "trunk branches into multiple limbs")
	assert_gt(fronds, 8, "canopy is built from multiple frond planes")

func test_leaf_material_is_pixel_cutout() -> void:
	var tree := TreeKit.build(2)
	autofree(tree)
	var m := _first_leaf_mat(tree)
	assert_ne(m, null, "leaf card has a material")
	# The two properties the whole look depends on:
	assert_eq(m.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "leaves use NEAREST (pixelated)")
	assert_eq(m.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, "leaves are alpha-CUTOUT, not blend")
	assert_ne(m.albedo_texture, null, "leaf sprite texture is generated")
	assert_eq(m.cull_mode, BaseMaterial3D.CULL_DISABLED, "card is double-sided")

func test_leaf_texture_has_transparent_and_opaque_pixels() -> void:
	# A cutout sprite is meaningless if it's fully opaque or fully empty.
	var tex := TreeKit._frond_texture(0)
	autofree(tex)  # ImageTexture is RefCounted, but keep the harness tidy
	var img := tex.get_image()
	var clear := 0
	var solid := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a < 0.5:
				clear += 1
			else:
				solid += 1
	assert_gt(clear, 50, "leaf mask has transparent pixels")
	assert_gt(solid, 50, "leaf mask has opaque leaf pixels")

func test_tree_build_is_deterministic() -> void:
	var a := TreeKit.build(7)
	var b := TreeKit.build(7)
	autofree(a); autofree(b)
	assert_eq(_descendants(a).size(), _descendants(b).size(), "same seed → same node count")

# --- RockKit ---------------------------------------------------------------

func test_rock_builds_a_faceted_mesh_on_the_ground() -> void:
	var rock := RockKit.build(3, 1.6)
	autofree(rock)
	var mi: MeshInstance3D = null
	for n in _descendants(rock):
		if n is MeshInstance3D:
			mi = n
	assert_ne(mi, null, "rock has a mesh instance")
	assert_gt(mi.mesh.get_surface_count(), 0, "mesh has a surface")
	var aabb: AABB = mi.mesh.get_aabb()
	assert_gt(aabb.size.length(), 0.1, "mesh has real volume")
	# seated on the ground: lowest point of the scaled+positioned mesh is ~y=0
	var world_min := mi.position.y + aabb.position.y * mi.scale.y
	assert_almost_eq(world_min, 0.0, 0.05, "boulder sits on y=0")

func test_rock_material_uses_triplanar_nearest_detail() -> void:
	var rock := RockKit.build(4)
	autofree(rock)
	var mi: MeshInstance3D = _descendants(rock).filter(func(n): return n is MeshInstance3D)[0]
	var m := mi.material_override
	assert_true(m is ShaderMaterial, "rock uses a shader material (triplanar)")
	var detail = (m as ShaderMaterial).get_shader_parameter("detail")
	assert_ne(detail, null, "detail noise texture is bound")
	assert_contains((m as ShaderMaterial).shader.code, "filter_nearest", "detail is sampled NEAREST")
	assert_contains((m as ShaderMaterial).shader.code, "bw", "material is triplanar (world-axis blend)")

func test_rock_patch_is_flat_pixel_cobble() -> void:
	var patch := RockKit.build_patch(1, 4.0)
	autofree(patch)
	var mi: MeshInstance3D = _descendants(patch).filter(func(n): return n is MeshInstance3D)[0]
	assert_true(mi.mesh is PlaneMesh, "patch is a flat plane (ground decal, not a boulder)")
	var m := mi.material_override as StandardMaterial3D
	assert_ne(m, null, "patch has a material")
	assert_eq(m.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "cobble uses NEAREST (pixelated)")
	assert_ne(m.albedo_texture, null, "cobble texture is generated")

func test_rock_build_is_deterministic() -> void:
	var a := RockKit.build(5)
	var b := RockKit.build(5)
	autofree(a); autofree(b)
	var ma: MeshInstance3D = _descendants(a).filter(func(n): return n is MeshInstance3D)[0]
	var mb: MeshInstance3D = _descendants(b).filter(func(n): return n is MeshInstance3D)[0]
	assert_eq(ma.mesh.get_aabb().size, mb.mesh.get_aabb().size, "same seed → same silhouette")
