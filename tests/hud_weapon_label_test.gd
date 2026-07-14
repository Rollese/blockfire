extends TestCase

func teardown() -> void:
	Weapon.reset_registry()

func test_base_archetype_labels_unchanged() -> void:
	assert_eq(HudView._weapon_label(Weapon.AR), "AR", "base AR label")
	assert_eq(HudView._weapon_label(Weapon.SMG), "SMG", "base SMG label")
	assert_eq(HudView._weapon_label(Weapon.DMR), "DMR", "base DMR label")
	assert_eq(HudView._weapon_label(Weapon.RPG), "RPG", "base RPG label (display_name would wrongly say AR)")
	assert_eq(HudView._weapon_label(Weapon.PISTOL), "PISTOL", "base PISTOL label")

func test_variant_shows_gun_name() -> void:
	Weapon.load_from_file("res://data/weapons.json")
	assert_eq(HudView._weapon_label(22), "SVD-K", "DMR variant shows its gun name")
	assert_eq(HudView._weapon_label(16), "M4A2", "AR variant shows its gun name")

func test_ammo_model_exposes_spare_mags_and_no_reserve_number() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.mag = 17
	wp.spare_mags = [30, 12, 0]
	var m := HudModel.new()
	var a: Dictionary = m._ammo({"weapon_predictor": wp, "tick": 0})
	assert_eq(int(a["mag"]), 17)
	assert_eq(a["spare_mags"], [30, 12, 0])
	assert_eq(int(a["mag_size"]), int(Weapon.get_def(Weapon.AR)["mag_size"]))
