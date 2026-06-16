class_name DamageDir
extends Object
## Pure: world-space bearing (radians) from a victim toward a damage source, matching the
## atan2(dx,dz) convention HudModel uses for compass/arc bearings.

static func bearing(victim_pos: Vector3, source_pos: Vector3) -> float:
	var d := source_pos - victim_pos
	if absf(d.x) < 0.0001 and absf(d.z) < 0.0001:
		return 0.0
	return atan2(d.x, d.z)
