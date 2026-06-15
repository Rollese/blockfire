class_name Revive
extends Object
## Pure DBNO (down-but-not-out) state machine + constants. No side effects and no Pawn
## references — the server holds the state on Pawn and calls these helpers to decide
## transitions, keeping the rules in shared/ (AGENTS.md §7). See docs/specs/combat-depth.md (P1).

# --- constants (initial values; gate-tuned) ---
const BANDAGE_COUNT := 3         # bandages per spawn, all classes
const MEDIC_EXTRA_BANDAGES := 2  # extra bandage charges for Medic
const BLEED_RATE := 1            # HP/tick lost while DOWNED and not halted
const BLEEDOUT_FLOOR := -240     # death threshold; |floor|/rate = 240 ticks (8 s) bleed-out window.
                                 # Must exceed REVIVE_TICKS so a teammate can revive a fresh down.
                                 # DOWNED pawns take no weapon damage (immune, BattleBit-style) — a
                                 # passive bleed-out is their only death path if not revived.
const REVIVE_TICKS := 90         # revive hold duration, non-medic (3 s @30 Hz)
const REVIVE_HP := 30            # HP restored on revive
const REVIVE_RANGE := 3.0        # max range (m) to begin/hold revive (gate-tuned up from 2.0 for
                                 # positioning margin so a reviver's drift doesn't drop progress)
const DOWNED_CRAWL_SPEED := 1.0  # m/s while DOWNED

# Damage source tags — who/what dealt the (potentially) lethal hit.
enum Source { BULLET = 0, BLAST = 1, FALL = 2 }

## A lethal hit skips DOWNED and kills outright when it is a headshot or an explosive/blast hit.
static func is_instant_kill(headshot: bool, source: int) -> bool:
	return headshot or source == Source.BLAST

## Effective bleed_health after one tick (0 at down, floored at BLEEDOUT_FLOOR). Halted pawns hold.
static func bleed_step(bleed_health: int, halted: bool) -> int:
	if halted:
		return bleed_health
	return maxi(BLEEDOUT_FLOOR, bleed_health - BLEED_RATE)

## True once a downed pawn has bled to the floor and must truly die.
static func is_bled_out(bleed_health: int) -> bool:
	return bleed_health <= BLEEDOUT_FLOOR

## Revive hold duration; Medic is 2× speed.
static func revive_ticks(is_medic: bool) -> int:
	return (REVIVE_TICKS / 2) if is_medic else REVIVE_TICKS

## Bandages a class spawns with.
static func bandage_count_for(is_medic: bool) -> int:
	return BANDAGE_COUNT + (MEDIC_EXTRA_BANDAGES if is_medic else 0)
