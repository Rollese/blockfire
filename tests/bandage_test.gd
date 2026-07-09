extends TestCase
## M16 bandage pure rules: channel timing (medic halving) and the victim-first pouch rule.

func test_channel_ticks_medic_is_half() -> void:
	assert_eq(Bandage.channel_ticks(false), Bandage.BANDAGE_TICKS)
	assert_eq(Bandage.channel_ticks(true), Bandage.BANDAGE_TICKS / 2)
	assert_true(Bandage.channel_ticks(true) < Bandage.channel_ticks(false))

func test_pick_source_victim_first() -> void:
	# Victim's own pouch pays first ("first-aid kit on your chest").
	assert_eq(Bandage.pick_source(3, 3), 0)
	assert_eq(Bandage.pick_source(1, 0), 0)

func test_pick_source_falls_back_to_helper() -> void:
	# Victim empty -> helper's charge is spent.
	assert_eq(Bandage.pick_source(0, 2), 1)

func test_pick_source_none_when_both_empty() -> void:
	assert_eq(Bandage.pick_source(0, 0), -1)

func test_heal_amount_positive() -> void:
	assert_true(Bandage.BANDAGE_HEAL > 0)

func test_medic_bandage_count_larger() -> void:
	# Medic carries far more bandages than the base class.
	assert_eq(Revive.bandage_count_for(false), Revive.BANDAGE_COUNT)
	assert_eq(Revive.bandage_count_for(true), Revive.MEDIC_BANDAGE_COUNT)
	assert_true(Revive.MEDIC_BANDAGE_COUNT > Revive.BANDAGE_COUNT)
