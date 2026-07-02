extends TestCase

func test_known_props_build_with_geometry() -> void:
	for p in ["crate", "barrel", "barrier"]:
		var node := PropKit.build(p)
		autofree(node)
		assert_true(node is Node3D, "%s returns a Node3D" % p)
		assert_true(PropKit.aabb(node).size.length() > 0.0, "%s has non-zero geometry" % p)

func test_barrel_is_round() -> void:
	var barrel := PropKit.build("barrel")
	autofree(barrel)
	var has_cyl := false
	for c in barrel.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is CylinderMesh:
			has_cyl = true
	assert_true(has_cyl, "barrel uses a cylinder")

func test_unknown_prop_falls_back_to_crate() -> void:
	assert_almost_eq(PropKit.aabb(autofree(PropKit.build("???"))).size.y,
		PropKit.aabb(autofree(PropKit.build("crate"))).size.y, 0.001, "unknown -> crate")
