class_name Humanize
extends RefCounted
## Per-bot humanization: seeded RNG for aim jitter + pure aim-settle math. Determinism
## is required for the "provable decision" tests (docs/specs/bot-ai.md §9).

var _rng := RandomNumberGenerator.new()

func _init(global_seed: int, bot_index: int) -> void:
	_rng.seed = global_seed ^ bot_index

## Random aim jitter (radians) within +/- error_deg, drawn from the seeded stream.
func aim_jitter(error_deg: float) -> float:
	var half := deg_to_rad(error_deg)
	return _rng.randf_range(-half, half)

## Fraction of base aim error still present after tracking a target for `ticks_tracked`
## of a `settle_ticks` window. 1.0 at first sighting -> 0.0 once settled. Pure (§8).
static func settle_frac(ticks_tracked: int, settle_ticks: int) -> float:
	if settle_ticks <= 0:
		return 0.0
	return clampf(1.0 - float(ticks_tracked) / float(settle_ticks), 0.0, 1.0)
