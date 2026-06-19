class_name Fall
extends Object
## Pure height-based fall-damage curve (BattleBit-style). Side-effect-free; the server applies the
## result via _apply_pawn_damage. See docs/specs/walkable-multifloor.md §4.

const SAFE_FALL := 4.0     # m; falls up to here are harmless
const DMG_PER_M := 13.5    # damage per metre above SAFE_FALL (~100 / lethal at ~11.4 m)

## Damage for a fall of `distance` metres (peak height minus landing height). 0 below SAFE_FALL.
static func damage_for(distance: float) -> int:
	if distance <= SAFE_FALL:
		return 0
	return int(round((distance - SAFE_FALL) * DMG_PER_M))
