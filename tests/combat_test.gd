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

func test_penetrate_wood_splits_damage() -> void:
	# body 25 to piece -> 25*0.40 = 10; enemy 25 beyond -> 25*0.60 = 15
	var r := Combat.apply_penetration(25, 25, PieceCatalog.absorption_of(PieceCatalog.MAT_WOOD), PieceCatalog.transmit_of(PieceCatalog.MAT_WOOD))
	assert_eq(r["piece_damage"], 10)
	assert_eq(r["exit_damage"], 15)

func test_penetrate_metal_thin_higher_absorption() -> void:
	var r := Combat.apply_penetration(100, 100, 0.65, 0.35)
	assert_eq(r["piece_damage"], 65)
	assert_eq(r["exit_damage"], 35)

func test_penetrate_rounds_to_int() -> void:
	var r := Combat.apply_penetration(45, 45, 0.40, 0.60)
	assert_eq(r["piece_damage"], 18)   # round(18.0)
	assert_eq(r["exit_damage"], 27)    # round(27.0)
