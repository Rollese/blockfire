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

func test_is_primary_allowed_enforces_locks() -> void:
	assert_true(Loadout.is_primary_allowed(Loadout.ASSAULT, Weapon.DMR), "Assault may take DMR")
	assert_false(Loadout.is_primary_allowed(Loadout.MEDIC, Weapon.DMR), "Medic may not take DMR")
	assert_true(Loadout.is_primary_allowed(Loadout.SUPPORT, Weapon.LMG), "Support may take LMG")
	assert_false(Loadout.is_primary_allowed(Loadout.ASSAULT, Weapon.LMG), "only Support takes LMG")
	assert_false(Loadout.is_primary_allowed(Loadout.ENGINEER, Weapon.RPG), "RPG is never a primary")

func test_every_primary_option_passes_can_equip() -> void:
	# primary_options (the menu) and can_equip (the authority) must never disagree.
	for c in ALL_CLASSES:
		for wid in Loadout.primary_options(c):
			assert_true(Loadout.can_equip(c, wid), "class %d option %d must pass can_equip" % [c, wid])

func test_lmg_can_equip_support_only() -> void:
	assert_true(Loadout.can_equip(Loadout.SUPPORT, Weapon.LMG))
	assert_false(Loadout.can_equip(Loadout.ASSAULT, Weapon.LMG))
	assert_false(Loadout.can_equip(Loadout.MEDIC, Weapon.LMG))

func test_class_traits_blast_engineer_only() -> void:
	assert_almost_eq(float(Loadout.class_traits(Loadout.ENGINEER)["blast_mult"]), 1.2)
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.SUPPORT]:
		assert_almost_eq(float(Loadout.class_traits(c)["blast_mult"]), 1.0)

func test_class_traits_grenades_support_five_others_three() -> void:
	assert_eq(int(Loadout.class_traits(Loadout.SUPPORT)["grenade_count"]), 5)
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER]:
		assert_eq(int(Loadout.class_traits(c)["grenade_count"]), 3)

func test_class_traits_regen_fast_assault_only() -> void:
	assert_true(bool(Loadout.class_traits(Loadout.ASSAULT)["regen_fast"]))
	for c in [Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		assert_false(bool(Loadout.class_traits(c)["regen_fast"]))

func test_class_traits_reserve_bonus_support_only() -> void:
	assert_gt(float(Loadout.class_traits(Loadout.SUPPORT)["reserve_mult"]), 1.0)
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER]:
		assert_almost_eq(float(Loadout.class_traits(c)["reserve_mult"]), 1.0)

func test_class_traits_medic_and_engineer_signatures() -> void:
	assert_true(bool(Loadout.class_traits(Loadout.MEDIC)["revive_fast"]))
	assert_eq(int(Loadout.class_traits(Loadout.MEDIC)["bandages"]), Revive.MEDIC_BANDAGE_COUNT)
	assert_eq(int(Loadout.class_traits(Loadout.ASSAULT)["bandages"]), Revive.BANDAGE_COUNT)
	assert_true(bool(Loadout.class_traits(Loadout.ENGINEER)["sledgehammer"]))
	assert_false(bool(Loadout.class_traits(Loadout.ASSAULT)["sledgehammer"]))

func test_trait_blurbs_nonempty_for_all_classes() -> void:
	for c in ALL_CLASSES:
		assert_gt(Loadout.trait_blurbs(c).size(), 0, "class %d has blurbs" % c)

func _joined(cls: int) -> String:
	return " || ".join(Loadout.trait_blurbs(cls))

func test_trait_blurbs_mention_each_signature_perk() -> void:
	assert_contains(_joined(Loadout.ASSAULT), "Combat Vigor")
	assert_contains(_joined(Loadout.ASSAULT), "DMR")
	assert_contains(_joined(Loadout.MEDIC), "revive")
	assert_contains(_joined(Loadout.MEDIC), "20")
	assert_contains(_joined(Loadout.ENGINEER), "blast")
	assert_contains(_joined(Loadout.ENGINEER), "Sledgehammer")
	assert_contains(_joined(Loadout.SUPPORT), "LMG")
	assert_contains(_joined(Loadout.SUPPORT), "grenade")

func test_trait_blurbs_cover_every_active_trait() -> void:
	for c in ALL_CLASSES:
		var t := Loadout.class_traits(c)
		var active := 0
		if bool(t["regen_fast"]): active += 1
		if bool(t["revive_fast"]): active += 1
		if bool(t["sledgehammer"]): active += 1
		if float(t["blast_mult"]) > 1.0: active += 1
		if int(t["grenade_count"]) > 3: active += 1
		if float(t["reserve_mult"]) > 1.0: active += 1
		assert_true(Loadout.trait_blurbs(c).size() >= active,
			"class %d: %d blurbs >= %d active traits" % [c, Loadout.trait_blurbs(c).size(), active])
