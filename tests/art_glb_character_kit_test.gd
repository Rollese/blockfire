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
