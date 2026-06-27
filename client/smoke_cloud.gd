class_name SmokeCloud
extends Object
## Pure opacity envelope for a deployed smoke-grenade cloud (M7, view-only — AGENTS.md §7). The
## server sends SMOKE_DEPLOYED (pos/radius/expire); the client renders a cluster of soft puffs whose
## alpha follows this curve: it billows in over GROW seconds, holds fully opaque, then thins out over
## the last FADE seconds before expiry. Distance-from-the-ends shaped so it degrades gracefully for
## clouds shorter-lived than GROW+FADE (the grow and fade ramps simply overlap).

const GROW := 0.6     # s — billow-in time after the canister pops
const FADE := 1.2     # s — thin-out time before the zone expires

## Returns 0..1: 0 before birth / at-or-after expiry, ramping to 1 during the held middle.
static func envelope(age: float, duration: float) -> float:
	if age <= 0.0 or age >= duration:
		return 0.0
	var grow_a := clampf(age / GROW, 0.0, 1.0)
	var fade_a := clampf((duration - age) / FADE, 0.0, 1.0)
	return minf(grow_a, fade_a)
