extends TestCase
## FootstepAudio (M7): maps locomotion context to the footstep catalog event.

func test_walk_is_default() -> void:
	assert_eq(FootstepAudio.event_for(0.5, Stance.STAND), "footstep_walk")

func test_run_at_sprint_intensity() -> void:
	assert_eq(FootstepAudio.event_for(0.9, Stance.STAND), "footstep_run")

func test_sneak_when_crouched() -> void:
	assert_eq(FootstepAudio.event_for(0.9, Stance.CROUCH), "footstep_sneak",
		"crouch overrides sprint intensity")

func test_land_action_override() -> void:
	assert_eq(FootstepAudio.event_for(1.0, Stance.STAND, FootstepAudio.LAND), "footstep_land")

func test_jump_action_override() -> void:
	assert_eq(FootstepAudio.event_for(0.5, Stance.STAND, FootstepAudio.JUMP), "footstep_jump")
