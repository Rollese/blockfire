extends TestCase

func test_each_class_maps_to_a_weapon() -> void:
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT, Loadout.RECON]:
		var wid := Loadout.weapon_for(c)
		assert_true(wid in [Weapon.AR, Weapon.SMG, Weapon.DMR], "valid weapon for class %d" % c)

func test_recon_uses_dmr_engineer_uses_smg() -> void:
	assert_eq(Loadout.weapon_for(Loadout.RECON), Weapon.DMR)
	assert_eq(Loadout.weapon_for(Loadout.ENGINEER), Weapon.SMG)
