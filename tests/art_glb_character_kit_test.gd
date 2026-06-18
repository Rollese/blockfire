extends TestCase

func test_build_returns_node3d_with_animationplayer() -> void:
	var node := GlbCharacterKit.build()
	assert_true(node is Node3D, "build() returns a Node3D root")
	var ap := GlbCharacterKit.anim_player(node)
	assert_true(ap is AnimationPlayer, "exposes the model's AnimationPlayer")
	assert_true(ap.has_animation("walk"), "walk clip present")
	assert_true(ap.has_animation("idle"), "idle clip present")
	node.free()

func test_build_scales_model_to_stand_height() -> void:
	var node := GlbCharacterKit.build()
	var aabb := GlbCharacterKit.world_aabb(node)
	assert_true(absf(aabb.size.y - GlbCharacterKit.STAND_HEIGHT) < 0.05,
		"scaled height ~= STAND_HEIGHT (got %f)" % aabb.size.y)
	node.free()

func test_stand_height_matches_canonical() -> void:
	assert_eq(GlbCharacterKit.STAND_HEIGHT, CharacterKit.STAND_HEIGHT,
		"GLB stand height equals the procedural kit's so renderer scaling is mode-agnostic")

func test_attach_weapon_parents_a_weapon_under_the_hand() -> void:
	var soldier := GlbCharacterKit.build()
	var hand := soldier.find_child(GlbCharacterKit.HAND_NODE, true, false)
	assert_true(hand != null, "the GLB exposes the '%s' hand node" % GlbCharacterKit.HAND_NODE)
	var held := hand.find_child("HeldWeapon", false, false)
	assert_true(held != null, "a HeldWeapon is parented directly under the hand node")
	assert_true(held is Node3D, "the held weapon is a Node3D")
	# The held weapon is now a GlbWeaponKit model (imported GLB for AR, or procedural fallback);
	# either way it contributes at least one mesh somewhere in its subtree.
	var meshes := 0
	var stack: Array = [held]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			meshes += 1
		for c in n.get_children():
			stack.append(c)
	assert_true(meshes >= 1, "the held weapon has renderable geometry")

func test_build_includes_a_held_weapon_by_default() -> void:
	var soldier := GlbCharacterKit.build()
	assert_true(soldier.find_child("HeldWeapon", true, false) != null,
		"GlbCharacterKit.build() arms the soldier with a default weapon")

func test_attach_weapon_is_safe_without_a_hand_node() -> void:
	var bare := Node3D.new()
	var ok := GlbCharacterKit.attach_weapon(bare, Weapon.AR)
	assert_false(ok, "no hand node -> returns false, no crash")
	assert_true(bare.find_child("HeldWeapon", true, false) == null, "nothing attached")

func test_held_weapon_does_not_break_height_normalization() -> void:
	var soldier := GlbCharacterKit.build()
	var h := GlbCharacterKit.world_aabb(soldier).size.y
	assert_almost_eq(h, GlbCharacterKit.STAND_HEIGHT, 0.35,
		"standing height stays ~STAND_HEIGHT despite the held weapon")
