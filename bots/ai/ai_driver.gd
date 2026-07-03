class_name AiDriver
extends RefCounted
## Per-bot orchestrator: perception -> utility -> behaviour -> humanized primitive intent.
## One instance per bot. The bot_driver shell calls observe() + decide() each tick and
## sends the returned intent. See docs/specs/bot-ai.md §4, §6.

var _perc: Perception
var _human: Humanize
var _profile: Dictionary
var _weights: Dictionary = {}  # M7.5-P3: utility weights from data/ai_tuning.json ({} -> hardcoded defaults)
var _current_behavior := ""
var _aim_target_id: int = 0
var _aim_ticks: int = 0
var _world: WorldModel = null
var _now: int = 0
var _objective: Vector3 = Vector3.ZERO
var _ladders: Array = []  # map ladders [{bottom, top, radius}] for climb_seek on the march
var _enemy_track := {}  # id -> {pos: Vector3, tick: int, vel: Vector3}

const ENGAGE_RANGE := 50.0
const LEAD_PROJECTILE_SPEED := 250.0  # nominal muzzle speed (AR) for bot aim lead; per-weapon precision not worth threading weapon data into the AI brain
const STANDOFF_RANGE := 10.0   # inside this, hold ground and strafe-fire instead of charging in
const STRAFE_PERIOD := 18      # ticks per strafe direction (~0.6s at 30Hz) — lateral juking while firing
const TRACK_STALE_TICKS := 30  # 1s @30Hz: a longer visibility gap restarts the velocity track
const AI_TICK_EVERY := 3       # M7.5-P3 (§E): full behaviour re-scoring stride (spec §11 table);
                               # aim/movement for the cached behaviour still refresh every tick
const _NEVER_DECIDED := -(1 << 30)   # sentinel: first decide() always runs a full re-score

var _bot_index: int = 0
var _last_decide_tick: int = _NEVER_DECIDED
var bot_class: int = 0   # Loadout class from WELCOME (bot_driver sets it); MEDIC widens revive reach

## Velocity estimate for an enemy track (batch 6, pure). A gap longer than TRACK_STALE_TICKS
## (respawn, interest-range re-entry) restarts the track at zero — averaging across the gap
## produced wild aim leads on reappearing enemies. Within a fresh track, movement updates the
## estimate and standing still persists the last good one.
static func track_velocity(prev, cur_pos: Vector3, now: int) -> Vector3:
	if prev == null:
		return Vector3.ZERO
	var dt: int = now - int(prev["tick"])
	if dt > TRACK_STALE_TICKS:
		return Vector3.ZERO
	var vel: Vector3 = prev["vel"]
	var moved: Vector3 = cur_pos - (prev["pos"] as Vector3)
	if dt > 0 and moved.length() > 0.01:
		vel = moved / (float(dt) * SimLoop.DT)
	return vel

func _init(global_seed: int, bot_index: int, profile_name: String) -> void:
	_perc = Perception.new()
	_human = Humanize.new(global_seed, bot_index)
	_bot_index = bot_index
	var t := AiTuning.load_file("res://data/ai_tuning.json")
	_profile = t.get("profiles", {}).get(profile_name, {"reaction_delay_ticks": 9, "aim_error_deg": 3.0, "aim_settle_ticks": 6, "aggression": 1.0})
	_weights = t.get("weights", {})
	# M7.5-P3 (§E): the profile's reaction delay finally reaches the gate (was loaded but unused).
	_perc.reaction_delay_ticks = int(_profile.get("reaction_delay_ticks", Perception.REACTION_DELAY_TICKS))

## Clear per-life state. Called from the bot_driver dead branch (and on future map
## rotation): enemies seen in a past life must re-trigger the reaction delay, stale
## velocity tracks must not produce wild aim leads on respawn, and the behaviour
## latch must not carry over. Humanize (seeded jitter) survives — it is per-bot, not per-life.
func reset() -> void:
	_perc.reset()
	_current_behavior = ""
	_aim_target_id = 0
	_aim_ticks = 0
	_world = null
	_enemy_track = {}
	_last_decide_tick = _NEVER_DECIDED

## Update perception state (memory + reaction gate) from the latest snapshot view.
## Builds and caches the WorldModel (including metadata_hp_frac + incoming_fire).
## M7.5-P3 trailing inputs: `net_self` (decoded SELF_STATE), `gadgets` (GADGET_LIST mirror),
## `grenade_events` ([{pos, tick}] landing estimates) — all default-empty for old callsites.
func observe(my_id: int, view: Dictionary, vview: Dictionary, structs: Dictionary, match_points: Array, now: int, objective_pos: Vector3 = Vector3.ZERO, ladders: Array = [], net_self: Dictionary = {}, gadgets: Array = [], grenade_events: Array = []) -> void:
	_world = _perc.build(my_id, view, vview, structs, match_points, now, net_self, gadgets, grenade_events, bot_class == Loadout.MEDIC)
	_now = now
	_objective = objective_pos
	_ladders = ladders
	# Update per-enemy velocity estimates from the new snapshot.
	var self_state: EntityState = view.get(my_id)
	var self_team: int = int(self_state.team) if self_state != null else -1
	for eid in view:
		var e: EntityState = view[eid]
		if not e.alive or int(e.team) == self_team:
			continue
		var cur_pos: Vector3 = e.pos
		var vel := track_velocity(_enemy_track.get(eid), cur_pos, now)
		_enemy_track[eid] = {"pos": cur_pos, "tick": now, "vel": vel}

## Produce the input intent for this tick from the last observed world.
## {move_x, move_y, yaw, pitch, buttons, stance, behavior}.
func decide() -> Dictionary:
	var w := _world
	var me: EntityState = w.self_state if w else null
	var default_intent := {"move_x": 0.0, "move_y": 0.0, "yaw": (me.yaw if me else 0.0), "pitch": 0.0, "buttons": 0, "stance": Stance.STAND, "behavior": "push_obj"}
	if w == null or me == null:
		return default_intent
	var tgt := AiCombat.pick_target(w, _aim_target_id)
	# M7.5-P3 (§E) AI_TICK_EVERY cadence: full behaviour re-scoring runs only every 3rd tick.
	# Danger pre-empts the stride (a grenade at your feet can't wait 2 ticks). Between
	# refreshes the cached behaviour's movement/aim block below still executes every call,
	# so aim tracking stays smooth. observe() remains per-tick (memory/pressure decay).
	if _now - _last_decide_tick >= AI_TICK_EVERY or not w.danger_zones.is_empty() or _current_behavior == "":
		_last_decide_tick = _now
		var scores := Utility.score(w, float(_profile.get("aggression", 1.0)), _weights)
		var behavior := Utility.choose(scores, _current_behavior, Utility.HYSTERESIS_BONUS)
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
	var intent := {"move_x": 0.0, "move_y": 0.0, "yaw": me.yaw, "pitch": 0.0, "buttons": 0, "stance": Stance.STAND, "behavior": _current_behavior}
	match _current_behavior:
		"engage":
			var e := _enemy_rec(w, tgt)
			if not e.is_empty():
				if tgt == _aim_target_id:
					_aim_ticks += 1
				else:
					_aim_target_id = tgt
					_aim_ticks = 0
				var settle := Humanize.settle_frac(_aim_ticks, int(_profile.get("aim_settle_ticks", 6)))
				var jit := _human.aim_jitter(float(_profile.get("aim_error_deg", 3.0))) * settle
				var raw_pos: Vector3 = e["pos"]
				var evel: Vector3 = _enemy_track.get(tgt, {}).get("vel", Vector3.ZERO)
				var flight: float = me.pos.distance_to(raw_pos) / LEAD_PROJECTILE_SPEED
				var tpos: Vector3 = raw_pos + evel * flight
				var aim := tpos + Vector3(0.0, Stance.body_height(int(e["stance"])) * 0.5, 0.0)
				var eye := me.pos + Vector3(0.0, Stance.eye_height(me.stance), 0.0)
				var to := aim - eye
				intent["yaw"] = atan2(to.x, to.z) + jit
				intent["pitch"] = clampf(asin(clampf(to.y / maxf(to.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
				var dist := me.pos.distance_to(raw_pos)
				if dist <= ENGAGE_RANGE:
					# Re-check the reaction gate per call: with the decide cadence, a cached
					# "engage" can outlive a target swap to a freshly-seen (still-gated) enemy.
					if _perc.actionable(tgt, _now):
						intent["buttons"] = InputCommand.BTN_FIRE
					var fwd := _flat_dir(me.pos, raw_pos)
					if dist > STANDOFF_RANGE:
						# advance into the fight while firing — don't root at max range
						intent["move_x"] = fwd.x; intent["move_y"] = fwd.y
					else:
						# close enough: strafe laterally (world-space, perpendicular to the
						# line of fire) so the bot juke-fires instead of standing still
						var strafe := Vector2(fwd.y, -fwd.x)
						if int(_aim_ticks / STRAFE_PERIOD) % 2 == 1:
							strafe = -strafe
						intent["move_x"] = strafe.x; intent["move_y"] = strafe.y
				else:
					var mv := _flat_dir(me.pos, raw_pos)
					intent["move_x"] = mv.x; intent["move_y"] = mv.y
		"take_cover":
			var c := AiCover.pick_cover(w)
			if w.cover.is_empty() and w.enemies.size() > 0:
				c = me.pos + (me.pos - _nearest_enemy_pos(w, me.pos))   # no cover -> break LOS, do not root crouched in the open
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
			else:
				# M7.5-P3 (§E) memory read: no enemy visible — keep the muzzle on the most
				# recent last-known position (perception _memory, ≤3s old) instead of the
				# stale spawn yaw. No blind fire: the gate needs a visible target.
				var lk := _perc.last_known()
				if not lk.is_empty():
					var to := (lk["pos"] as Vector3) - me.pos
					intent["yaw"] = atan2(to.x, to.z) + _human.aim_jitter(float(_profile.get("aim_error_deg", 3.0)))
			# movement stays 0 (hold and pin)
		"revive":
			# M7.5-P3: steer to the chosen downed ally; once inside the revive envelope
			# (×0.8 so quantization/lag never leaves us hovering at the exact boundary),
			# stop, crouch (BattleBit medic posture) and hand the target id to the driver,
			# which latches REVIVE_ACTION on the wire.
			var rt := w.revive_target
			if not rt.is_empty():
				var tpos: Vector3 = rt["pos"]
				var to := tpos - me.pos
				intent["yaw"] = atan2(to.x, to.z)
				if me.pos.distance_to(tpos) <= Revive.REVIVE_RANGE * 0.8:
					intent["stance"] = Stance.CROUCH
					intent["revive_target_id"] = int(rt["id"])
				else:
					var mv := _flat_dir(me.pos, tpos)
					intent["move_x"] = mv.x; intent["move_y"] = mv.y
		"seek_supply":
			# M7.5-P3: path to the nearest known friendly bag; on arrival stand on it —
			# the server's bag radius dispenses passively, no action message needed.
			var bag := w.supply_bag
			if not bag.is_empty():
				var bpos: Vector3 = bag["pos"]
				if me.pos.distance_to(bpos) > AiSupport.BAG_ARRIVE_RANGE:
					var mv := _flat_dir(me.pos, bpos)
					intent["move_x"] = mv.x; intent["move_y"] = mv.y
					if mv != Vector2.ZERO:
						intent["yaw"] = atan2(mv.x, mv.y)
		"avoid_danger":
			# M7.5-P3: sprint out of the grenade/mine zone along the pure flee vector.
			# move axes are world-space XZ (Pawn.step applies them unrotated), so the
			# flee vector maps directly. buttons stay 0 — never fire while fleeing.
			var flee := AiSupport.flee_vector(w.me_pos, w.danger_zones)
			intent["move_x"] = flee.x; intent["move_y"] = flee.z
			if flee != Vector3.ZERO:
				intent["yaw"] = atan2(flee.x, flee.z)
		_:   # push_obj / default: march to the objective on this bot's lateral lane (batch 6
			# spread: a squad advances as a line abreast, converging inside the capture zone)
			var march := AiObjective.spread_march_target(me.pos, _objective, _bot_index)
			# M7.5-P3 (§E): climb_seek back in the march path (dropped from the march in
			# 214b7e4) — steer onto a nearby ladder base when the objective lies beyond it
			# (M14 multi-floor maps). climb_seek returns seek=false when no ladder is relevant.
			var cs := AiObjective.climb_seek(me.pos, march, _ladders)
			if bool(cs["seek"]):
				march = cs["target"]
			var mv := _flat_dir(me.pos, march)
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
