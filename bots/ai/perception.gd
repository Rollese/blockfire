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
