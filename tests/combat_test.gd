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

func _eff(spread_mult: float, move_mult: float, prone_zero: bool) -> Dictionary:
	return Weapon.effective_def(Weapon.AR, {"spread_mult": spread_mult, "recoil_mult": 1.0,
		"range_mult": 1.0, "move_spread_mult": move_mult, "prone_spread_zero": prone_zero})

func test_override_tightens_spread_vs_base() -> void:
	# Same seed: a tighter spread_mult must not push the ray further from forward than the base.
	var eye := Vector3.ZERO
	var base_ray := Combat.reconstruct_ray(Weapon.AR, eye, 0.0, 0.0, 0, 7, 11, 3, false)
	var tight_ray := Combat.reconstruct_ray(Weapon.AR, eye, 0.0, 0.0, 0, 7, 11, 3, false, false, _eff(0.1, 1.0, false))
	var fwd := Vector3(0, 0, 1)
	assert_true(tight_ray["dir"].dot(fwd) >= base_ray["dir"].dot(fwd) - 0.0001, "tighter spread stays nearer forward")

func test_bipod_prone_zeroes_spread() -> void:
	var r := Combat.reconstruct_ray(Weapon.AR, Vector3.ZERO, 0.0, 0.0, 0, 1, 1, 0, true, true, _eff(1.0, 1.0, true))
	assert_almost_eq(r["dir"].dot(Vector3(0, 0, 1)), 1.0, 0.0001, "bipod prone = zero spread, dead-on")

func test_damage_for_uses_override_range() -> void:
	# Override range to 10 m; a shot at 50 m should now do 0.
	var eff := Weapon.effective_def(Weapon.AR, {"spread_mult": 1.0, "recoil_mult": 1.0, "range_mult": 10.0 / float(Weapon.get_def(Weapon.AR)["range_m"]), "move_spread_mult": 1.0, "prone_spread_zero": false})
	assert_eq(Combat.damage_for(Weapon.AR, false, 50.0, eff), 0)
	assert_true(Combat.damage_for(Weapon.AR, false, 5.0, eff) > 0)
