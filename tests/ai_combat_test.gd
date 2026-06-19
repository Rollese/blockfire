extends TestCase
const AiCombat := preload("res://bots/ai/behaviors/combat.gd")
const WorldModel := preload("res://bots/ai/world_model.gd")

func test_target_priority_prefers_low_hp_over_nearest() -> void:
	var w := WorldModel.new()
	w.enemies.append({"id": 2, "pos": Vector3(2,0,0), "dist": 2.0, "hp_frac": 1.0, "priority": 0.0, "last_seen_tick": 0})
	w.enemies.append({"id": 3, "pos": Vector3(8,0,0), "dist": 8.0, "hp_frac": 0.2, "priority": 1.0, "last_seen_tick": 0})
	assert_eq(AiCombat.pick_target(w), 3, "low-HP priority target beats nearest")

func test_pick_target_none_when_no_enemies() -> void:
	assert_eq(AiCombat.pick_target(WorldModel.new()), 0, "no enemies -> 0")

func test_pick_target_hysteresis_keeps_current_target() -> void:
	# Two near-equal targets: without a current target the marginally-closer one wins; once locked on,
	# hysteresis keeps the current target (stops per-tick thrash that prevents aim from settling).
	var w := WorldModel.new()
	w.enemies.append({"id": 2, "pos": Vector3(5,0,0), "dist": 5.0, "hp_frac": 1.0, "priority": 0.0, "last_seen_tick": 0})
	w.enemies.append({"id": 3, "pos": Vector3(4.5,0,0), "dist": 4.5, "hp_frac": 1.0, "priority": 0.0, "last_seen_tick": 0})
	assert_eq(AiCombat.pick_target(w, 0), 3, "no current target -> marginally closer enemy")
	assert_eq(AiCombat.pick_target(w, 2), 2, "current target kept despite a marginally closer enemy")

func test_pick_target_tie_breaks_by_lower_id() -> void:
	var w := WorldModel.new()
	# identical dist/hp/priority -> equal score -> lower id must win
	w.enemies.append({"id": 5, "pos": Vector3(4,0,0), "dist": 4.0, "hp_frac": 1.0, "priority": 0.0, "last_seen_tick": 0})
	w.enemies.append({"id": 3, "pos": Vector3(4,0,0), "dist": 4.0, "hp_frac": 1.0, "priority": 0.0, "last_seen_tick": 0})
	assert_eq(AiCombat.pick_target(w), 3, "equal score -> lower id wins")

func test_stop_to_shoot_when_firing() -> void:
	assert_true(AiCombat.should_stop_to_shoot(true), "halt while firing for accuracy")
	assert_false(AiCombat.should_stop_to_shoot(false), "keep moving when not firing")
