extends TestCase

func test_types_are_distinct() -> void:
	assert_eq(Grenade.FRAG, 0)
	assert_eq(Grenade.SMOKE, 1)

func test_launch_velocity_full_charge_is_max_speed() -> void:
	var v := Grenade.launch_velocity(Vector3(1, 0, 0))   # default charge = 1.0
	assert_almost_eq(v.x, Grenade.MAX_THROW_SPEED, 0.001)
	assert_almost_eq(v.y, 0.0, 0.001)

func test_charged_throw_scales_speed_with_hold() -> void:
	# C3: hold-to-charge — a longer hold throws faster (farther). Tap (0) = MIN, full (1) = MAX.
	assert_almost_eq(Grenade.launch_velocity(Vector3.FORWARD, 0.0).length(), Grenade.MIN_THROW_SPEED, 0.001)
	assert_almost_eq(Grenade.launch_velocity(Vector3.FORWARD, 1.0).length(), Grenade.MAX_THROW_SPEED, 0.001)
	var mid := Grenade.launch_velocity(Vector3.FORWARD, 0.5).length()
	assert_true(mid > Grenade.MIN_THROW_SPEED and mid < Grenade.MAX_THROW_SPEED, "half charge is between")
	# clamps out-of-range charge
	assert_almost_eq(Grenade.launch_velocity(Vector3.FORWARD, 2.0).length(), Grenade.MAX_THROW_SPEED, 0.001)

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

func test_new_grenade_type_constants() -> void:
	assert_eq(Grenade.FRAG, 0)
	assert_eq(Grenade.SMOKE, 1)
	assert_eq(Grenade.FLASHBANG, 2)
	assert_eq(Grenade.IMPACT, 3)

func test_impact_is_contact_fuse_others_are_timed() -> void:
	assert_true(Grenade.is_contact_fuse(Grenade.IMPACT))
	assert_false(Grenade.is_contact_fuse(Grenade.FRAG))
	assert_false(Grenade.is_contact_fuse(Grenade.FLASHBANG))
