extends TestCase

func teardown() -> void:
	Weapon.reset_registry()

func _load() -> void:
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "real catalog loads: %s" % res["error"])

func _by_key(archetype: int) -> Dictionary:
	var m := {}
	for id in Weapon.variants_of(archetype):
		m[String(Weapon.get_def(id)["key"])] = Weapon.get_def(id)
	return m

func test_catalog_wellformed() -> void:
	_load()
	var seen := {}
	for arch in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.PISTOL]:
		var ids := Weapon.variants_of(arch)
		assert_true(ids.size() >= 3, "archetype %d has >=3 variants" % arch)
		for id in ids:
			assert_true(int(id) >= 16, "id >= 16")
			assert_false(seen.has(id), "unique id %d" % id)
			seen[id] = true
			assert_eq(Weapon.archetype_of(id), arch, "id %d resolves to its archetype" % id)

func test_defaults_are_first() -> void:
	_load()
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.AR))["key"]), "m4a2", "AR default")
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.SMG))["key"]), "mp5x", "SMG default")
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.DMR))["key"]), "svdk", "DMR default")
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.PISTOL))["key"]), "m9", "Pistol default")

func test_ar_role_axis() -> void:
	_load()
	var ar := _by_key(Weapon.AR)
	assert_true(int(ar["m4a2"]["damage_body"]) < int(ar["akm74"]["damage_body"]), "AR dmg M4<AK")
	assert_true(int(ar["akm74"]["damage_body"]) < int(ar["fl40"]["damage_body"]), "AR dmg AK<FAL")
	assert_true(int(ar["m4a2"]["rpm"]) > int(ar["akm74"]["rpm"]), "AR rpm M4>AK")
	assert_true(int(ar["akm74"]["rpm"]) > int(ar["fl40"]["rpm"]), "AR rpm AK>FAL")

func test_smg_role_axis() -> void:
	_load()
	var s := _by_key(Weapon.SMG)
	assert_true(int(s["uz9"]["rpm"]) > int(s["skorpion61"]["rpm"]), "SMG UZ fastest > Skorpion")
	assert_true(int(s["skorpion61"]["rpm"]) > int(s["mp5x"]["rpm"]), "Skorpion > MP5")
	assert_true(int(s["skorpion61"]["damage_body"]) < int(s["mp5x"]["damage_body"]), "Skorpion lowest dmg")

func test_dmr_role_axis() -> void:
	_load()
	var d := _by_key(Weapon.DMR)
	assert_true(int(d["sk45"]["rpm"]) > int(d["svdk"]["rpm"]), "DMR SK fastest")
	assert_true(int(d["svdk"]["rpm"]) > int(d["m14ebr"]["rpm"]), "DMR SVD > Mk14")
	assert_true(int(d["sk45"]["damage_body"]) < int(d["m14ebr"]["damage_body"]), "DMR SK < Mk14 dmg")

func test_pistol_role_axis() -> void:
	_load()
	var p := _by_key(Weapon.PISTOL)
	assert_eq(int(p["d50"]["mag_size"]), 7, "Deagle smallest mag")
	assert_true(int(p["d50"]["damage_body"]) > int(p["p229"]["damage_body"]), "Deagle hand-cannon dmg")

func test_effective_def_applies_to_variant() -> void:
	# effective_def duplicates get_def(id) and applies attachment multipliers; it must work on a
	# variant id (attachment compatibility is category-level, resolved via archetype elsewhere).
	_load()
	var base := Weapon.get_def(18)   # FL-40 (AR variant), spread_base 0.50
	var eff := Weapon.effective_def(18, {"spread_mult": 0.5, "recoil_mult": 1.0, "range_mult": 1.0})
	assert_almost_eq(float(eff["spread_base_deg"]), float(base["spread_base_deg"]) * 0.5, 0.0001, "spread mult applied to variant")
	assert_eq(int(eff["damage_body"]), int(base["damage_body"]), "damage untouched by these mults")
