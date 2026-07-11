extends TestCase

# A minimal in-memory catalog (two AR variants) so tests never touch the real file.
const _FIX := {"weapons": [
	{"id": 16, "key": "m4a2", "name": "M4A2", "archetype": "AR",
	 "damage_body": 24, "headshot_mult": 2.0, "rpm": 700, "mag_size": 30,
	 "reserve_ammo": 180, "reload_secs": 2.2, "spread_base_deg": 0.55,
	 "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.35, "range_m": 300.0,
	 "muzzle_velocity": 880.0, "gravity_scale": 0.5,
	 "fire_modes": ["AUTO", "SEMI", "BURST"], "burst_count": 3},
	{"id": 17, "key": "akm74", "name": "AKM-74", "archetype": "AR",
	 "damage_body": 30, "headshot_mult": 2.0, "rpm": 580, "mag_size": 30,
	 "reserve_ammo": 180, "reload_secs": 2.4, "spread_base_deg": 0.65,
	 "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.55, "range_m": 280.0,
	 "muzzle_velocity": 715.0, "gravity_scale": 0.5,
	 "fire_modes": ["AUTO", "SEMI"], "burst_count": 3},
]}

func teardown() -> void:
	Weapon.reset_registry()

func test_load_ok_populates_registry() -> void:
	var res := Weapon.load_from_dict(_FIX)
	assert_true(res["ok"], "valid catalog loads: %s" % res["error"])
	var d := Weapon.get_def(16)
	assert_eq(int(d["damage_body"]), 24, "variant 16 damage")
	assert_eq(int(d["rpm"]), 700, "variant 16 rpm")

func test_fire_modes_parsed_to_ints() -> void:
	Weapon.load_from_dict(_FIX)
	var modes: Array = Weapon.get_def(16)["fire_modes"]
	assert_true(modes[0] is int, "fire_modes are ints after load")
	assert_eq(int(modes[0]), Weapon.MODE_AUTO, "AUTO string -> MODE_AUTO")

func test_reject_duplicate_id() -> void:
	var bad := {"weapons": [_FIX["weapons"][0], _FIX["weapons"][0]]}
	assert_false(Weapon.load_from_dict(bad)["ok"], "duplicate id rejected")

func test_reject_id_below_16() -> void:
	var e := (_FIX["weapons"][0] as Dictionary).duplicate(); e["id"] = 3
	assert_false(Weapon.load_from_dict({"weapons": [e]})["ok"], "id < 16 collides with archetype enum")

func test_reject_bad_archetype() -> void:
	var e := (_FIX["weapons"][0] as Dictionary).duplicate(); e["archetype"] = "BAZOOKA"
	assert_false(Weapon.load_from_dict({"weapons": [e]})["ok"], "unknown archetype rejected")

func test_reject_empty() -> void:
	assert_false(Weapon.load_from_dict({"weapons": []})["ok"], "empty catalog rejected")

func test_reject_zero_damage() -> void:
	var e := (_FIX["weapons"][0] as Dictionary).duplicate(); e["damage_body"] = 0
	assert_false(Weapon.load_from_dict({"weapons": [e]})["ok"], "zero damage rejected")

func test_reject_duplicate_key() -> void:
	var a := (_FIX["weapons"][0] as Dictionary).duplicate()
	var b := (_FIX["weapons"][0] as Dictionary).duplicate(); b["id"] = 18
	assert_false(Weapon.load_from_dict({"weapons": [a, b]})["ok"], "duplicate key rejected")

func test_archetype_of() -> void:
	Weapon.load_from_dict(_FIX)
	assert_eq(Weapon.archetype_of(16), Weapon.AR, "variant -> its archetype")
	assert_eq(Weapon.archetype_of(Weapon.DMR), Weapon.DMR, "base id maps to itself")

func test_variants_of_default_first() -> void:
	Weapon.load_from_dict(_FIX)
	var ar := Weapon.variants_of(Weapon.AR)
	assert_eq(ar[0], 16, "catalog order: default (M4A2) first")
	assert_eq(Weapon.default_variant(Weapon.AR), 16, "default_variant == variants_of[0]")

func test_default_variant_degrades_when_empty() -> void:
	Weapon.load_from_dict(_FIX)
	# SMG has no variants in the fixture -> degrade to the archetype id.
	assert_true(Weapon.variants_of(Weapon.SMG).is_empty(), "no SMG variants loaded")
	assert_eq(Weapon.default_variant(Weapon.SMG), Weapon.SMG, "degrades to archetype default")

func test_is_variant_and_display_name() -> void:
	Weapon.load_from_dict(_FIX)
	assert_true(Weapon.is_variant(16), "16 is a variant")
	assert_false(Weapon.is_variant(Weapon.AR), "base id is not a variant")
	assert_eq(Weapon.display_name(17), "AKM-74", "variant display name")
