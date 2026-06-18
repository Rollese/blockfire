class_name AiCombat
extends RefCounted
## P2 combat behaviour: target prioritization, stop-to-shoot. Pure decision helpers
## (docs/specs/bot-ai.md §7). Re-homed combat_button lands in a later cluster.

## Pick the highest-priority enemy id, or 0 if none. Priority blends closeness, low HP,
## and a per-enemy priority tag (reviving medic / flag-capper / actively-shooting-me),
## NOT nearest-only (§7). Higher score wins; tie-break by lower id.
static func pick_target(w: WorldModel) -> int:
	var best := 0
	var best_s := -INF
	for e in w.enemies:
		var dist: float = float(e.get("dist", 999.0))
		var hp: float = float(e.get("hp_frac", 1.0))
		var pri: float = float(e.get("priority", 0.0))
		var s: float = (1.0 - hp) * 2.0 + pri * 2.0 + (1.0 / maxf(dist, 1.0))
		var id: int = int(e["id"])
		if s > best_s or (is_equal_approx(s, best_s) and (best == 0 or id < best)):
			best_s = s; best = id
	return best

## Halt (or minimise) movement while firing — the server adds movement spread (§7).
static func should_stop_to_shoot(firing: bool) -> bool:
	return firing
