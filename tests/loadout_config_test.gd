extends TestCase

const ALL_CLASSES := [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]

func test_primary_options_match_matrix() -> void:
	assert_eq(Loadout.primary_options(Loadout.ASSAULT), [Weapon.AR, Weapon.SMG, Weapon.DMR])
	assert_eq(Loadout.primary_options(Loadout.MEDIC), [Weapon.AR, Weapon.SMG])
	assert_eq(Loadout.primary_options(Loadout.ENGINEER), [Weapon.AR, Weapon.SMG])
	assert_eq(Loadout.primary_options(Loadout.SUPPORT), [Weapon.AR, Weapon.SMG, Weapon.LMG])

func test_gadget_options_match_matrix() -> void:
	assert_eq(Loadout.gadget_options(Loadout.ASSAULT), [Loadout.GADGET_C4, Loadout.GADGET_GRAPPLE, Loadout.GADGET_BREACH])
	assert_eq(Loadout.gadget_options(Loadout.MEDIC), [Loadout.GADGET_HEAL, Loadout.GADGET_STIM, Loadout.GADGET_SMOKE_WALL])
	assert_eq(Loadout.gadget_options(Loadout.ENGINEER), [Loadout.GADGET_RPG, Loadout.GADGET_C4, Loadout.GADGET_REPAIR])
	assert_eq(Loadout.gadget_options(Loadout.SUPPORT), [Loadout.GADGET_AMMO, Loadout.GADGET_RIOT_SHIELD, Loadout.GADGET_LMG_NEST])

func test_every_class_has_three_gadget_options() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.gadget_options(c).size(), 3, "class %d has 3 gadgets" % c)

func test_default_gadget_is_always_implemented() -> void:
	for c in ALL_CLASSES:
		assert_contains(Loadout.IMPLEMENTED_GADGETS, Loadout.default_gadget(c))

func test_default_gadget_picks_first_implemented_option() -> void:
	assert_eq(Loadout.default_gadget(Loadout.ENGINEER), Loadout.GADGET_C4)
	assert_eq(Loadout.default_gadget(Loadout.ASSAULT), Loadout.GADGET_C4)
	assert_eq(Loadout.default_gadget(Loadout.MEDIC), Loadout.GADGET_HEAL)
	assert_eq(Loadout.default_gadget(Loadout.SUPPORT), Loadout.GADGET_AMMO)

func test_default_primary_is_ar_for_all() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.default_primary(c), Weapon.AR)

func test_default_armor_is_medium() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.default_armor(c), Armor.MEDIUM)

func test_primary_allowed_enforces_locks() -> void:
	assert_true(Loadout.primary_allowed(Loadout.ASSAULT, Weapon.DMR), "Assault may take DMR")
	assert_false(Loadout.primary_allowed(Loadout.MEDIC, Weapon.DMR), "Medic may not take DMR")
	assert_true(Loadout.primary_allowed(Loadout.SUPPORT, Weapon.LMG), "Support may take LMG")
	assert_false(Loadout.primary_allowed(Loadout.ASSAULT, Weapon.LMG), "only Support takes LMG")
	assert_false(Loadout.primary_allowed(Loadout.ENGINEER, Weapon.RPG), "RPG is never a primary")

func test_lmg_can_equip_support_only() -> void:
	assert_true(Loadout.can_equip(Loadout.SUPPORT, Weapon.LMG))
	assert_false(Loadout.can_equip(Loadout.ASSAULT, Weapon.LMG))
	assert_false(Loadout.can_equip(Loadout.MEDIC, Weapon.LMG))
