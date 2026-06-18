class_name AiCombat
extends RefCounted
## P2 combat behaviour: target prioritization, stop-to-shoot. Pure decision helpers
## (docs/specs/bot-ai.md §7). combat_button re-homed here from BotDriver (§4 migration).

const BURST_TICKS := 60   # server ticks (~2.0s @30Hz) of firing before reloading; shorter
                          # than the fastest mag-empty time so no weapon runs dry mid-burst
const RELOAD_TICKS := 84  # server ticks (~2.8s) to hold BTN_RELOAD; > the slowest weapon
                          # reload (2.6s) so the mag is surely refilled before the next burst

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

## Combat button for an ammo-blind bot, paced in SERVER game-time (`st` = server tick).
## Returns [button, reload_until, burst_start]. Fires BURST_TICKS-long bursts then holds
## BTN_RELOAD for RELOAD_TICKS before the next burst, so combat is sustained instead of dying
## after one magazine. See docs/specs/m3-bot-convergence-fix.md.
static func combat_button(fire: bool, st: int, reload_until: int, burst_start: int) -> Array:
	if st < reload_until:
		return [InputCommand.BTN_RELOAD, reload_until, burst_start]
	if not fire:
		return [0, reload_until, burst_start]
	if burst_start < 0:
		burst_start = st
	if st - burst_start >= BURST_TICKS:
		return [InputCommand.BTN_RELOAD, st + RELOAD_TICKS, -1]
	return [InputCommand.BTN_FIRE, reload_until, burst_start]
