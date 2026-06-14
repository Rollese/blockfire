extends TestCase

func test_ray_is_deterministic() -> void:
	var r1 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 1, 3, true)
	var r2 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 1, 3, true)
	assert_almost_eq((r1["dir"] - r2["dir"]).length(), 0.0, 0.00001, "same seed -> same ray")

func test_different_shot_index_differs() -> void:
	var r1 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 1, 3, true)
	var r2 := Combat.reconstruct_ray(Weapon.AR, Vector3(0,1.6,0), 0.0, 0.0, 0, 7, 5, 3, true)
	assert_true((r1["dir"] - r2["dir"]).length() > 0.0, "recoil/spread differ by shot index")

func test_headshot_multiplier() -> void:
	assert_eq(Combat.damage_for(Weapon.AR, false, 10.0), 25)
	assert_eq(Combat.damage_for(Weapon.AR, true, 10.0), 50)

func test_out_of_range_zero_damage() -> void:
	assert_eq(Combat.damage_for(Weapon.AR, false, 999.0), 0)
