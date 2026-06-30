extends TestCase

func test_holding_pose_when_still_and_alive() -> void:
	var r := CharacterAnim.clip_for(false, 0.0, Stance.STAND)
	assert_eq(r["clip"], "holding-both", "still + armed -> two-handed weapon-ready hold")
	assert_true(r["loop"], "the ready hold loops (breathing)")

func test_walk_above_walk_threshold() -> void:
	var r := CharacterAnim.clip_for(false, 1.5, Stance.STAND)
	assert_eq(r["clip"], "walk", "moderate speed -> walk")
	assert_true(r["loop"], "walk loops")

func test_sprint_above_sprint_threshold() -> void:
	var r := CharacterAnim.clip_for(false, 6.0, Stance.STAND)
	assert_eq(r["clip"], "sprint", "high speed -> sprint")

func test_downed_uses_calm_lying_pose() -> void:
	# Downed (DBNO) is alive, lying on the back — the renderer tips the body face-up. We want a calm
	# breathing pose, NOT the `die` collapse clip (which flails the arms and reads as "hands-up").
	var r := CharacterAnim.clip_for(true, 0.0, Stance.STAND)
	assert_eq(r["clip"], "idle", "downed -> calm idle (renderer lays it on its back)")
	assert_true(r["loop"], "downed pose loops (alive, breathing)")

func test_downed_overrides_movement() -> void:
	var r := CharacterAnim.clip_for(true, 6.0, Stance.STAND)
	assert_eq(r["clip"], "idle", "downed wins over speed (no sprinting while incapacitated)")

func test_firing_stationary_uses_shoot_clip() -> void:
	var r := CharacterAnim.clip_for(false, 0.0, Stance.STAND, true)
	assert_eq(r["clip"], "holding-both-shoot", "stationary + firing -> authored shoot clip")
	assert_true(r["loop"], "shoot clip loops for sustained auto-fire")

func test_firing_while_moving_keeps_locomotion() -> void:
	# A moving shooter keeps walk/sprint (the body-pitch recoil twitch covers fire feedback in motion).
	assert_eq(CharacterAnim.clip_for(false, 1.5, Stance.STAND, true)["clip"], "walk", "walking+firing stays walk")
	assert_eq(CharacterAnim.clip_for(false, 6.0, Stance.STAND, true)["clip"], "sprint", "sprinting+firing stays sprint")

func test_not_firing_stationary_is_plain_hold() -> void:
	assert_eq(CharacterAnim.clip_for(false, 0.0, Stance.STAND, false)["clip"], "holding-both", "stationary idle -> plain hold")

func test_reloading_stationary_uses_interact_clip() -> void:
	var r := CharacterAnim.clip_for(false, 0.0, Stance.STAND, false, true)
	assert_eq(r["clip"], "interact", "stationary + reloading -> interact gesture (no authored reload clip)")
	assert_true(r["loop"], "reload gesture loops for the reload span")

func test_reloading_while_moving_keeps_locomotion() -> void:
	# A reloading-on-the-move pawn keeps walk/sprint; the reload gesture only stands in when stationary.
	assert_eq(CharacterAnim.clip_for(false, 1.5, Stance.STAND, false, true)["clip"], "walk", "walking+reloading stays walk")
	assert_eq(CharacterAnim.clip_for(false, 6.0, Stance.STAND, false, true)["clip"], "sprint", "sprinting+reloading stays sprint")

func test_downed_overrides_reloading() -> void:
	assert_eq(CharacterAnim.clip_for(true, 0.0, Stance.STAND, false, true)["clip"], "idle", "downed wins over reloading")
