class_name Projectile
extends Object
## Pure helpers for stepped bullet projectiles (M5.5-P1). A projectile is a plain dict held by the
## server pool; these are the deterministic math for its flight. Shared so the M7 client can spawn a
## cosmetic predicted tracer from the same integration. Nothing here touches networking. See
## docs/specs/combat-depth-2.md §1.

## Muzzle launch velocity for a unit look-direction at the weapon's muzzle speed.
static func initial_velocity(dir: Vector3, muzzle_velocity: float) -> Vector3:
	return dir.normalized() * muzzle_velocity

## One integration step. gravity_scale<1 = high-velocity round (little drop). Returns {pos, vel}.
static func integrate(pos: Vector3, vel: Vector3, gravity_scale: float, dt: float) -> Dictionary:
	var v := vel - Vector3(0.0, Grenade.GRAVITY * gravity_scale, 0.0) * dt
	return {"pos": pos + v * dt, "vel": v}

## A projectile expires when its lifetime is up OR it has flown past its weapon range.
## Caller passes (age_ticks, max_ticks, dist_traveled, max_range).
## max_ticks <= 0 means no TTL limit (projectile expires only by range).
static func expired(age_ticks: int, max_ticks: int, dist_traveled: float, max_range: float) -> bool:
	return (max_ticks > 0 and age_ticks >= max_ticks) or dist_traveled >= max_range
