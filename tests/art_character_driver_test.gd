extends TestCase

func _mounted() -> Array:
	# Build a model and mount it under a temporary parent so AnimationPlayer.play() works headless.
	var parent := Node.new()
	var model := GlbCharacterKit.build()
	parent.add_child(model)
	return [parent, model, GlbCharacterKit.anim_player(model)]

func test_drive_plays_requested_clip() -> void:
	var m := _mounted()
	CharacterDriver.drive(m[2], "walk", true)
	assert_eq((m[2] as AnimationPlayer).current_animation, "walk", "walk is current")
	(m[0] as Node).free()

func test_drive_sets_loop_mode() -> void:
	var m := _mounted()
	CharacterDriver.drive(m[2], "walk", true)
	var a := (m[2] as AnimationPlayer).get_animation("walk")
	assert_eq(a.loop_mode, Animation.LOOP_LINEAR, "loop requested -> LOOP_LINEAR")
	CharacterDriver.drive(m[2], "die", false)
	var d := (m[2] as AnimationPlayer).get_animation("die")
	assert_eq(d.loop_mode, Animation.LOOP_NONE, "no loop requested -> LOOP_NONE")
	(m[0] as Node).free()

func test_drive_unknown_clip_is_noop() -> void:
	var m := _mounted()
	CharacterDriver.drive(m[2], "does-not-exist", true)
	assert_true((m[2] as AnimationPlayer).current_animation != "does-not-exist", "unknown clip ignored")
	(m[0] as Node).free()

func test_drive_null_player_is_safe() -> void:
	CharacterDriver.drive(null, "walk", true)
	assert_true(true, "null AnimationPlayer does not crash")
