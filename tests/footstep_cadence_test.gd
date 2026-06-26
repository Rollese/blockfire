extends TestCase
## FootstepCadence (M7): a pawn fires a footstep every stride of ground travel. View-only feedback.

func test_standing_still_never_steps() -> void:
	var r := FootstepCadence.advance(0.0, 0.0, 0.0, Stance.STAND, true)
	assert_false(r["fired"], "no footstep while stationary")
	assert_almost_eq(r["accum"], 0.0, 0.001, "accumulator stays drained")

func test_footfalls_equal_distance_over_stride() -> void:
	var stride := FootstepCadence.stride_for(Stance.STAND)
	var accum := 0.0
	var steps := 0
	for i in range(10):
		var r := FootstepCadence.advance(accum, 0.5, 3.0, Stance.STAND, true)
		accum = r["accum"]
		if r["fired"]:
			steps += 1
	# 10 * 0.5 = 5 m of travel over a 2.2 m stride -> 2 footfalls.
	assert_eq(steps, int(5.0 / stride), "footfalls = floor(distance / stride)")

func test_remainder_is_kept_phase_correct() -> void:
	var stride := FootstepCadence.stride_for(Stance.STAND)
	var r := FootstepCadence.advance(stride - 0.1, 0.3, 3.0, Stance.STAND, true)
	assert_true(r["fired"], "crossing the stride fires")
	assert_almost_eq(r["accum"], 0.2, 0.001, "leftover 0.2 m carried into the next stride")

func test_airborne_does_not_step() -> void:
	var r := FootstepCadence.advance(5.0, 0.3, 5.0, Stance.STAND, false)
	assert_false(r["fired"], "no footsteps mid-air")
	assert_almost_eq(r["accum"], 0.0, 0.001, "airborne drains the accumulator")

func test_prone_is_silent() -> void:
	var r := FootstepCadence.advance(5.0, 0.5, 3.0, Stance.PRONE, true)
	assert_false(r["fired"], "crawling makes no footstep")

func test_crouch_strides_shorter_than_stand() -> void:
	assert_true(FootstepCadence.stride_for(Stance.CROUCH) < FootstepCadence.stride_for(Stance.STAND),
		"a crouch-walk footfall lands sooner than a standing stride")

func test_teleport_distance_is_ignored() -> void:
	var r := FootstepCadence.advance(1.0, FootstepCadence.MAX_FRAME_DIST + 1.0, 50.0, Stance.STAND, true)
	assert_false(r["fired"], "a respawn/teleport jump fires no footstep")
	assert_almost_eq(r["accum"], 0.0, 0.001, "and resets the accumulator")

func test_sprint_intensity_exceeds_walk() -> void:
	var stride := FootstepCadence.stride_for(Stance.STAND)
	var walk := FootstepCadence.advance(stride, 0.1, 2.0, Stance.STAND, true)
	var sprint := FootstepCadence.advance(stride, 0.1, 7.5, Stance.STAND, true)
	assert_true(walk["fired"] and sprint["fired"], "both cross the stride")
	assert_true(sprint["intensity"] > walk["intensity"], "faster pawn -> louder/bigger footstep")
