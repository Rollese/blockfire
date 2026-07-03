class_name Perception
extends RefCounted
## Builds the per-bot WorldModel from the interest snapshot. Owns short-term memory
## (decaying last-known enemy positions) and the reaction-delay gate. See docs/specs/bot-ai.md §5.

const REACTION_DELAY_TICKS := 9   # ~0.3s @30Hz; historical default — the live gate uses the
                                  # reaction_delay_ticks instance var (profile-wired, M7.5-P3 §E)
const MEMORY_DECAY_TICKS := 90    # 3s @30Hz (§11)
const REVIVE_THREAT_RANGE := 15.0    # m: an enemy this close to MY downed ally threatens the revive
const REVIVE_THREAT_PRIORITY := 0.5  # priority tag pick_target blends in (§7)
const PRESSURE_HP_REF := 50.0
const PRESSURE_DECAY := 0.97      # per-tick envelope decay: a full hit fades below the crouch
                                  # threshold (0.5) in ~0.8s and floors to 0 in ~4s

static func is_actionable(first_seen_tick: int, now: int, delay: int) -> bool:
	return now - first_seen_tick >= delay

## Returns a new memory dict with entries older than `lifetime` ticks removed.
## mem: enemy_id -> {pos:Vector3, tick:int}. Pure (§5.2 memory decay).
static func decay_memory(mem: Dictionary, now: int, lifetime: int) -> Dictionary:
	var kept := {}
	for id in mem:
		if now - int(mem[id]["tick"]) <= lifetime:
			kept[id] = mem[id]
	return kept

## Infer 0..1 combat pressure from observables: recent health drop (normalised by a
## 50 HP reference) plus an enemy currently aiming at me. Pure (§6.1).
static func infer_pressure(prev_hp: float, cur_hp: float, aimed_at: bool) -> float:
	var dmg: float = maxf(prev_hp - cur_hp, 0.0)
	var p: float = dmg / PRESSURE_HP_REF
	if aimed_at:
		p += 0.5
	return clampf(p, 0.0, 1.0)

## Pressure envelope (batch 6): the raw impulse is nonzero only on the exact tick health
## dropped, which made take_cover a 1-tick twitch oscillating with engage. A fresh impulse
## dominates; otherwise the previous pressure decays geometrically and floors to exactly 0
## so calm bots aren't stuck with an infinite tail. Pure.
static func decay_pressure(prev: float, impulse: float) -> float:
	var p: float = maxf(impulse, prev * PRESSURE_DECAY)
	return p if p >= 0.01 else 0.0

var reaction_delay_ticks: int = REACTION_DELAY_TICKS   # per-profile gate delay, set by AiDriver
                                                        # from data/ai_tuning.json (M7.5-P3 §E)
var _first_seen: Dictionary = {}   # enemy_id -> tick first continuously seen
var _memory: Dictionary = {}        # enemy_id -> {pos, tick} last-known
var _last_hp: float = 100.0
var _pressure: float = 0.0          # decaying incoming_fire envelope (see decay_pressure)

## Clear per-life state (see AiDriver.reset): re-arm the reaction gate, drop last-known
## memory, and start the pressure baseline from full health for the next spawn.
func reset() -> void:
	_first_seen = {}
	_memory = {}
	_last_hp = 100.0
	_pressure = 0.0
## Build the WorldModel from the snapshot view. `my_id` is this bot's pawn id.
func build(my_id: int, view: Dictionary, _vview: Dictionary, structs: Dictionary, match_points: Array, now: int) -> WorldModel:
	var w := WorldModel.new()
	w.now_tick = now
	var me: EntityState = view.get(my_id)
	w.self_state = me
	w.me_pos = me.pos if me != null else Vector3.ZERO
	var cur_hp: float = float(me.health) if me else 100.0
	w.metadata_hp_frac = cur_hp / 100.0
	# Pressure from health-drop since last tick, held in a decaying envelope so cover-seeking
	# persists past the hit tick. `aimed_at` geometry is deferred (§6.1 follow-up), so it's
	# false for now — health loss alone drives take_cover/retreat this increment.
	_pressure = decay_pressure(_pressure, infer_pressure(_last_hp, cur_hp, false))
	w.incoming_fire = _pressure
	_last_hp = cur_hp
	var seen_now := {}
	for id in view:
		if int(id) == my_id:
			continue
		var e: EntityState = view[id]
		if me != null and e.team == me.team:
			if e.is_downed:
				w.downed_allies.append({"id": int(id), "pos": e.pos, "dist": me.pos.distance_to(e.pos)})
			elif e.alive:
				w.allies.append({"id": int(id), "pos": e.pos, "dist": me.pos.distance_to(e.pos)})
			continue
		# Downed pawns keep alive==true but are immune to weapon damage — never
		# targetable (mirrors the reflex-loop rule; shoot the reviver instead).
		if not e.alive or e.is_downed:
			continue
		var d: float = (me.pos.distance_to(e.pos) if me else 0.0)
		w.enemies.append({"id": int(id), "pos": e.pos, "stance": e.stance, "dist": d, "last_seen_tick": now, "hp_frac": float(e.health) / 100.0})
		seen_now[int(id)] = true
		if not _first_seen.has(int(id)):
			_first_seen[int(id)] = now
		_memory[int(id)] = {"pos": e.pos, "tick": now}
	for id in _first_seen.keys():
		if not seen_now.has(id) and not _memory.has(id):
			_first_seen.erase(id)
	_memory = decay_memory(_memory, now, MEMORY_DECAY_TICKS)
	# M7.5-P3 (§E): tag enemies threatening a revive — any of MY downed allies within
	# REVIVE_THREAT_RANGE of the enemy. AiCombat.pick_target already blends `priority`
	# into target scoring; this finally feeds it. Downed list is tiny, so O(E*D) is fine.
	for e in w.enemies:
		var pri := 0.0
		for da in w.downed_allies:
			if (e["pos"] as Vector3).distance_to(da["pos"]) <= REVIVE_THREAT_RANGE:
				pri = REVIVE_THREAT_PRIORITY
				break
		e["priority"] = pri
	for sid in structs:
		var cell: Vector3i = structs[sid]["cell"]
		w.cover.append(BuildGrid.world_of(cell))
	for i in match_points.size():
		var mp: Dictionary = match_points[i]
		w.objectives.append({"pos": mp.get("pos", Vector3.ZERO), "owner": int(mp.get("owner", -1))})
	return w
## Reaction gate for a currently-visible enemy id at time `now`. Uses the per-profile
## instance delay (recruit 15 .. elite 4), wired from ai_tuning.json by AiDriver (§E).
func actionable(enemy_id: int, now: int) -> bool:
	if not _first_seen.has(enemy_id):
		return false
	return is_actionable(int(_first_seen[enemy_id]), now, reaction_delay_ticks)

## Most recent last-known enemy memory entry ({pos, tick}) or {} when memory is empty /
## fully decayed. The suppress behaviour aims here when no enemy is visible (§E: the
## _memory store is finally read, not just written).
func last_known() -> Dictionary:
	var best: Dictionary = {}
	for id in _memory:
		if best.is_empty() or int(_memory[id]["tick"]) > int(best["tick"]):
			best = _memory[id]
	return best
