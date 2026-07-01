class_name ViewmodelAnim
extends Object
## Pure procedural first-person viewmodel animation (M7). Maps (kind, phase t in [0,1]) to a
## position + rotation OFFSET applied on top of the base viewmodel placement (VM_OFFSET / VM_YAW).
## No nodes, no engine state → headless-testable. Presentation-only (AGENTS.md §7).
## pos offset is in camera space (right=+X, up=+Y, forward=-Z); rot offset is (pitch, yaw, roll) rad.

const SWING := 0   # melee: a quick forward slash/bash of the held weapon
const SWAP := 1    # weapon change: the gun rises into view from a lowered position
const RECOIL := 2  # firing: a sharp up/back kick that snaps in and settles back
const RELOAD := 3  # reload: cant the gun inward/down to work the mag, then return

const SWING_DUR := 0.34   # seconds
const SWAP_DUR := 0.40
const RECOIL_DUR := 0.11  # short + snappy; on full-auto each shot restarts it → a sustained jolt
const RELOAD_DUR := 2.0   # fallback; the renderer drives the real per-weapon reload_secs

## Offset for an animation at phase t. Outside [0,1) → rest (zero), so a finished/!started anim is a
## no-op. SWING returns to rest at both ends (sin envelope); SWAP starts lowered and rises to rest.
static func sample(kind: int, t: float) -> Dictionary:
	if t < 0.0 or t >= 1.0:
		return {"pos": Vector3.ZERO, "rot": Vector3.ZERO}
	match kind:
		SWING: return _swing(t)
		SWAP: return _swap(t)
		RECOIL: return _recoil(t)
		RELOAD: return _reload(t)
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

# ---- Continuous locomotion (not a one-shot anim; composed every frame) -------------------------
# Applied on top of the base placement alongside any active swing/swap/recoil. The renderer eases
# the sprint amount and advances the bob phase by distance travelled; these stay pure for testing.

const SPRINT_LOWER_POS := Vector3(0.04, -0.06, 0.05)   # gun dips + shifts out of the aim when sprinting (stays partly in frame)
const SPRINT_LOWER_ROT := Vector3(0.50, -0.30, 0.16)   # muzzle angled down/across (can't fire while sprinting)
const CLIMB_LOWER_POS := Vector3(0.05, -0.09, 0.08)    # ladder/vault: gun drops low but stays partly in frame (deeper than sprint, clearly lowered)
const CLIMB_LOWER_ROT := Vector3(0.60, -0.34, 0.20)    # muzzle canted well down — deeper than sprint (not a firing pose)
const BOB_X := 0.015     # m lateral sway at full speed
const BOB_Y := 0.018     # m vertical dip at full speed
const BOB_ROLL := 0.025  # rad roll sway at full speed

## Subtle weapon bob while moving — a gentle step cadence so the held weapon reads as alive, not
## frozen. `speed_norm` (0..1) scales the amplitude (0 at a standstill); `phase` (rad) is the step
## cycle. Down-weighted on Y so each step dips (a footfall), not floats.
static func _reload(t: float) -> Dictionary:
	# Cant the gun inward + down to work the magazine (you'd look at the magwell), hold through the
	# middle with a couple of taps (mag out / seat / slap), then return to rest. Trapezoid envelope:
	# ramp in over the first ~18%, hold, ramp out over the last ~18% — so it reads over the whole
	# (variable) reload duration the renderer passes in.
	var env := clampf(t / 0.18, 0.0, 1.0) * clampf((1.0 - t) / 0.18, 0.0, 1.0)
	var tap := maxf(sin(t * PI * 3.0), 0.0)   # downward taps during the mag work
	var pos := Vector3(-0.05 * env, (-0.09 - 0.04 * tap) * env, 0.04 * env)
	var rot := Vector3(0.20 * env, 0.32 * env, -0.55 * env)   # roll inward (-Z) to show the magwell + yaw/pitch in
	return {"pos": pos, "rot": rot}

static func walk_bob(speed_norm: float, phase: float) -> Dictionary:
	var amp := clampf(speed_norm, 0.0, 1.0)
	var pos := Vector3(sin(phase) * BOB_X * amp, -absf(sin(phase)) * BOB_Y * amp, 0.0)
	var rot := Vector3(0.0, 0.0, sin(phase) * BOB_ROLL * amp)
	return {"pos": pos, "rot": rot}
