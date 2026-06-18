class_name Utility
extends RefCounted
## Pure behaviour scoring + argmax with hysteresis. Curves are deliberately simple;
## feel-tuning of the weights is deferred to the renderer (docs/specs/bot-ai.md §2.2, §6).

const HYSTERESIS_BONUS := 0.15

## Returns Array[{behavior:String, score:float}]. `aggression` is a difficulty-profile scalar (1.0 = baseline).
static func score(w: WorldModel, aggression: float, _current: String) -> Array:
	var hp := w.metadata_hp_frac
	var fire := w.incoming_fire
	var has_target := w.enemies.size() > 0
	var out: Array[Dictionary] = []
	out.append({"behavior": "retreat", "score": (1.0 - hp) * fire * 1.6})
	# take_cover rises with pressure and with missing health; the +0.3*fire floor keeps a
	# baseline cover bias under fire even at full HP. Equivalent to fire * (1.3 - hp).
	out.append({"behavior": "take_cover", "score": fire * (1.3 - hp)})
	out.append({"behavior": "suppress", "score": (0.4 if w.enemies.size() > 0 else 0.0)})
	out.append({"behavior": "engage", "score": (0.7 * aggression if has_target else 0.0) * hp})
	out.append({"behavior": "push_obj", "score": (0.2 if not has_target else 0.0)})
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
