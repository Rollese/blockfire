class_name Ladder
extends Object
## Pure helpers for static map ladders + walkable platforms. A ladder is a vertical climb volume
## {bottom, top, radius} (bottom/top share x,z); a platform is a walkable AABB {min, max}.
## SimLoop owns the geometry arrays and the climbing flag; these helpers are side-effect-free.

const LADDER_CLIMB_SPEED := 3.0     # m/s vertical, sign from move_y
const LADDER_CAPTURE_RADIUS := 0.6  # m (x,z) capture distance from the ladder line
const ANCHOR_EPS := 0.1             # m tolerance at top/bottom anchors

## The ladder whose volume contains world point `pos`, or {} if none. (x,z) within radius of the
## line and y within [bottom.y - eps, top.y + eps].
static func capture(ladders: Array, pos: Vector3) -> Dictionary:
	for l in ladders:
		var b: Vector3 = l["bottom"]
		var t: Vector3 = l["top"]
		if Vector2(pos.x - b.x, pos.z - b.z).length() > float(l["radius"]):
			continue
		if pos.y >= b.y - ANCHOR_EPS and pos.y <= t.y + ANCHOR_EPS:
			return l
	return {}

## Engage climb when in the volume with upward intent and room above (won't trap a passer-by who
## merely brushes the volume with no climb input).
static func should_engage(ladder: Dictionary, pos: Vector3, move_y: float) -> bool:
	if ladder.is_empty():
		return false
	var t: Vector3 = ladder["top"]
	return move_y > 0.1 and pos.y < t.y - ANCHOR_EPS

## Vertical climb step: move_y sign drives y at LADDER_CLIMB_SPEED, clamped to [bottom.y, top.y];
## (x,z) locked to the ladder line (no strafe in v1).
static func climb_step(ladder: Dictionary, pos: Vector3, move_y: float, dt: float) -> Vector3:
	var b: Vector3 = ladder["bottom"]
	var t: Vector3 = ladder["top"]
	var v: float = signf(move_y) * LADDER_CLIMB_SPEED if absf(move_y) > 0.1 else 0.0
	return Vector3(b.x, clampf(pos.y + v * dt, b.y, t.y), b.z)

## Highest platform top at or below `y` whose footprint contains (x,z); 0.0 (ground) if none.
static func platform_floor(platforms: Array, x: float, z: float, y: float) -> float:
	var best := 0.0
	for p in platforms:
		var mn: Vector3 = p["min"]
		var mx: Vector3 = p["max"]
		if x >= mn.x and x <= mx.x and z >= mn.z and z <= mx.z:
			if y >= mx.y - ANCHOR_EPS and mx.y > best:
				best = mx.y
	return best
