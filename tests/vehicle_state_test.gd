extends TestCase

func test_clone_is_independent_copy() -> void:
	var s := VehicleState.new()
	s.pos = Vector3(1, 2, 3); s.heading = 0.5; s.turret_yaw = -0.5
	s.hp = 800; s.type = 0; s.seats = [7, 0, 0, 0, 9]
	var c := s.clone()
	assert_eq(c.hp, 800)
	assert_almost_eq(c.heading, 0.5, 0.0001)
	assert_eq(int(c.seats[0]), 7)
	c.seats[0] = 0
	assert_eq(int(s.seats[0]), 7)   # original unaffected
