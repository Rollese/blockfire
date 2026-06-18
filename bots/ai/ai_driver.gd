class_name AiDriver
extends RefCounted
## Per-bot orchestrator: perception -> utility -> behaviour -> humanized primitive intent.
## One instance per bot. The bot_driver shell calls observe() + decide() each tick and
## sends the returned intent. See docs/specs/bot-ai.md §4, §6.

var _perc: Perception
var _human: Humanize
var _profile: Dictionary
var _current_behavior := ""
var _world: WorldModel = null
var _now: int = 0

# NOTE: profile reaction_delay_ticks is loaded but gate scaling is deferred to §11; gate uses Perception.REACTION_DELAY_TICKS for now.
func _init(global_seed: int, bot_index: int, profile_name: String) -> void:
	_perc = Perception.new()
	_human = Humanize.new(global_seed, bot_index)
	var t := AiTuning.load_file("res://data/ai_tuning.json")
	_profile = t.get("profiles", {}).get(profile_name, {"reaction_delay_ticks": 9, "aim_error_deg": 3.0, "aim_settle_ticks": 6, "aggression": 1.0})

## Update perception state (memory + reaction gate) from the latest snapshot view.
## Builds and caches the WorldModel (including metadata_hp_frac + incoming_fire).
func observe(my_id: int, view: Dictionary, vview: Dictionary, structs: Dictionary, match_points: Array, now: int) -> void:
	_world = _perc.build(my_id, view, vview, structs, match_points, now)
	_now = now

## Produce the input intent for this tick from the last observed world.
## {move_x, move_y, yaw, pitch, buttons, stance, behavior}.
func decide() -> Dictionary:
	var w := _world
	var me: EntityState = w.self_state if w else null
	var default_intent := {"move_x": 0.0, "move_y": 0.0, "yaw": (me.yaw if me else 0.0), "pitch": 0.0, "buttons": 0, "stance": Stance.STAND, "behavior": "push_obj"}
	if w == null:
		return default_intent
	var scores := Utility.score(w, float(_profile.get("aggression", 1.0)), _current_behavior)
	var behavior := Utility.choose(scores, _current_behavior, Utility.HYSTERESIS_BONUS)
	var tgt := AiCombat.pick_target(w)
	# Reaction gate: if engage was chosen but no target has cleared the delay, re-pick the best
	# non-engage behaviour (cannot re-select engage; always terminates over the fixed score list).
	if behavior == "engage" and not (tgt != 0 and _perc.actionable(tgt, _now)):
		var best := "suppress"
		var best_s := -INF
		for s in scores:
			if String(s["behavior"]) == "engage":
				continue
			var v: float = float(s["score"])
			if String(s["behavior"]) == _current_behavior:
				v += Utility.HYSTERESIS_BONUS
			if v > best_s:
				best_s = v; best = String(s["behavior"])
		behavior = best
	_current_behavior = behavior
	var intent := {"move_x": 0.0, "move_y": 0.0, "yaw": (me.yaw if me else 0.0), "pitch": 0.0, "buttons": 0, "stance": Stance.STAND, "behavior": behavior}
	if behavior == "engage" and tgt != 0:
		var tpos := _enemy_pos(w, tgt)
		var d := tpos - me.pos
		intent["yaw"] = atan2(d.x, d.z) + _human.aim_jitter(float(_profile.get("aim_error_deg", 3.0)))
		intent["buttons"] = InputCommand.BTN_FIRE
	elif behavior == "take_cover":
		var c := AiCover.pick_cover(w)
		var flat := Vector2(c.x - me.pos.x, c.z - me.pos.z)
		if flat.length() > 0.001: flat = flat.normalized()
		intent["move_x"] = flat.x; intent["move_y"] = flat.y
		intent["stance"] = AiCover.desired_stance(w.incoming_fire)
	return intent

## Position of enemy `id` from the cached world's enemy records, else Vector3.ZERO.
func _enemy_pos(w: WorldModel, id: int) -> Vector3:
	for e in w.enemies:
		if int(e["id"]) == id:
			return e["pos"]
	return Vector3.ZERO
