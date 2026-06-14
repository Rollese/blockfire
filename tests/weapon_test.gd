extends TestCase

func test_weapons_exist_with_sane_stats() -> void:
	for wid in [Weapon.AR, Weapon.SMG, Weapon.DMR]:
		var w := Weapon.get_def(wid)
		assert_true(w["damage_body"] > 0)
		assert_true(w["headshot_mult"] >= 1.0)
		assert_true(w["mag_size"] > 0)
		assert_true(w["rpm"] > 0)

func test_fire_interval_from_rpm() -> void:
	assert_almost_eq(Weapon.fire_interval(Weapon.AR), 0.1, 0.001)
