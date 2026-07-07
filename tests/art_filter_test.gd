extends TestCase
## ArtFilter.apply_nearest walks a built node tree and forces every mesh material to NEAREST texture
## filtering (game-wide pixel-cutout look). Headless-safe — asserts material properties only, never
## rendered pixels (AGENTS.md §10). Targets GLB-loaded models whose materials the glTF importer bakes
## LINEAR; procedural kits already set NEAREST inline.

func _mesh_with_override() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mi.material_override = mat
	return mi

func _mesh_with_surface_override() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()   # one surface
	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mi.set_surface_override_material(0, mat)
	return mi

func test_apply_nearest_switches_material_override() -> void:
	var root := Node3D.new()
	autofree(root)
	var mi := _mesh_with_override()
	root.add_child(mi)
	var count := ArtFilter.apply_nearest(root)
	assert_gt(count, 0, "at least one material switched")
	assert_eq((mi.material_override as BaseMaterial3D).texture_filter,
		BaseMaterial3D.TEXTURE_FILTER_NEAREST, "material_override is NEAREST")

func test_apply_nearest_switches_surface_override() -> void:
	var root := Node3D.new()
	autofree(root)
	var mi := _mesh_with_surface_override()
	root.add_child(mi)
	var count := ArtFilter.apply_nearest(root)
	assert_gt(count, 0, "at least one material switched")
	assert_eq((mi.get_surface_override_material(0) as BaseMaterial3D).texture_filter,
		BaseMaterial3D.TEXTURE_FILTER_NEAREST, "surface override is NEAREST")

func test_apply_nearest_walks_nested_children() -> void:
	var root := Node3D.new()
	autofree(root)
	var mid := Node3D.new()
	root.add_child(mid)
	var mi := _mesh_with_override()
	mid.add_child(mi)
	var count := ArtFilter.apply_nearest(root)
	assert_eq(count, 1, "found the deeply nested material")
	assert_eq((mi.material_override as BaseMaterial3D).texture_filter,
		BaseMaterial3D.TEXTURE_FILTER_NEAREST, "nested material_override is NEAREST")

func test_apply_nearest_is_idempotent() -> void:
	var root := Node3D.new()
	autofree(root)
	root.add_child(_mesh_with_override())
	var first := ArtFilter.apply_nearest(root)
	assert_gt(first, 0, "first walk switches the LINEAR material")
	var second := ArtFilter.apply_nearest(root)
	assert_eq(second, 0, "idempotent: nothing left to switch on the second walk")

func test_apply_nearest_switches_mesh_surface_material() -> void:
	# The path GLB models actually use: a material stored on the mesh surface itself, with NO override.
	var root := Node3D.new()
	autofree(root)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	bm.surface_set_material(0, mat)
	mi.mesh = bm
	root.add_child(mi)
	var count := ArtFilter.apply_nearest(root)
	assert_gt(count, 0, "mesh surface material switched via surface_get_material fallback")
	assert_eq((mi.mesh.surface_get_material(0) as BaseMaterial3D).texture_filter,
		BaseMaterial3D.TEXTURE_FILTER_NEAREST, "surface_get_material material is NEAREST")
