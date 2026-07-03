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
	var best := Utility.choose(Utility.score(w, 1.0), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "retreat", "low HP under fire -> retreat dominates")

func test_calm_with_target_picks_engage() -> void:
	var w := _world(0.0, 1.0, true)
	var best := Utility.choose(Utility.score(w, 1.0), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "engage", "healthy, calm, target present -> engage")

func test_hysteresis_keeps_current_when_all_scores_equal() -> void:
	var scores := [{"behavior": "engage", "score": 0.0}, {"behavior": "take_cover", "score": 0.0}]
	var Util := preload("res://bots/ai/utility.gd")
	assert_eq(Util.choose(scores, "take_cover", Util.HYSTERESIS_BONUS), "take_cover", "all-equal -> stick with current")

func test_hysteresis_keeps_current_on_a_tie() -> void:
	var w := _world(0.5, 0.6, true)
	var keep := Utility.choose(Utility.score(w, 1.0), "take_cover", Utility.HYSTERESIS_BONUS)
	assert_eq(keep, "take_cover", "stickiness bonus prevents per-tick flip-flop")

# --- Suppress fix (batch 6): the flat 0.4 score had no range gate and beat engage (0.7*hp)
# below ~57% HP, rooting wounded bots in the open forever while an enemy was in view.

func test_suppress_scores_zero_beyond_range_gate() -> void:
	var w := _world(0.0, 1.0, true, Utility.SUPPRESS_RANGE + 20.0)
	assert_almost_eq(_score_of(Utility.score(w, 1.0), "suppress"), 0.0, 0.001,
		"an enemy far beyond suppress range does not root the bot")

func test_suppress_scales_with_own_health() -> void:
	var healthy := _score_of(Utility.score(_world(0.0, 1.0, true), 1.0), "suppress")
	var wounded := _score_of(Utility.score(_world(0.0, 0.4, true), 1.0), "suppress")
	assert_true(wounded < healthy, "a wounded bot suppresses less, it does not dig in harder")

func test_wounded_bot_with_target_engages_instead_of_rooting() -> void:
	# 40% HP, calm, enemy in range: engage (0.7*hp) must beat suppress — the pre-batch-6
	# scores flipped this below 57% HP and the bot stood still for the rest of its life.
	var w := _world(0.0, 0.4, true)
	var best := Utility.choose(Utility.score(w, 1.0), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "engage", "wounded but able: fight, don't root")

func test_march_floor_when_target_present_but_nothing_scores() -> void:
	# Distant fresh enemy (beyond suppress range), full HP, no fire: with suppress gated to 0
	# the bot must keep marching on the objective, not fall into retreat-by-default.
	var w := _world(0.0, 1.0, true, Utility.SUPPRESS_RANGE + 20.0)
	assert_true(_score_of(Utility.score(w, 1.0), "push_obj") > 0.0,
		"push_obj keeps a small floor while a target is visible")

# --- M7.5-P3: tuning-driven weights (score gains a weights Dictionary param) ---

func test_weights_override_flips_argmax() -> void:
	# Retreat-dominant world (low HP, heavy fire): a huge engage weight must flip the argmax.
	var w := _world(0.9, 0.2, true)
	var best := Utility.choose(Utility.score(w, 1.0, {"engage": 9.0}), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "engage", "weights dict overrides the hardcoded engage weight")

func test_empty_weights_matches_hardcoded_defaults() -> void:
	# Regression: weights={} must be bit-identical to the historical hardcoded scores.
	var w := _world(0.5, 0.4, true, 10.0)
	var s := Utility.score(w, 1.0, {})
	assert_almost_eq(_score_of(s, "retreat"), (1.0 - 0.4) * 0.5 * 1.6, 1e-6, "retreat default 1.6")
	assert_almost_eq(_score_of(s, "take_cover"), 0.5 * (1.3 - 0.4), 1e-6, "take_cover formula unchanged at coefficient 1.0")
	assert_almost_eq(_score_of(s, "suppress"), 0.4 * 0.4, 1e-6, "suppress default 0.4*hp")
	assert_almost_eq(_score_of(s, "engage"), 0.7 * 1.0 * 0.4, 1e-6, "engage default 0.7*aggression*hp")
	assert_almost_eq(_score_of(s, "push_obj"), 0.05, 1e-6, "push_obj floor with target unchanged")

func test_tuning_file_weights_bit_identical_to_defaults() -> void:
	# The shipped ai_tuning.json weight values equal the historical hardcoded constants,
	# so file-driven scoring must match default scoring exactly.
	var t := preload("res://bots/ai/tuning.gd").load_file("res://data/ai_tuning.json")
	var wt: Dictionary = t.get("weights", {})
	assert_true(not wt.is_empty(), "tuning file has a weights block")
	var w := _world(0.6, 0.3, true, 20.0)
	var a := Utility.score(w, 1.0, {})
	var b := Utility.score(w, 1.0, wt)
	assert_eq(a.size(), b.size(), "same behaviour set either way")
	for i in a.size():
		assert_almost_eq(float(a[i]["score"]), float(b[i]["score"]), 1e-9,
			"file-driven == hardcoded for %s" % String(a[i]["behavior"]))

# --- M7.5-P3: revive / seek_supply / avoid_danger behaviours ---

func test_revive_outranks_engage_for_medic_weights() -> void:
	# Healthy, calm, enemy in view: engage scores 0.7; a medic-weighted revive (>0.7+hysteresis)
	# must win when a downed ally is reachable.
	var w := _world(0.0, 1.0, true)
	w.revive_target = {"id": 7, "pos": Vector3(3, 0, 0), "dist": 3.0}
	var best := Utility.choose(Utility.score(w, 1.0, {"revive": 1.2}), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "revive", "medic-weighted revive beats engage")

func test_revive_score_scaled_down_by_incoming_fire() -> void:
	var calm := _world(0.0, 1.0, false)
	calm.revive_target = {"id": 7, "pos": Vector3(3, 0, 0), "dist": 3.0}
	var hot := _world(1.0, 1.0, false)
	hot.revive_target = {"id": 7, "pos": Vector3(3, 0, 0), "dist": 3.0}
	assert_almost_eq(_score_of(Utility.score(calm, 1.0, {}), "revive"), 0.9, 1e-6, "calm revive = full default weight")
	assert_almost_eq(_score_of(Utility.score(hot, 1.0, {}), "revive"), 0.45, 1e-6, "full incoming fire halves revive")

func test_no_revive_score_without_target() -> void:
	var w := _world(0.0, 1.0, false)
	assert_true(_score_of(Utility.score(w, 1.0, {}), "revive") == -INF, "no revive_target -> behaviour not offered")

func test_seek_supply_wins_when_safe_and_no_enemy() -> void:
	var w := _world(0.0, 0.4, false)
	w.supply_kind = "heal"
	w.supply_bag = {"kind": "heal", "pos": Vector3(5, 0, 0), "team": 0}
	var best := Utility.choose(Utility.score(w, 1.0, {}), "", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "seek_supply", "hurt, safe, bag known -> go resupply (0.5 beats push_obj 0.2)")

func test_seek_supply_suppressed_under_fire() -> void:
	var w := _world(1.0, 0.4, false)
	w.supply_kind = "heal"
	w.supply_bag = {"kind": "heal", "pos": Vector3(5, 0, 0), "team": 0}
	assert_almost_eq(_score_of(Utility.score(w, 1.0, {}), "seek_supply"), 0.0, 1e-6,
		"full incoming fire zeroes seek_supply — resupply only matters when safe")

func test_no_seek_supply_without_known_bag() -> void:
	var w := _world(0.0, 0.4, false)
	w.supply_kind = "heal"   # wants a heal but no bag in view
	assert_true(_score_of(Utility.score(w, 1.0, {}), "seek_supply") == -INF, "no bag -> behaviour not offered")

func test_avoid_danger_dominates_inside_zone() -> void:
	# Even a retreat-dominant world: standing in a grenade/mine zone overrides everything.
	var w := _world(0.9, 0.2, true)
	w.me_pos = Vector3.ZERO
	w.danger_zones = [{"pos": Vector3(1, 0, 0), "radius": 8.0}]
	var best := Utility.choose(Utility.score(w, 1.0, {}), "retreat", Utility.HYSTERESIS_BONUS)
	assert_eq(best, "avoid_danger", "danger zone underfoot is near-absolute (default 5.0)")

func test_no_avoid_danger_when_outside_all_zones() -> void:
	var w := _world(0.0, 1.0, false)
	w.me_pos = Vector3.ZERO
	w.danger_zones = [{"pos": Vector3(100, 0, 0), "radius": 8.0}]
	assert_true(_score_of(Utility.score(w, 1.0, {}), "avoid_danger") == -INF,
		"a distant zone the bot is not inside does not trigger avoidance")
