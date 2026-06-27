class_name BulletPassby
extends Object
## Pure near-miss classifier (M7, view-only — AGENTS.md §7). A remote pawn's shot arrives at the
## client as a ray (origin + unit dir) on SHOT_FX. If that ray's closest approach to the local eye
## is tight enough, the player should hear the supersonic snap of the round passing — a CRACK when
## it nearly clips them, a fainter WHIZ a little further out. No gameplay effect; the server has
## already resolved the shot. Stateless: one call per received SHOT_FX.

const CRACK_RADIUS := 1.6        # m — within this of the bullet line: a sharp supersonic crack
const WHIZ_RADIUS := 5.0         # m — within this (but past CRACK): a softer whiz/zip
const MAX_RANGE := 400.0         # m — the bullet only travels so far; ignore the line beyond it

## Returns {"kind": "" | "bullet_crack" | "bullet_whiz", "point": Vector3}.
## `point` is the closest-approach position on the ray (so the audio plays spatially to the side the
## round actually passed), meaningful only when kind != "".
static func classify(origin: Vector3, dir: Vector3, eye: Vector3,
		crack_radius: float = CRACK_RADIUS, whiz_radius: float = WHIZ_RADIUS,
		max_range: float = MAX_RANGE) -> Dictionary:
	var none := {"kind": "", "point": Vector3.ZERO}
	var ndir := dir
	var len_sq := ndir.length_squared()
	if len_sq < 1e-8:
		return none                      # degenerate ray — nothing to pass by
	ndir = ndir / sqrt(len_sq)
	var to_eye := eye - origin
	var t := to_eye.dot(ndir)
	if t <= 0.0:
		return none                      # eye is behind the muzzle — the round flies away from us
	t = minf(t, max_range)               # clamp to how far the round actually travels
	var closest := origin + ndir * t
	var miss := closest.distance_to(eye)
	if miss <= crack_radius:
		return {"kind": "bullet_crack", "point": closest}
	if miss <= whiz_radius:
		return {"kind": "bullet_whiz", "point": closest}
	return none
