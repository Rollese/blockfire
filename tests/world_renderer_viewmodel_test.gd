extends TestCase
## WorldRenderer.build_viewmodel: a GlbWeaponKit weapon placed in camera space for first person.

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

func test_build_viewmodel_is_a_placed_weapon() -> void:
	var vm := WorldRenderer.build_viewmodel(Weapon.AR)
	autofree(vm)
	assert_true(vm is Node3D, "returns a Node3D holder")
	assert_eq(vm.position, WorldRenderer.VM_OFFSET, "placed at the camera-space viewmodel offset")
	assert_almost_eq(vm.rotation.y, WorldRenderer.VM_YAW, 0.001, "yawed to face camera-forward (-Z)")
	assert_true(_mesh_count(vm) >= 1, "holds a weapon with renderable geometry")

func test_build_viewmodel_wraps_weapon_so_kit_orientation_is_intact() -> void:
	# The holder wraps the GlbWeaponKit weapon (which sets its own MODEL_YAW); the holder must NOT
	# overwrite that — the weapon is a child, so the placement composes rather than clobbers.
	var vm := WorldRenderer.build_viewmodel(Weapon.AR)
	autofree(vm)
	assert_eq(vm.get_child_count(), 1, "holder wraps exactly the weapon node")

func test_build_viewmodel_rpg_fallback_still_builds() -> void:
	var vm := WorldRenderer.build_viewmodel(Weapon.RPG)
	autofree(vm)
	assert_true(_mesh_count(vm) >= 1, "RPG (procedural WeaponKit fallback) still yields a viewmodel")
