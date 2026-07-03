class_name Utility
extends RefCounted
## Pure behaviour scoring + argmax with hysteresis. Curves are deliberately simple;
## feel-tuning of the weights is deferred to the renderer (docs/specs/bot-ai.md §2.2, §6).

const HYSTERESIS_BONUS := 0.15
const SUPPRESS_RANGE := 60.0   # m: only pin targets near enough to matter — a distant contact must not root the bot

## Returns Array[{behavior:String, score:float}]. `aggression` is a difficulty-profile scalar (1.0 = baseline).
static func score(w: WorldModel, aggression: float, _current: String) -> Array:
	var hp := w.metadata_hp_frac
	var fire := w.incoming_fire
	var has_target := w.enemies.size() > 0
	var nearest := INF
	for e in w.enemies:
		nearest = minf(nearest, float(e["dist"]))
	var out: Array[Dictionary] = []
	out.append({"behavior": "retreat", "score": (1.0 - hp) * fire * 1.6})
	# take_cover rises with pressure and with missing health; the +0.3*fire floor keeps a
	# baseline cover bias under fire even at full HP. Equivalent to fire * (1.3 - hp).
	out.append({"behavior": "take_cover", "score": fire * (1.3 - hp)})
	# suppress is range-gated and hp-scaled (batch 6): the old flat 0.4 beat engage (0.7*hp)
	# below ~57% HP, permanently rooting wounded bots in the open while any enemy was in view.
	# Scaled by hp it never outranks engage in the argmax; it wins only as decide()'s fallback
	# while the reaction gate holds fire — its actual job.
	out.append({"behavior": "suppress", "score": (0.4 * hp if nearest <= SUPPRESS_RANGE else 0.0)})
	out.append({"behavior": "engage", "score": (0.7 * aggression if has_target else 0.0) * hp})
	# small floor while a target is visible: with suppress gated off (distant contact) the
	# reaction-gate fallback must keep the bot marching, not drop it into retreat-by-default.
	out.append({"behavior": "push_obj", "score": (0.2 if not has_target else 0.05)})
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
