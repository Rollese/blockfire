extends TestCase

const LADDER := {"bottom": Vector3(5, 0, 5), "top": Vector3(5, 4, 5), "radius": 0.6}

func test_capture_within_radius_and_height() -> void:
	assert_true(Ladder.capture([LADDER], Vector3(5.3, 1.0, 5.0)) == LADDER)   # within radius + y range
	assert_true(Ladder.capture([LADDER], Vector3(8.0, 1.0, 5.0)).is_empty())  # too far horizontally
	assert_true(Ladder.capture([LADDER], Vector3(5.0, 9.0, 5.0)).is_empty())  # above the top

func test_should_engage_requires_upward_intent_below_top() -> void:
	# At the base, pressing forward (move_y>0) engages.
	assert_true(Ladder.should_engage(LADDER, Vector3(5, 0, 5), 1.0))
	# Standing in the volume with no upward intent does not engage (won't trap passers-by).
	assert_false(Ladder.should_engage(LADDER, Vector3(5, 0, 5), 0.0))
	# At the very top there is no room to climb up.
	assert_false(Ladder.should_engage(LADDER, Vector3(5, 4, 5), 1.0))

func test_climb_step_moves_vertically_and_locks_to_line() -> void:
	var np := Ladder.climb_step(LADDER, Vector3(5.4, 1.0, 5.2), 1.0, 1.0 / 30.0)
	assert_almost_eq(np.x, 5.0)   # locked to ladder x
	assert_almost_eq(np.z, 5.0)   # locked to ladder z
	assert_true(np.y > 1.0, "climbs upward with move_y>0")
	var down := Ladder.climb_step(LADDER, Vector3(5, 2, 5), -1.0, 1.0 / 30.0)
	assert_true(down.y < 2.0, "descends with move_y<0")

func test_climb_step_clamps_to_anchor_range() -> void:
	var top := Ladder.climb_step(LADDER, Vector3(5, 3.99, 5), 1.0, 1.0)  # big dt overshoots
	assert_almost_eq(top.y, 4.0)   # clamped to top.y
	var bot := Ladder.climb_step(LADDER, Vector3(5, 0.01, 5), -1.0, 1.0)
	assert_almost_eq(bot.y, 0.0)   # clamped to bottom.y

func test_platform_floor_inside_footprint_else_zero() -> void:
	var plats := [{"min": Vector3(0, 0, 0), "max": Vector3(10, 4, 10)}]
	assert_almost_eq(Ladder.platform_floor(plats, 5.0, 5.0, 4.0), 4.0)   # standing on top
	assert_almost_eq(Ladder.platform_floor(plats, 5.0, 5.0, 5.0), 4.0)   # above the top -> floor is the top
	assert_almost_eq(Ladder.platform_floor(plats, 50.0, 50.0, 5.0), 0.0) # outside footprint -> ground
