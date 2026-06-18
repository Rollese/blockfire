class_name Perception
extends RefCounted
## Builds the per-bot WorldModel from the interest snapshot. Owns short-term memory
## (decaying last-known enemy positions) and the reaction-delay gate. See docs/specs/bot-ai.md §5.

const REACTION_DELAY_TICKS := 9   # ~0.3s @30Hz; profile-scaled later (§11)
const MEMORY_DECAY_TICKS := 90    # 3s @30Hz (§11)
const PRESSURE_HP_REF := 50.0

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

var _first_seen: Dictionary = {}   # enemy_id -> tick first continuously seen
var _memory: Dictionary = {}        # enemy_id -> {pos, tick} last-known
## Build the WorldModel from the snapshot view. `my_id` is this bot's pawn id.
func build(my_id: int, view: Dictionary, _vview: Dictionary, structs: Dictionary, match_points: Array, now: int) -> WorldModel:
	var w := WorldModel.new()
	w.now_tick = now
	var me: EntityState = view.get(my_id)
	w.self_state = me
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
		if not e.alive:
			continue
		var d: float = (me.pos.distance_to(e.pos) if me else 0.0)
		w.enemies.append({"id": int(id), "pos": e.pos, "stance": e.stance, "dist": d, "last_seen_tick": now})
		seen_now[int(id)] = true
		if not _first_seen.has(int(id)):
			_first_seen[int(id)] = now
		_memory[int(id)] = {"pos": e.pos, "tick": now}
	for id in _first_seen.keys():
		if not seen_now.has(id) and not _memory.has(id):
			_first_seen.erase(id)
	_memory = decay_memory(_memory, now, MEMORY_DECAY_TICKS)
	for sid in structs:
		var cell: Vector3i = structs[sid]["cell"]
		w.cover.append(BuildGrid.world_of(cell))
	for i in match_points.size():
		var mp: Dictionary = match_points[i]
		w.objectives.append({"pos": mp.get("pos", Vector3.ZERO), "owner": int(mp.get("owner", -1))})
	return w
## Reaction gate for a currently-visible enemy id at time `now`.
func actionable(enemy_id: int, now: int) -> bool:
	if not _first_seen.has(enemy_id):
		return false
	return is_actionable(int(_first_seen[enemy_id]), now, REACTION_DELAY_TICKS)
