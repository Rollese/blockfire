extends TestCase

func test_each_class_maps_to_a_weapon() -> void:
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT, Loadout.RECON]:
		var wid := Loadout.weapon_for(c)
		assert_true(wid in [Weapon.AR, Weapon.SMG, Weapon.DMR], "valid weapon for class %d" % c)

func test_human_class_roll_never_engineer() -> void:
	# Humans must never be assigned ENGINEER (no click-fire gun on its RPG-primary variant).
	for _i in 300:
		var c := Loadout.random_class_no_engineer()
		assert_true(c != Loadout.ENGINEER, "human roll never ENGINEER")
		assert_true(c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.SUPPORT, Loadout.RECON], "valid non-engineer class")

func test_recon_uses_dmr_engineer_uses_smg() -> void:
	assert_eq(Loadout.weapon_for(Loadout.RECON), Weapon.DMR)
	assert_eq(Loadout.weapon_for(Loadout.ENGINEER), Weapon.SMG)

func test_gadget_per_class() -> void:
	assert_eq(Loadout.gadget_for(Loadout.ENGINEER), Loadout.GADGET_C4)
	assert_eq(Loadout.gadget_for(Loadout.RECON), Loadout.GADGET_MINE)
	assert_eq(Loadout.gadget_for(Loadout.MEDIC), Loadout.GADGET_HEAL)
	assert_eq(Loadout.gadget_for(Loadout.SUPPORT), Loadout.GADGET_AMMO)
	assert_eq(Loadout.gadget_for(Loadout.ASSAULT), Loadout.GADGET_NONE)

func test_rpg_only_engineer_can_equip() -> void:
	assert_true(Loadout.can_equip(Loadout.ENGINEER, Weapon.RPG))
	assert_false(Loadout.can_equip(Loadout.ASSAULT, Weapon.RPG))
	assert_false(Loadout.can_equip(Loadout.RECON, Weapon.RPG))

func test_non_rpg_weapons_unrestricted() -> void:
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.AR))
	assert_true(Loadout.can_equip(Loadout.RECON, Weapon.DMR))

func test_default_attachments_has_three_slots() -> void:
	var a := Loadout.default_attachments()
	assert_true(a.has("optic") and a.has("barrel") and a.has("underbarrel"))
