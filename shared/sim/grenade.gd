class_name Grenade
extends Object
## Pure helpers for server-side thrown grenades (M4 Phase 2). A grenade is a plain dict held by
## the server; these are the deterministic, unit-testable math for its ballistic flight and blast
## falloff. The `type` (FRAG/SMOKE) is stored on that dict — throw/arc/fuse are identical for both;
## only the detonation side effect differs (server). Nothing here touches networking or the
## snapshot path. See docs/specs/destruction.md.

const FRAG := 0            # area damage to structures + pawns
const SMOKE := 1           # spawns a smoke zone (no damage)
const FLASHBANG := 2       # LOS-gated blind/deafen, no damage
const IMPACT := 3          # frag-like blast, zero fuse, detonates on first contact

## Impact grenades detonate on contact instead of on a fuse timer.
static func is_contact_fuse(type: int) -> bool:
	return type == IMPACT

const GRAVITY := 20.0      # m/s^2 downward (gameplay gravity, not realistic 9.8)
const THROW_SPEED := 18.0  # initial launch speed (m/s)

## Initial velocity for a throw in look-direction `dir`.
static func launch_velocity(dir: Vector3) -> Vector3:
	return dir.normalized() * THROW_SPEED

## One integration step of the ballistic arc. Returns {pos:Vector3, vel:Vector3}.
static func integrate(pos: Vector3, vel: Vector3, dt: float) -> Dictionary:
	var v := vel - Vector3(0.0, GRAVITY, 0.0) * dt
	return {"pos": pos + v * dt, "vel": v}

## Linear-falloff damage from a blast at `center` onto a point `at`: max_dmg at the centre,
## 0 at/beyond `radius`. Never negative.
static func falloff_damage(center: Vector3, at: Vector3, max_dmg: int, radius: float) -> int:
	if radius <= 0.0:
		return 0
	var d := center.distance_to(at)
	if d >= radius:
		return 0
	return int(round(float(max_dmg) * (1.0 - d / radius)))
