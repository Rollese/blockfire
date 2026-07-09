class_name Bandage
extends Object
## Pure bandage-channel timing + resource rule (M16). No side effects — the server holds the
## channel latch/progress and calls these to decide duration and which pouch pays. Backs both a
## standing-bandage completion and (revive-costs-a-bandage) a revive completion.
## See docs/superpowers/specs/2026-07-03-standing-bleed-bandage-design.md.

const BANDAGE_TICKS := 150    # channel duration, non-medic (5 s @30 Hz); medic = 75 (2.5 s)
const BANDAGE_HEAL := 25      # HP restored on a completed bandage (capped at 100 by the caller)
const BANDAGE_RANGE := 3.0    # max range (m) to bandage a teammate (matches Revive.REVIVE_RANGE)

## Channel duration for the healer; Medic is 2× speed (mirrors Revive.revive_ticks).
static func channel_ticks(is_medic: bool) -> int:
	return (BANDAGE_TICKS / 2) if is_medic else BANDAGE_TICKS

## Which pouch pays for a bandage: 0 = victim/target (first-aid-kit-on-your-chest, spent first),
## 1 = helper, -1 = neither has a charge (the bandage cannot complete). The same rule gates a
## standing-bandage and a revive.
static func pick_source(victim_bandages: int, helper_bandages: int) -> int:
	if victim_bandages > 0:
		return 0
	if helper_bandages > 0:
		return 1
	return -1
