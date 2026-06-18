extends TestCase

func test_idle_when_still_and_alive() -> void:
	var r := CharacterAnim.clip_for(false, 0.0, Stance.STAND)
	assert_eq(r["clip"], "idle", "still -> idle")
	assert_true(r["loop"], "idle loops")

func test_walk_above_walk_threshold() -> void:
	var r := CharacterAnim.clip_for(false, 1.5, Stance.STAND)
	assert_eq(r["clip"], "walk", "moderate speed -> walk")
	assert_true(r["loop"], "walk loops")

func test_sprint_above_sprint_threshold() -> void:
	var r := CharacterAnim.clip_for(false, 6.0, Stance.STAND)
	assert_eq(r["clip"], "sprint", "high speed -> sprint")

func test_downed_plays_die_pose_non_looping() -> void:
	var r := CharacterAnim.clip_for(true, 0.0, Stance.STAND)
	assert_eq(r["clip"], "die", "downed -> die collapse pose")
	assert_false(r["loop"], "die does not loop (holds last frame)")

func test_downed_overrides_movement() -> void:
	var r := CharacterAnim.clip_for(true, 6.0, Stance.STAND)
	assert_eq(r["clip"], "die", "downed wins over speed")
