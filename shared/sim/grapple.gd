class_name Grapple
extends Object
## Pure Assault grappling-hook rules: resolve a fired hook into a vertical climb-line anchor,
## and decide when a deployed rope may be cut. Side-effect-free; the server does the actual
## structure/terrain march and passes the hit into resolve(). Ladder geometry matches the
## strictly-vertical Ladder volume (bottom/top share x,z).

const MAX_RANGE := 22.0        # m: furthest a fired hook may anchor (march bound + guard)
const MIN_HEIGHT := 2.5        # m: min top-minus-bottom, else reject (no stubby ground ropes)
const CHARGES := 1             # single-use per life; restock from support to redeploy
const CUT_ARM_TICKS := 900     # ~30 s @30 Hz uncuttable window (guaranteed uptime)
const CUT_RADIUS := 1.5        # m: how close a player must be to cut a deployed rope
const LADDER_RADIUS := 0.6     # matches Ladder.LADDER_CAPTURE_RADIUS

## Resolve a fired hook into a vertical ladder anchor. `hit_point` is the world point the
## server's structure/terrain march struck (only meaningful when has_hit); `ground_y` is the
## terrain/platform floor directly below the anchor. Returns {ok, reason, x, z, bottom_y, top_y}.
static func resolve(origin: Vector3, hit_point: Vector3, ground_y: float, has_hit: bool) -> Dictionary:
	if not has_hit:
		return {"ok": false, "reason": "no_surface"}
	if origin.distance_to(hit_point) > MAX_RANGE:
		return {"ok": false, "reason": "out_of_range"}
	var top_y := hit_point.y
	if top_y - ground_y < MIN_HEIGHT:
		return {"ok": false, "reason": "too_short"}
	return {"ok": true, "reason": "", "x": hit_point.x, "z": hit_point.z,
		"bottom_y": ground_y, "top_y": top_y}

## A deployed rope may be cut once it has been up at least CUT_ARM_TICKS and the requester is
## within CUT_RADIUS of the climb line (x,z distance, any height).
static func can_cut(age_ticks: int, dist: float) -> bool:
	return age_ticks >= CUT_ARM_TICKS and dist <= CUT_RADIUS
