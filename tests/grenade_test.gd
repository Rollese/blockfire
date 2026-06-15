extends TestCase

func test_types_are_distinct() -> void:
	assert_eq(Grenade.FRAG, 0)
	assert_eq(Grenade.SMOKE, 1)

func test_launch_velocity_is_dir_times_speed() -> void:
	var v := Grenade.launch_velocity(Vector3(1, 0, 0))
	assert_almost_eq(v.x, Grenade.THROW_SPEED, 0.001)
	assert_almost_eq(v.y, 0.0, 0.001)

func test_integrate_applies_gravity() -> void:
	var s := Grenade.integrate(Vector3.ZERO, Vector3.ZERO, 0.1)
	# v = -G*dt = -2.0; pos = v*dt = -0.2
	assert_almost_eq(s["vel"].y, -2.0, 0.001)
	assert_almost_eq(s["pos"].y, -0.2, 0.001)

func test_falloff_is_linear_to_zero_at_edge() -> void:
	var c := Vector3.ZERO
	assert_eq(Grenade.falloff_damage(c, Vector3.ZERO, 100, 6.0), 100)
	assert_eq(Grenade.falloff_damage(c, Vector3(3, 0, 0), 100, 6.0), 50)
	assert_eq(Grenade.falloff_damage(c, Vector3(6, 0, 0), 100, 6.0), 0)
	assert_eq(Grenade.falloff_damage(c, Vector3(9, 0, 0), 100, 6.0), 0)
