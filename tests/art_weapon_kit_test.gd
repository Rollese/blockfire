extends TestCase

func test_builds_a_distinct_model_per_weapon() -> void:
	for w in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.RPG]:
		var node := WeaponKit.build(w)
		autofree(node)
		assert_true(node is Node3D, "weapon %d returns a Node3D" % w)
		assert_true(node.get_child_count() >= 2, "weapon %d has multiple parts" % w)

func test_relative_lengths_read_as_their_class() -> void:
	var smg_len := WeaponKit.aabb(autofree(WeaponKit.build(Weapon.SMG))).size.z
	var ar_len := WeaponKit.aabb(autofree(WeaponKit.build(Weapon.AR))).size.z
	var dmr_len := WeaponKit.aabb(autofree(WeaponKit.build(Weapon.DMR))).size.z
	assert_true(smg_len < ar_len, "SMG shorter than AR")
	assert_true(dmr_len > ar_len, "DMR longer than AR (marksman barrel)")

func test_rpg_has_a_warhead_cone() -> void:
	var rpg := WeaponKit.build(Weapon.RPG)
	autofree(rpg)
	assert_true(rpg.has_node("Warhead"), "RPG carries a visible warhead")

func test_unknown_weapon_falls_back_to_ar() -> void:
	var fallback := WeaponKit.aabb(autofree(WeaponKit.build(999))).size
	var ar := WeaponKit.aabb(autofree(WeaponKit.build(Weapon.AR))).size
	assert_almost_eq(fallback.z, ar.z, 0.001, "unknown id renders as AR")
