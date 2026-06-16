class_name Vault
extends Object
## Pure helpers for auto-vaulting a low (waist-height) blocker. Height-generic: any blocker
## whose top is <= VAULT_MAX_HEIGHT is vaultable, so future low pieces vault with no code change.
## State lives on the Pawn (vaulting / vault_* fields); SimLoop drives the arc each tick.

const VAULT_MAX_HEIGHT := 1.2   # m; half structure piece (1.0 m) qualifies, full wall (2.0 m) does not
const VAULT_TICKS := 8          # ticks to complete the arc (~0.27 s @30Hz)
const VAULT_FORWARD := 2.5      # m carried forward, enough to clear one CELL_SIZE (2.0 m) obstacle
const VAULT_PEAK := 0.6         # m arc apex above the straight line

## A standing, moving pawn may vault a blocker whose top is in (0, VAULT_MAX_HEIGHT].
static func can_vault(blocker_top: float, stance: int, moving: bool) -> bool:
	return stance == Stance.STAND and moving and blocker_top > 0.0 and blocker_top <= VAULT_MAX_HEIGHT

## Position along the vault arc. progress in [0,1]: linear in the horizontal, sine bump in y.
static func arc_pos(from: Vector3, to: Vector3, progress: float) -> Vector3:
	var t := clampf(progress, 0.0, 1.0)
	var p := from.lerp(to, t)
	p.y = lerpf(from.y, to.y, t) + sin(PI * t) * VAULT_PEAK
	return p

## Begin a vault on `pawn` from `from` in flat unit direction `dir`. Landing target is FORWARD
## ahead at y=0 (SimLoop applies platform floor on completion if relevant).
static func begin(pawn: Pawn, from: Vector3, dir: Vector3) -> void:
	pawn.vaulting = true
	pawn.vault_tick = 0
	pawn.vault_from = from
	pawn.vault_to = Vector3(from.x + dir.x * VAULT_FORWARD, 0.0, from.z + dir.z * VAULT_FORWARD)

## Advance the arc one tick; returns the new position. Clears `vaulting` and snaps to `vault_to`
## on the final tick.
static func advance(pawn: Pawn) -> Vector3:
	pawn.vault_tick += 1
	if pawn.vault_tick >= VAULT_TICKS:
		pawn.vaulting = false
		return pawn.vault_to
	return arc_pos(pawn.vault_from, pawn.vault_to, float(pawn.vault_tick) / float(VAULT_TICKS))
