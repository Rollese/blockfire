class_name Utility
extends RefCounted
## Pure behaviour scoring + argmax with hysteresis. Curves are deliberately simple;
## feel-tuning of the weights is deferred to the renderer (docs/specs/bot-ai.md §2.2, §6).

const HYSTERESIS_BONUS := 0.15
const SUPPRESS_RANGE := 60.0   # m: only pin targets near enough to matter — a distant contact must not root the bot

## Returns Array[{behavior:String, score:float}]. `aggression` is a difficulty-profile scalar (1.0 = baseline).
## `weights` (M7.5-P3): per-behaviour weight overrides from data/ai_tuning.json; every missing
## key falls back to the historical hardcoded value, so weights={} is bit-identical to the old scoring.
static func score(w: WorldModel, aggression: float, weights: Dictionary = {}) -> Array:
	var hp := w.metadata_hp_frac
	var fire := w.incoming_fire
	var has_target := w.enemies.size() > 0
	var nearest := INF
	for e in w.enemies:
		nearest = minf(nearest, float(e["dist"]))
	var out: Array[Dictionary] = []
	out.append({"behavior": "retreat", "score": (1.0 - hp) * fire * float(weights.get("retreat", 1.6))})
	# take_cover rises with pressure and with missing health; the +0.3*fire floor keeps a
	# baseline cover bias under fire even at full HP. Equivalent to fire * (1.3 - hp).
	# The tuning weight scales the whole formula (coefficient, default 1.0).
	out.append({"behavior": "take_cover", "score": float(weights.get("take_cover", 1.0)) * fire * (1.3 - hp)})
	# suppress is range-gated and hp-scaled (batch 6): the old flat 0.4 beat engage (0.7*hp)
	# below ~57% HP, permanently rooting wounded bots in the open while any enemy was in view.
	# Scaled by hp it never outranks engage in the argmax; it wins only as decide()'s fallback
	# while the reaction gate holds fire — its actual job.
	out.append({"behavior": "suppress", "score": (float(weights.get("suppress", 0.4)) * hp if nearest <= SUPPRESS_RANGE else 0.0)})
	out.append({"behavior": "engage", "score": (float(weights.get("engage", 0.7)) * aggression if has_target else 0.0) * hp})
	# small floor while a target is visible: with suppress gated off (distant contact) the
	# reaction-gate fallback must keep the bot marching, not drop it into retreat-by-default.
	# One knob scales both values (floor = weight * 0.25, i.e. 0.05 at the 0.2 default).
	var push_w := float(weights.get("push_obj", 0.2))
	out.append({"behavior": "push_obj", "score": (push_w if not has_target else push_w * 0.25)})
	# M7.5-P3 support behaviours. avoid_danger is near-absolute: standing in a grenade/mine
	# zone overrides everything (weight default 5.0). revive outranks engage for medics via
	# the weights profile; seek_supply only matters when safe (scaled down by incoming fire).
	if not w.danger_zones.is_empty() and not AiSupport.flee_vector(w.me_pos, w.danger_zones).is_zero_approx():
		out.append({"behavior": "avoid_danger", "score": float(weights.get("avoid_danger", 5.0))})
	if not w.revive_target.is_empty():
		out.append({"behavior": "revive", "score": float(weights.get("revive", 0.9)) * (1.0 - w.incoming_fire * 0.5)})
	if w.supply_kind != "" and not w.supply_bag.is_empty():
		out.append({"behavior": "seek_supply", "score": float(weights.get("seek_supply", 0.5)) * (1.0 - w.incoming_fire)})
	return out

## Argmax with a stickiness bonus added to `current` so near-ties don't flip-flop.
static func choose(scores: Array, current: String, hysteresis: float) -> String:
	var best := ""
	var best_s := -INF
	for s in scores:
		var v: float = float(s["score"])
		if String(s["behavior"]) == current:
			v += hysteresis
		if v > best_s:
			best_s = v; best = String(s["behavior"])
	return best
