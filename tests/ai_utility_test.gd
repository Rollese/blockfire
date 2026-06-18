extends TestCase
const Utility := preload("res://bots/ai/utility.gd")
const WorldModel := preload("res://bots/ai/world_model.gd")

func _world(fire: float, hp_frac: float, has_enemy: bool) -> WorldModel:
	var w := WorldModel.new()
	w.incoming_fire = fire
	w.metadata_hp_frac = hp_frac
	if has_enemy:
		w.enemies.append({"id": 2, "pos": Vector3(5,0,0), "stance":0, "dist":5.0, "last_seen_tick":0})
	return w

func test_high_pressure_low_hp_picks_retreat() -> void:
	var w := _world(0.9, 0.2, true)
	var best := Utility.choose(Utility.score(w, 1.0, ""), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "retreat", "low HP under fire -> retreat dominates")

func test_calm_with_target_picks_engage() -> void:
	var w := _world(0.0, 1.0, true)
	var best := Utility.choose(Utility.score(w, 1.0, ""), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "engage", "healthy, calm, target present -> engage")

func test_hysteresis_keeps_current_on_a_tie() -> void:
	var w := _world(0.5, 0.6, true)
	var keep := Utility.choose(Utility.score(w, 1.0, "take_cover"), "take_cover", Utility.HYSTERESIS_BONUS)
	assert_eq(keep, "take_cover", "stickiness bonus prevents per-tick flip-flop")
