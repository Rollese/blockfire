class_name ViewmodelAnim
extends Object
## Pure procedural first-person viewmodel animation (M7). Maps (kind, phase t in [0,1]) to a
## position + rotation OFFSET applied on top of the base viewmodel placement (VM_OFFSET / VM_YAW).
## No nodes, no engine state → headless-testable. Presentation-only (AGENTS.md §7).
## pos offset is in camera space (right=+X, up=+Y, forward=-Z); rot offset is (pitch, yaw, roll) rad.

const SWING := 0   # melee: a quick forward slash/bash of the held weapon
const SWAP := 1    # weapon change: the gun rises into view from a lowered position
const RECOIL := 2  # firing: a sharp up/back kick that snaps in and settles back

const SWING_DUR := 0.34   # seconds
const SWAP_DUR := 0.40
const RECOIL_DUR := 0.11  # short + snappy; on full-auto each shot restarts it → a sustained jolt

## Offset for an animation at phase t. Outside [0,1) → rest (zero), so a finished/!started anim is a
## no-op. SWING returns to rest at both ends (sin envelope); SWAP starts lowered and rises to rest.
static func sample(kind: int, t: float) -> Dictionary:
	if t < 0.0 or t >= 1.0:
		return {"pos": Vector3.ZERO, "rot": Vector3.ZERO}
	match kind:
		SWING: return _swing(t)
		SWAP: return _swap(t)
		RECOIL: return _recoil(t)
		_: return {"pos": Vector3.ZERO, "rot": Vector3.ZERO}

static func _swing(t: float) -> Dictionary:
	# sin(t*PI): 0 at both ends, 1 at the middle — a single thrust+recover with no pop.
	var env := sin(t * PI)
	# A forward jab/bash: thrust the muzzle forward (-Z) + dip it down and slash across (yaw+roll).
	var pos := Vector3(0.06 * env, -0.07 * env, -0.22 * env)
	var rot := Vector3(0.45 * env, -0.40 * env, 0.22 * env)   # +pitch = muzzle dips down (a bash, not an overhead)
	return {"pos": pos, "rot": rot}

static func _swap(t: float) -> Dictionary:
	# Raise: fully lowered at t=0, eased back to rest at t=1 (ease-out so it snaps up near the top).
	var down := 1.0 - t
	var ease := down * down
	var pos := Vector3(0.0, -0.30 * ease, 0.05 * ease)   # gun dropped out of frame, pulled back a touch
	var rot := Vector3(0.65 * ease, 0.0, 0.10 * ease)    # tilted muzzle-down while lowered
	return {"pos": pos, "rot": rot}

static func _recoil(t: float) -> Dictionary:
	# Snap kick at t=0 (full envelope, no ramp-up) decaying back to rest — the gun jolts up and back
	# toward the eye on the shot, then settles. pow(>1) so it falls off fast for a sharp impulse.
	var env := pow(1.0 - t, 1.6)
	var pos := Vector3(0.0, 0.012 * env, 0.05 * env)   # nudge up + push back toward the camera (+Z)
	var rot := Vector3(-0.10 * env, 0.0, 0.02 * env)   # -pitch = muzzle rises; a touch of roll for life
	return {"pos": pos, "rot": rot}
