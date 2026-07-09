class_name Revive
extends Object
## Pure DBNO (down-but-not-out) state machine + constants. No side effects and no Pawn
## references — the server holds the state on Pawn and calls these helpers to decide
## transitions, keeping the rules in shared/ (AGENTS.md §7). See docs/specs/combat-depth.md (P1).

# --- constants (initial values; gate-tuned) ---
const BANDAGE_COUNT := 3         # bandages per spawn, non-medic classes
const MEDIC_BANDAGE_COUNT := 20  # bandages per spawn, Medic (M16: the bandage item now has a consumer —
                                 # standing-bandage + revive both spend one, so the medic carries a real pouch)
const BLEED_RATE := 1            # HP/tick lost while DOWNED (drains bleed_health toward the floor)
const INITIAL_BLEEDOUT_TICKS := 1800  # 60 s @30 Hz on the FIRST down of a life; halved on each further
                                 # down that life (bleedout_window). DOWNED pawns take no weapon damage
                                 # (immune, BattleBit-style) — bleed-out or revive are the only exits.
                                 # Late-life windows intentionally fall below REVIVE_TICKS (a heavily
                                 # re-downed player becomes unsaveable) and a 0-tick window skips DBNO.
const REVIVE_TICKS := 90         # revive hold duration, non-medic (3 s @30 Hz)
const REVIVE_HP := 30            # HP restored on revive
const REVIVE_RANGE := 3.0        # max range (m) to begin/hold revive (gate-tuned up from 2.0 for
                                 # positioning margin so a reviver's drift doesn't drop progress)
const DOWNED_CRAWL_SPEED := 1.0  # m/s while DOWNED

# Damage source tags — who/what dealt the (potentially) lethal hit.
enum Source { BULLET = 0, BLAST = 1, FALL = 2 }

## A lethal hit skips DOWNED and kills outright when it is a headshot or an explosive/blast hit.
static func is_instant_kill(headshot: bool, source: int) -> bool:
	return headshot or source == Source.BLAST or source == Source.FALL

## Bleed-out window (ticks) for the n-th down of a life (1-based): 60 s, halved each subsequent down,
## clamped at 0. A 0-tick window means the down is skipped and the hit kills outright (see the server
## _down/_kill routing). down_count <= 1 is the first down.
static func bleedout_window(down_count: int) -> int:
	if down_count <= 1:
		return INITIAL_BLEEDOUT_TICKS
	return INITIAL_BLEEDOUT_TICKS >> (down_count - 1)

## Bleed-out floor (negative HP threshold) for a window; bleed_health drains from 0 down to here.
static func bleedout_floor(window_ticks: int) -> int:
	return -window_ticks

## Effective bleed_health after one tick: drains by BLEED_RATE toward `floor` (= -window). No halt
## path — downed self-bandage was removed 2026-07-03 (BattleBit has no downed self-heal).
static func bleed_step(bleed_health: int, floor: int) -> int:
	return maxi(floor, bleed_health - BLEED_RATE)

## True once a downed pawn has bled to its (per-down) floor and must truly die.
static func is_bled_out(bleed_health: int, floor: int) -> bool:
	return bleed_health <= floor

## Bleed-out urgency as a 0..255 byte for the wire (M7 revive marker): 255 the instant a pawn goes
## down (bleed_health 0), draining to 0 at the (variable) floor. `floor` must be < 0.
static func bleed_frac_u8(bleed_health: int, floor: int) -> int:
	if floor >= 0:
		return 0
	var f := float(bleed_health - floor) / float(-floor)
	return clampi(roundi(f * 255.0), 0, 255)

## Revive hold duration; Medic is 2× speed.
static func revive_ticks(is_medic: bool) -> int:
	return (REVIVE_TICKS / 2) if is_medic else REVIVE_TICKS

## Bandages a class spawns with.
static func bandage_count_for(is_medic: bool) -> int:
	return MEDIC_BANDAGE_COUNT if is_medic else BANDAGE_COUNT
