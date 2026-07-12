extends TestCase

const ALL_CLASSES := [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]

func setup() -> void:
	Weapon.reset_registry()
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "weapons.json loads: %s" % res.get("error", ""))

func teardown() -> void:
	Weapon.reset_registry()

func test_primary_options_are_variants_of_allowed_archetypes() -> void:
	for c in ALL_CLASSES:
		var expected: Array = []
		for a in Loadout.allowed_archetypes(c):
			expected.append_array(Weapon.variants_of(a))
		assert_eq(Loadout.primary_options(c), expected, "class %d primary_options == concatenated variants" % c)
		assert_gt(Loadout.primary_options(c).size(), 0, "class %d has selectable variants" % c)
	# independent spot-check: Assault's picker lists AR+DMR variants but no LMG variant
	var assault := Loadout.primary_options(Loadout.ASSAULT)
	assert_contains(assault, Weapon.default_variant(Weapon.AR))
	assert_contains(assault, Weapon.variants_of(Weapon.DMR)[0])
	assert_true(not (Weapon.variants_of(Weapon.LMG)[0] in assault), "Assault picker excludes LMG variants")

func test_allowed_archetypes_match_matrix() -> void:
	# The archetype allow-list that class gating is expressed against (stable across the
	# weapon-variants switch; only primary_options() expands to variant ids later).
	assert_eq(Loadout.allowed_archetypes(Loadout.ASSAULT), [Weapon.AR, Weapon.SMG, Weapon.DMR])
	assert_eq(Loadout.allowed_archetypes(Loadout.SUPPORT), [Weapon.AR, Weapon.SMG, Weapon.LMG])
	assert_eq(Loadout.allowed_archetypes(Loadout.MEDIC), [Weapon.AR, Weapon.SMG])

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
	assert_eq(Loadout.default_gadget(Loadout.ENGINEER), Loadout.GADGET_RPG)
	assert_eq(Loadout.default_gadget(Loadout.ASSAULT), Loadout.GADGET_C4)
	assert_eq(Loadout.default_gadget(Loadout.MEDIC), Loadout.GADGET_HEAL)
	assert_eq(Loadout.default_gadget(Loadout.SUPPORT), Loadout.GADGET_AMMO)

func test_default_primary_is_ar_variant_for_all() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.default_primary(c), Weapon.default_variant(Weapon.AR))
		assert_eq(Weapon.archetype_of(Loadout.default_primary(c)), Weapon.AR)

func test_default_armor_is_medium() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.default_armor(c), Armor.MEDIUM)

func test_is_primary_allowed_enforces_locks() -> void:
	assert_true(Loadout.is_primary_allowed(Loadout.ASSAULT, Weapon.DMR), "Assault may take DMR")
	assert_false(Loadout.is_primary_allowed(Loadout.MEDIC, Weapon.DMR), "Medic may not take DMR")
	assert_true(Loadout.is_primary_allowed(Loadout.SUPPORT, Weapon.LMG), "Support may take LMG")
	assert_false(Loadout.is_primary_allowed(Loadout.ASSAULT, Weapon.LMG), "only Support takes LMG")
	assert_false(Loadout.is_primary_allowed(Loadout.ENGINEER, Weapon.RPG), "RPG is never a primary")
	var dmr_v := int(Weapon.variants_of(Weapon.DMR)[0])   # SVD-K
	var lmg_v := int(Weapon.variants_of(Weapon.LMG)[0])   # PKP
	assert_true(Loadout.is_primary_allowed(Loadout.ASSAULT, dmr_v), "Assault may take SVD-K (DMR variant)")
	assert_false(Loadout.is_primary_allowed(Loadout.MEDIC, dmr_v), "Medic may not take a DMR variant")
	assert_true(Loadout.is_primary_allowed(Loadout.SUPPORT, lmg_v), "Support may take PKP (LMG variant)")
	assert_false(Loadout.is_primary_allowed(Loadout.ASSAULT, lmg_v), "only Support takes an LMG variant")

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

func _attach() -> Attachment:
	var res := Attachment.from_dict({"attachments": [
		{"id": "iron", "slot": "optic"},
		{"id": "reddot", "slot": "optic"},
		{"id": "standard", "slot": "barrel"},
		{"id": "none_ub", "slot": "underbarrel"},
	]})
	return res["catalog"]

func test_default_loadout_is_self_consistent() -> void:
	for c in ALL_CLASSES:
		var d := Loadout.default_loadout(c)
		assert_eq(Loadout.sanitize(d, _attach()), d, "default_loadout(%d) stable under sanitize" % c)

func test_sanitize_is_idempotent() -> void:
	var raw := {"class": Loadout.SUPPORT, "primary": int(Weapon.variants_of(Weapon.LMG)[0]), "secondary": Weapon.PISTOL,
		"gadget": Loadout.GADGET_AMMO, "armor": Armor.HEAVY, "grenade": Grenade.SMOKE,
		"attachments": {"optic": "reddot", "barrel": "standard", "underbarrel": "none_ub"}}
	var once := Loadout.sanitize(raw, _attach())
	assert_eq(Loadout.sanitize(once, _attach()), once, "sanitize twice == once")

func test_sanitize_rejects_illegal_primary() -> void:
	var dmr_v := int(Weapon.variants_of(Weapon.DMR)[0])   # SVD-K
	var out := Loadout.sanitize({"class": Loadout.MEDIC, "primary": dmr_v}, _attach())
	assert_eq(int(out["primary"]), Loadout.default_primary(Loadout.MEDIC))
	assert_eq(Weapon.archetype_of(int(out["primary"])), Weapon.AR)

func test_sanitize_rejects_bare_archetype_primary() -> void:
	var out := Loadout.sanitize({"class": Loadout.SUPPORT, "primary": Weapon.LMG}, _attach())
	assert_eq(int(out["primary"]), Loadout.default_primary(Loadout.SUPPORT))
	assert_true(Weapon.is_variant(int(out["primary"])), "sanitized primary is always a real variant")

func test_sanitize_rpg_never_a_primary() -> void:
	var out := Loadout.sanitize({"class": Loadout.ENGINEER, "primary": Weapon.RPG}, _attach())
	assert_ne(int(out["primary"]), Weapon.RPG)

func test_sanitize_unbuilt_gadget_falls_to_default() -> void:
	# M19-P5 Task 5 implemented RIOT_SHIELD, so GRAPPLE (Assault's still-unbuilt option) is now the
	# stand-in for "offered but not yet built."
	var out := Loadout.sanitize({"class": Loadout.ASSAULT, "gadget": Loadout.GADGET_GRAPPLE}, _attach())
	assert_eq(int(out["gadget"]), Loadout.GADGET_C4)

func test_sanitize_out_of_set_gadget_falls_to_default() -> void:
	var out := Loadout.sanitize({"class": Loadout.SUPPORT, "gadget": Loadout.GADGET_HEAL}, _attach())
	assert_eq(int(out["gadget"]), Loadout.GADGET_AMMO)

func test_sanitize_clamps_class_armor_grenade() -> void:
	var out := Loadout.sanitize({"class": 99, "armor": 99, "grenade": 99}, _attach())
	assert_eq(int(out["class"]), Loadout.ASSAULT)
	assert_eq(int(out["armor"]), Armor.MEDIUM)
	assert_eq(int(out["grenade"]), Grenade.FRAG)

func test_sanitize_drops_bad_attachment_ids() -> void:
	var out := Loadout.sanitize({"class": Loadout.ASSAULT,
		"attachments": {"optic": "not_a_real_id", "barrel": "none_ub", "underbarrel": "none_ub"}}, _attach())
	assert_eq(String(out["attachments"]["optic"]), String(Loadout.default_attachments()["optic"]))
	assert_eq(String(out["attachments"]["barrel"]), String(Loadout.default_attachments()["barrel"]))

func test_sanitize_secondary_is_always_pistol() -> void:
	var out := Loadout.sanitize({"class": Loadout.ASSAULT, "secondary": Weapon.AR}, _attach())
	assert_eq(int(out["secondary"]), Weapon.PISTOL)
