class_name AiDriver
extends RefCounted
## Per-bot orchestrator: perception -> utility -> behaviour -> humanized primitive intent.
## One instance per bot. The bot_driver shell calls observe() + decide() each tick and
## sends the returned intent. See docs/specs/bot-ai.md §4, §6.

var _perc: Perception
var _human: Humanize
var _profile: Dictionary
var _current_behavior := ""

func _init(global_seed: int, bot_index: int, profile_name: String) -> void:
	_perc = Perception.new()
	_human = Humanize.new(global_seed, bot_index)
	var t := AiTuning.load_file("res://data/ai_tuning.json")
	_profile = t.get("profiles", {}).get(profile_name, {"reaction_delay_ticks": 9, "aim_error_deg": 3.0, "aim_settle_ticks": 6, "aggression": 1.0})

## Update perception state (memory + reaction gate) from the latest snapshot view.
func observe(my_id: int, view: Dictionary, vview: Dictionary, structs: Dictionary, match_points: Array, now: int) -> void:
	_perc.build(my_id, view, vview, structs, match_points, now)

## Produce the input intent for this tick: {move_x, move_y, yaw, pitch, buttons, stance, behavior}.
func decide(my_id: int, view: Dictionary, vview: Dictionary, structs: Dictionary, match_points: Array, now: int) -> Dictionary:
	var w := _perc.build(my_id, view, vview, structs, match_points, now)
	var me: EntityState = view.get(my_id)
	w.metadata_hp_frac = (float(me.health) / 100.0) if me else 1.0
	var scores := Utility.score(w, float(_profile.get("aggression", 1.0)), _current_behavior)
	var behavior := Utility.choose(scores, _current_behavior, Utility.HYSTERESIS_BONUS)
	# Reaction gate: if the top choice is "engage" but no target has cleared the delay,
	# fall back to the next-best behavior so the behavior label reflects the gate.
	var tgt := AiCombat.pick_target(w)
	if behavior == "engage" and (tgt == 0 or not _perc.actionable(tgt, now)):
		var fallback := ""
		var fallback_s := -INF
		for s in scores:
			if String(s["behavior"]) == "engage":
				continue
			var v: float = float(s["score"])
			if String(s["behavior"]) == _current_behavior:
				v += Utility.HYSTERESIS_BONUS
			if v > fallback_s:
				fallback_s = v; fallback = String(s["behavior"])
		behavior = fallback if fallback != "" else "suppress"
	_current_behavior = behavior
	var intent := {"move_x": 0.0, "move_y": 0.0, "yaw": (me.yaw if me else 0.0), "pitch": 0.0, "buttons": 0, "stance": Stance.STAND, "behavior": behavior}
	if behavior == "engage" and tgt != 0 and _perc.actionable(tgt, now):
		var tpos: Vector3 = view[tgt].pos
		var d := tpos - me.pos
		intent["yaw"] = atan2(d.x, d.z) + _human.aim_jitter(float(_profile.get("aim_error_deg", 3.0)))
		intent["buttons"] = InputCommand.BTN_FIRE
		intent["move_x"] = 0.0; intent["move_y"] = 0.0
	elif behavior == "take_cover":
		var c := AiCover.pick_cover(w)
		var flat := Vector2(c.x - me.pos.x, c.z - me.pos.z)
		if flat.length() > 0.001: flat = flat.normalized()
		intent["move_x"] = flat.x; intent["move_y"] = flat.y
		intent["stance"] = AiCover.desired_stance(w.incoming_fire)
	return intent
