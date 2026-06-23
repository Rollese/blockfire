extends TestCase

func test_initial_velocity_is_dir_times_speed() -> void:
	var v := Projectile.initial_velocity(Vector3(0, 0, 1), 250.0)
	assert_almost_eq(v.z, 250.0)
	assert_almost_eq(v.x, 0.0)

func test_integrate_applies_scaled_gravity_and_advances() -> void:
	var s := Projectile.integrate(Vector3.ZERO, Vector3(0, 0, 250.0), 0.5, 1.0 / 30.0)
	assert_true(s["pos"].z > 8.0, "advanced downrange")
	assert_true(s["vel"].y < 0.0, "gained downward velocity")

func test_higher_gravity_scale_drops_more() -> void:
	var lo := Projectile.integrate(Vector3.ZERO, Vector3(0, 0, 250.0), 0.3, 1.0)
	var hi := Projectile.integrate(Vector3.ZERO, Vector3(0, 0, 250.0), 0.9, 1.0)
	assert_true(hi["pos"].y < lo["pos"].y, "more drop with higher scale")

func test_expired_on_ttl_or_range() -> void:
	assert_true(Projectile.expired(5, 5, 5.0, 100.0))      # ttl reached (age == max_ticks)
	assert_true(Projectile.expired(2, 10, 100.0, 10.0))    # dist >= range
	assert_false(Projectile.expired(2, 10, 5.0, 100.0))    # neither expired
