extends TestCase

func test_each_class_maps_to_a_weapon() -> void:
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		var wid := Loadout.weapon_for(c)
		assert_true(wid in [Weapon.AR, Weapon.SMG], "valid default weapon for class %d" % c)

func test_human_class_roll_never_engineer() -> void:
	for _i in 300:
		var c := Loadout.random_class_no_engineer()
		assert_true(c != Loadout.ENGINEER, "human roll never ENGINEER")
		assert_true(c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.SUPPORT], "valid non-engineer class")

func test_class_roll_in_range_no_recon() -> void:
	for _i in 300:
		var c := Loadout.random_class()
		assert_true(c >= Loadout.ASSAULT and c <= Loadout.SUPPORT, "class in 0..3 (no Recon)")

func test_default_weapons() -> void:
	assert_eq(Loadout.weapon_for(Loadout.ENGINEER), Weapon.SMG)
	assert_eq(Loadout.weapon_for(Loadout.ASSAULT), Weapon.AR)
	assert_eq(Loadout.weapon_for(Loadout.MEDIC), Weapon.AR)
	assert_eq(Loadout.weapon_for(Loadout.SUPPORT), Weapon.AR)

func test_gadget_per_class_default() -> void:
	assert_eq(Loadout.gadget_for(Loadout.ENGINEER), Loadout.GADGET_C4)   # default option; claymore via gadget_for_player
	assert_eq(Loadout.gadget_for(Loadout.MEDIC), Loadout.GADGET_HEAL)
	assert_eq(Loadout.gadget_for(Loadout.SUPPORT), Loadout.GADGET_AMMO)
	assert_eq(Loadout.gadget_for(Loadout.ASSAULT), Loadout.GADGET_NONE)

func test_rpg_no_longer_weapon_gated() -> void:
	# M19: RPG is an Engineer *gadget*, not a weapon-slot choice — can_equip no longer gates it
	# (it can still never be a primary; see test_sanitize_rpg_never_a_primary).
	assert_true(Loadout.can_equip(Loadout.ENGINEER, Weapon.RPG))
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.RPG), "RPG is gadget-only, not weapon-gated")
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.AR), "AR unrestricted")

func test_non_rpg_non_dmr_weapons_unrestricted() -> void:
	# AR / SMG / etc. have no class restriction (only RPG and DMR are gated).
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.AR))
	assert_true(Loadout.can_equip(Loadout.MEDIC, Weapon.SMG))

func test_default_attachments_has_three_slots() -> void:
	var a := Loadout.default_attachments()
	assert_true(a.has("optic") and a.has("barrel") and a.has("underbarrel"))

func test_dmr_only_assault_can_equip() -> void:
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.DMR), "Assault may equip DMR")
	assert_false(Loadout.can_equip(Loadout.MEDIC, Weapon.DMR), "Medic may not")
	assert_false(Loadout.can_equip(Loadout.ENGINEER, Weapon.DMR), "Engineer may not")
	assert_false(Loadout.can_equip(Loadout.SUPPORT, Weapon.DMR), "Support may not")

func test_engineer_gadget_options_are_rpg_c4_repair() -> void:
	assert_eq(Loadout.gadget_options(Loadout.ENGINEER), [Loadout.GADGET_RPG, Loadout.GADGET_C4, Loadout.GADGET_REPAIR])
	assert_true(Loadout.is_valid_gadget(Loadout.ENGINEER, Loadout.GADGET_C4))
	assert_false(Loadout.is_valid_gadget(Loadout.ENGINEER, Loadout.GADGET_HEAL), "engineer can't pick heal")

func test_single_gadget_classes_validate() -> void:
	assert_true(Loadout.is_valid_gadget(Loadout.MEDIC, Loadout.GADGET_HEAL))
	assert_false(Loadout.is_valid_gadget(Loadout.MEDIC, Loadout.GADGET_C4))
	assert_true(Loadout.is_valid_gadget(Loadout.SUPPORT, Loadout.GADGET_AMMO))

func test_gadget_for_player_engineer_splits_by_id() -> void:
	# Engineers alternate C4 / claymore by id parity so the fleet exercises both.
	assert_eq(Loadout.gadget_for_player(Loadout.ENGINEER, 2), Loadout.GADGET_C4)
	assert_eq(Loadout.gadget_for_player(Loadout.ENGINEER, 3), Loadout.GADGET_MINE)
	# Non-engineers ignore id and use their single gadget.
	assert_eq(Loadout.gadget_for_player(Loadout.MEDIC, 3), Loadout.GADGET_HEAL)
	assert_eq(Loadout.gadget_for_player(Loadout.ASSAULT, 7), Loadout.GADGET_NONE)

func test_secondary_is_pistol_for_all_classes() -> void:
	for cls in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		assert_eq(Loadout.secondary_for(cls), Weapon.PISTOL)

func test_can_equip_pistol_any_class() -> void:
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.PISTOL))
	assert_true(Loadout.can_equip(Loadout.SUPPORT, Weapon.PISTOL))

func test_sledge_engineer_only() -> void:
	assert_true(Loadout.has_sledgehammer(Loadout.ENGINEER))
	assert_false(Loadout.has_sledgehammer(Loadout.ASSAULT))
	assert_false(Loadout.has_sledgehammer(Loadout.MEDIC))
	assert_false(Loadout.has_sledgehammer(Loadout.SUPPORT))
