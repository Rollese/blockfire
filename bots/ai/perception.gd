class_name Perception
extends RefCounted
## Builds the per-bot WorldModel from the interest snapshot. Owns short-term memory
## (decaying last-known enemy positions) and the reaction-delay gate. See docs/specs/bot-ai.md §5.
static func is_actionable(first_seen_tick: int, now: int, delay: int) -> bool:
	return now - first_seen_tick >= delay
