class_name Perception
extends RefCounted
## Builds the per-bot WorldModel from the interest snapshot. Owns short-term memory
## (decaying last-known enemy positions) and the reaction-delay gate. See docs/specs/bot-ai.md §5.
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
const PRESSURE_HP_REF := 50.0
static func infer_pressure(prev_hp: float, cur_hp: float, aimed_at: bool) -> float:
	var dmg: float = maxf(prev_hp - cur_hp, 0.0)
	var p: float = dmg / PRESSURE_HP_REF
	if aimed_at:
		p += 0.5
	return clampf(p, 0.0, 1.0)
