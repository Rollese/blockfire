extends TestCase

func test_stance_speeds_descend() -> void:
	assert_almost_eq(Stance.speed(Stance.STAND), 6.0)
	assert_almost_eq(Stance.speed(Stance.CROUCH), 3.0)
	assert_almost_eq(Stance.speed(Stance.PRONE), 1.2)

func test_heights_present_for_each_stance() -> void:
	for s in [Stance.STAND, Stance.CROUCH, Stance.PRONE]:
		assert_true(Stance.eye_height(s) > 0.0, "eye height")
		assert_true(Stance.body_height(s) > 0.0, "body height")
		assert_true(Stance.head_center(s) > 0.0, "head center")
