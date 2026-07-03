extends TestCase
const Utility := preload("res://bots/ai/utility.gd")
const WorldModel := preload("res://bots/ai/world_model.gd")

func _world(fire: float, hp_frac: float, has_enemy: bool, enemy_dist := 5.0) -> WorldModel:
	var w := WorldModel.new()
	w.incoming_fire = fire
	w.metadata_hp_frac = hp_frac
	if has_enemy:
		w.enemies.append({"id": 2, "pos": Vector3(enemy_dist,0,0), "stance":0, "dist":enemy_dist, "last_seen_tick":0})
	return w

func _score_of(scores: Array, behavior: String) -> float:
	for s in scores:
		if String(s["behavior"]) == behavior:
			return float(s["score"])
	return -INF

func test_high_pressure_low_hp_picks_retreat() -> void:
	var w := _world(0.9, 0.2, true)
	var best := Utility.choose(Utility.score(w, 1.0, ""), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "retreat", "low HP under fire -> retreat dominates")

func test_calm_with_target_picks_engage() -> void:
	var w := _world(0.0, 1.0, true)
	var best := Utility.choose(Utility.score(w, 1.0, ""), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "engage", "healthy, calm, target present -> engage")

func test_hysteresis_keeps_current_when_all_scores_equal() -> void:
	var scores := [{"behavior": "engage", "score": 0.0}, {"behavior": "take_cover", "score": 0.0}]
	var Util := preload("res://bots/ai/utility.gd")
	assert_eq(Util.choose(scores, "take_cover", Util.HYSTERESIS_BONUS), "take_cover", "all-equal -> stick with current")

func test_hysteresis_keeps_current_on_a_tie() -> void:
	var w := _world(0.5, 0.6, true)
	var keep := Utility.choose(Utility.score(w, 1.0, "take_cover"), "take_cover", Utility.HYSTERESIS_BONUS)
	assert_eq(keep, "take_cover", "stickiness bonus prevents per-tick flip-flop")

# --- Suppress fix (batch 6): the flat 0.4 score had no range gate and beat engage (0.7*hp)
# below ~57% HP, rooting wounded bots in the open forever while an enemy was in view.

func test_suppress_scores_zero_beyond_range_gate() -> void:
	var w := _world(0.0, 1.0, true, Utility.SUPPRESS_RANGE + 20.0)
	assert_almost_eq(_score_of(Utility.score(w, 1.0, ""), "suppress"), 0.0, 0.001,
		"an enemy far beyond suppress range does not root the bot")

func test_suppress_scales_with_own_health() -> void:
	var healthy := _score_of(Utility.score(_world(0.0, 1.0, true), 1.0, ""), "suppress")
	var wounded := _score_of(Utility.score(_world(0.0, 0.4, true), 1.0, ""), "suppress")
	assert_true(wounded < healthy, "a wounded bot suppresses less, it does not dig in harder")

func test_wounded_bot_with_target_engages_instead_of_rooting() -> void:
	# 40% HP, calm, enemy in range: engage (0.7*hp) must beat suppress — the pre-batch-6
	# scores flipped this below 57% HP and the bot stood still for the rest of its life.
	var w := _world(0.0, 0.4, true)
	var best := Utility.choose(Utility.score(w, 1.0, ""), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "engage", "wounded but able: fight, don't root")

func test_march_floor_when_target_present_but_nothing_scores() -> void:
	# Distant fresh enemy (beyond suppress range), full HP, no fire: with suppress gated to 0
	# the bot must keep marching on the objective, not fall into retreat-by-default.
	var w := _world(0.0, 1.0, true, Utility.SUPPRESS_RANGE + 20.0)
	assert_true(_score_of(Utility.score(w, 1.0, ""), "push_obj") > 0.0,
		"push_obj keeps a small floor while a target is visible")
