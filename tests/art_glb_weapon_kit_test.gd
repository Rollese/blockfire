extends TestCase
## GlbWeaponKit: imported weapon GLBs for mapped weapons, procedural fallback otherwise.

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

func test_mapped_weapon_loads_a_glb_model() -> void:
	var ar := GlbWeaponKit.build(Weapon.AR)
	autofree(ar)
	assert_true(ar is Node3D, "AR returns a Node3D")
	assert_true(_mesh_count(ar) >= 1, "the imported AR GLB contributes at least one mesh")

func test_mapped_weapon_is_normalized_to_target_length() -> void:
	var ar := GlbWeaponKit.build(Weapon.AR)
	autofree(ar)
	var sz: Vector3 = GlbCharacterKit.world_aabb(ar).size
	var longest: float = maxf(sz.x, maxf(sz.y, sz.z))
	assert_almost_eq(longest, GlbWeaponKit.TARGET_LENGTH, 0.05,
		"longest axis normalized to TARGET_LENGTH regardless of the model's native scale")

func test_smg_and_dmr_also_map_to_glbs() -> void:
	assert_true(_mesh_count(autofree(GlbWeaponKit.build(Weapon.SMG))) >= 1, "SMG maps to a GLB")
	assert_true(_mesh_count(autofree(GlbWeaponKit.build(Weapon.DMR))) >= 1, "DMR maps to a GLB")

func test_pistol_maps_to_glb() -> void:
	assert_true(_mesh_count(autofree(GlbWeaponKit.build(Weapon.PISTOL))) >= 1, "PISTOL maps to a GLB")

func test_rpg_falls_back_to_procedural_weaponkit() -> void:
	# The Ultimate Guns Pack has no launcher, so RPG must fall back to the procedural WeaponKit,
	# which builds a visible warhead cone.
	var rpg := GlbWeaponKit.build(Weapon.RPG)
	autofree(rpg)
	assert_true(rpg.find_child("Warhead", true, false) != null,
		"RPG -> procedural WeaponKit (identifiable by its Warhead part)")

func test_unknown_weapon_still_builds_something() -> void:
	var unknown := GlbWeaponKit.build(999)
	autofree(unknown)
	assert_true(unknown is Node3D and _mesh_count(unknown) >= 1,
		"unknown id falls back to procedural WeaponKit (non-null, has geometry)")
