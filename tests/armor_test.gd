extends TestCase
## M5.5-P2 armor class pure rules (body/speed multipliers + helmet headshot downgrade).

func test_body_mult_decreases_with_tier() -> void:
	assert_almost_eq(Armor.body_mult(Armor.LIGHT), 1.0)
	assert_almost_eq(Armor.body_mult(Armor.MEDIUM), 0.85)
	assert_almost_eq(Armor.body_mult(Armor.HEAVY), 0.7)

func test_speed_mult_decreases_with_tier() -> void:
	assert_almost_eq(Armor.speed_mult(Armor.LIGHT), 1.0)
	assert_true(Armor.speed_mult(Armor.HEAVY) < Armor.speed_mult(Armor.MEDIUM))
	assert_true(Armor.speed_mult(Armor.MEDIUM) < Armor.speed_mult(Armor.LIGHT))

func test_heavy_helmet_downgrades_finishing_headshot() -> void:
	# A finishing AR headshot (~50) on a 40-HP victim instant-kills LIGHT/MEDIUM, but HEAVY's
	# helmet (50 * 0.7 = 35 < 40) downgrades it off the instant-kill, routing through as body damage.
	assert_true(Armor.headshot_lethal(Armor.LIGHT, 50, 40))
	assert_true(Armor.headshot_lethal(Armor.MEDIUM, 50, 40))
	assert_false(Armor.headshot_lethal(Armor.HEAVY, 50, 40))

func test_strong_headshot_still_lethal_vs_heavy() -> void:
	# A point-blank DMR headshot (45 * 2.0 = 90) still finishes a 40-HP HEAVY (90 * 0.7 = 63 >= 40).
	assert_true(Armor.headshot_lethal(Armor.HEAVY, 90, 40))

func test_loadout_armor_default_per_class_spans_all_tiers() -> void:
	# Recon was removed (M12-P1); the four live classes must map onto valid tiers and
	# collectively span all three so the fleet exercises armor-TTK variance.
	var seen := {}
	for cls in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		var a := Loadout.armor_for(cls)
		assert_true(a == Armor.LIGHT or a == Armor.MEDIUM or a == Armor.HEAVY)
		seen[a] = true
	assert_true(seen.has(Armor.LIGHT) and seen.has(Armor.MEDIUM) and seen.has(Armor.HEAVY),
		"the four classes span LIGHT/MEDIUM/HEAVY")
