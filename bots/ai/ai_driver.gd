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
var _objective: Vector3 = Vector3.ZERO

const ENGAGE_RANGE := 50.0

# NOTE: profile reaction_delay_ticks is loaded but gate scaling is deferred to §11; gate uses Perception.REACTION_DELAY_TICKS for now.
func _init(global_seed: int, bot_index: int, profile_name: String) -> void:
	_perc = Perception.new()
	_human = Humanize.new(global_seed, bot_index)
	var t := AiTuning.load_file("res://data/ai_tuning.json")
	_profile = t.get("profiles", {}).get(profile_name, {"reaction_delay_ticks": 9, "aim_error_deg": 3.0, "aim_settle_ticks": 6, "aggression": 1.0})

## Update perception state (memory + reaction gate) from the latest snapshot view.
## Builds and caches the WorldModel (including metadata_hp_frac + incoming_fire).
func observe(my_id: int, view: Dictionary, vview: Dictionary, structs: Dictionary, match_points: Array, now: int, objective_pos: Vector3 = Vector3.ZERO) -> void:
	_world = _perc.build(my_id, view, vview, structs, match_points, now)
	_now = now
	_objective = objective_pos

## Produce the input intent for this tick from the last observed world.
## {move_x, move_y, yaw, pitch, buttons, stance, behavior}.
func decide() -> Dictionary:
	var w := _world
	var me: EntityState = w.self_state if w else null
	var default_intent := {"move_x": 0.0, "move_y": 0.0, "yaw": (me.yaw if me else 0.0), "pitch": 0.0, "buttons": 0, "stance": Stance.STAND, "behavior": "push_obj"}
	if w == null or me == null:
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
	var intent := {"move_x": 0.0, "move_y": 0.0, "yaw": me.yaw, "pitch": 0.0, "buttons": 0, "stance": Stance.STAND, "behavior": behavior}
	match behavior:
		"engage":
			var e := _enemy_rec(w, tgt)
			if not e.is_empty():
				var tpos: Vector3 = e["pos"]
				var aim := tpos + Vector3(0.0, Stance.body_height(int(e["stance"])) * 0.5, 0.0)
				var eye := me.pos + Vector3(0.0, Stance.eye_height(me.stance), 0.0)
				var to := aim - eye
				intent["yaw"] = atan2(to.x, to.z) + _human.aim_jitter(float(_profile.get("aim_error_deg", 3.0)))
				intent["pitch"] = clampf(asin(clampf(to.y / maxf(to.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
				if me.pos.distance_to(tpos) <= ENGAGE_RANGE:
					intent["buttons"] = InputCommand.BTN_FIRE   # stop-to-shoot: movement stays 0
				else:
					var mv := _flat_dir(me.pos, tpos)
					intent["move_x"] = mv.x; intent["move_y"] = mv.y
		"take_cover":
			var c := AiCover.pick_cover(w)
			var mv := _flat_dir(me.pos, c)
			intent["move_x"] = mv.x; intent["move_y"] = mv.y
			intent["stance"] = AiCover.desired_stance(w.incoming_fire)
		"retreat":
			var c := AiCover.pick_cover(w)
			var dest := c
			if w.cover.is_empty() and w.enemies.size() > 0:
				dest = me.pos + (me.pos - _nearest_enemy_pos(w, me.pos))   # flee directly away
			var mv := _flat_dir(me.pos, dest)
			intent["move_x"] = mv.x; intent["move_y"] = mv.y
		"suppress":
			if tgt != 0:
				var tpos := _enemy_pos(w, tgt)
				var to := tpos - me.pos
				intent["yaw"] = atan2(to.x, to.z) + _human.aim_jitter(float(_profile.get("aim_error_deg", 3.0)))
				if _perc.actionable(tgt, _now):
					intent["buttons"] = InputCommand.BTN_FIRE
			# movement stays 0 (hold and pin)
		_:   # push_obj / default: march to the objective
			var mv := _flat_dir(me.pos, _objective)
			intent["move_x"] = mv.x; intent["move_y"] = mv.y
			if mv != Vector2.ZERO:
				intent["yaw"] = atan2(mv.x, mv.y)
	return intent

## Flat (XZ-plane) unit direction from `from` toward `to`, or zero if coincident.
func _flat_dir(from: Vector3, to: Vector3) -> Vector2:
	var f := Vector2(to.x - from.x, to.z - from.z)
	if f.length() > 0.001:
		return f.normalized()
	return Vector2.ZERO

## Full enemy record dict for id, or {} if not present.
func _enemy_rec(w: WorldModel, id: int) -> Dictionary:
	for e in w.enemies:
		if int(e["id"]) == id:
			return e
	return {}

## Nearest enemy position to `from`, or `from` if none.
func _nearest_enemy_pos(w: WorldModel, from: Vector3) -> Vector3:
	var best := from
	var best_d := INF
	for e in w.enemies:
		var p: Vector3 = e["pos"]
		var d: float = from.distance_to(p)
		if d < best_d:
			best_d = d; best = p
	return best

## Position of enemy `id` from the cached world's enemy records, else Vector3.ZERO.
func _enemy_pos(w: WorldModel, id: int) -> Vector3:
	for e in w.enemies:
		if int(e["id"]) == id:
			return e["pos"]
	return Vector3.ZERO
