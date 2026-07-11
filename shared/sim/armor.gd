class_name Armor
extends Object
## Simplified loadout armor (M5.5-P2): one class bundles body damage-reduction + move-speed
## penalty + (implicit) helmet headshot protection. Pure rules; the data here keeps the damage
## equation in one place so client prediction and server authority cannot diverge.
## See docs/specs/combat-depth-2.md §2.

const LIGHT := 0
const MEDIUM := 1
const HEAVY := 2

const _BODY_MULT := {LIGHT: 1.0, MEDIUM: 0.85, HEAVY: 0.7}
# Move-speed multiplier by armor tier (M19: player-picked armor is a real trade-off — widened from
# the M5.5 1.0/0.95/0.9 so Light is a genuine speed pick and Heavy a genuine tank pick).
const _SPEED_MULT := {LIGHT: 1.2, MEDIUM: 1.0, HEAVY: 0.8}

## Fraction of body damage that lands (lower tier = tougher). Default LIGHT for unknown ids.
static func body_mult(cls: int) -> float:
	return float(_BODY_MULT.get(cls, 1.0))

## Move-speed multiplier applied to the M2 stance speeds in Pawn.step().
static func speed_mult(cls: int) -> float:
	return float(_SPEED_MULT.get(cls, 1.0))

## A headshot of `head_dmg` (already incl. the headshot mult, pre-armor) is an instant kill unless
## a HEAVY helmet absorbs enough that it no longer meets/exceeds current HP. LIGHT/MEDIUM never save.
static func headshot_lethal(cls: int, head_dmg: int, hp: int) -> bool:
	if cls != HEAVY:
		return head_dmg >= hp
	return int(round(float(head_dmg) * body_mult(HEAVY))) >= hp
