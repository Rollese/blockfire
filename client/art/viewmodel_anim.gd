class_name ViewmodelAnim
extends Object
## Pure procedural first-person viewmodel animation (M7). Maps (kind, phase t in [0,1]) to a
## position + rotation OFFSET applied on top of the base viewmodel placement (VM_OFFSET / VM_YAW).
## No nodes, no engine state → headless-testable. Presentation-only (AGENTS.md §7).
## pos offset is in camera space (right=+X, up=+Y, forward=-Z); rot offset is (pitch, yaw, roll) rad.

const SWING := 0   # melee: a quick forward slash/bash of the held weapon
const SWAP := 1    # weapon change: the gun rises into view from a lowered position

const SWING_DUR := 0.34   # seconds
const SWAP_DUR := 0.40

## Offset for an animation at phase t. Outside [0,1) → rest (zero), so a finished/!started anim is a
## no-op. SWING returns to rest at both ends (sin envelope); SWAP starts lowered and rises to rest.
static func sample(kind: int, t: float) -> Dictionary:
	if t < 0.0 or t >= 1.0:
		return {"pos": Vector3.ZERO, "rot": Vector3.ZERO}
	match kind:
		SWING: return _swing(t)
		SWAP: return _swap(t)
		_: return {"pos": Vector3.ZERO, "rot": Vector3.ZERO}

static func _swing(t: float) -> Dictionary:
	# sin(t*PI): 0 at both ends, 1 at the middle — a single thrust+recover with no pop.
	var env := sin(t * PI)
	# Thrust the muzzle forward (-Z) + slightly right/down, pitch it down and yaw across the slash.
	var pos := Vector3(0.08 * env, -0.05 * env, -0.16 * env)
	var pitch := -0.9 * sin(clampf((t - 0.1) / 0.6, 0.0, 1.0) * PI)   # quick down then back
	var rot := Vector3(pitch, -0.55 * env, 0.30 * env)
	return {"pos": pos, "rot": rot}

static func _swap(t: float) -> Dictionary:
	# Raise: fully lowered at t=0, eased back to rest at t=1 (ease-out so it snaps up near the top).
	var down := 1.0 - t
	var ease := down * down
	var pos := Vector3(0.0, -0.30 * ease, 0.05 * ease)   # gun dropped out of frame, pulled back a touch
	var rot := Vector3(0.65 * ease, 0.0, 0.10 * ease)    # tilted muzzle-down while lowered
	return {"pos": pos, "rot": rot}
