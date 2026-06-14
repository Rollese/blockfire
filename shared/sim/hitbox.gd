class_name Hitbox
extends Object
## Head sphere + body capsule (segment+radius) ray tests from a pawn position+stance.
## dir is assumed normalized. Returns nearest hit with a headshot flag.

static func ray_sphere(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := o - c
	var b := oc.dot(d)
	var cc := oc.dot(oc) - r * r
	var disc := b * b - cc
	if disc < 0.0:
		return -1.0
	var t := -b - sqrt(disc)
	return t if t >= 0.0 else -1.0

## Closest distance between ray (o + t*d, t>=0) and segment [a,b], plus the ray t at that point.
static func ray_segment(o: Vector3, d: Vector3, a: Vector3, b: Vector3) -> Dictionary:
	var u := d                      # ray dir (unit)
	var v := b - a
	var w0 := o - a
	var aa := u.dot(u)              # = 1
	var bb := u.dot(v)
	var cc := v.dot(v)
	var dd := u.dot(w0)
	var ee := v.dot(w0)
	var den := aa * cc - bb * bb
	var s := 0.0   # ray param
	var tseg := 0.0
	if den > 0.00001:
		s = (bb * ee - cc * dd) / den
		tseg = (aa * ee - bb * dd) / den
	else:
		s = -dd  # parallel: project
		tseg = 0.0
	s = maxf(s, 0.0)
	tseg = clampf(tseg, 0.0, 1.0)
	var pr := o + u * s
	var ps := a + v * tseg
	return {"dist": pr.distance_to(ps), "t": s}

static func raycast_pawn(o: Vector3, d: Vector3, pawn_pos: Vector3, stance: int, max_dist: float) -> Dictionary:
	var dir := d.normalized()
	# head sphere
	var head_c := pawn_pos + Vector3(0, Stance.head_center(stance), 0)
	var th := ray_sphere(o, dir, head_c, Stance.HEAD_RADIUS)
	# body capsule (feet+r .. body_height-r)
	var bh := Stance.body_height(stance)
	var a := pawn_pos + Vector3(0, Stance.BODY_RADIUS, 0)
	var b := pawn_pos + Vector3(0, maxf(bh - Stance.BODY_RADIUS, Stance.BODY_RADIUS), 0)
	var seg := ray_segment(o, dir, a, b)
	var body_t: float = seg["t"] if seg["dist"] <= Stance.BODY_RADIUS else -1.0

	var head_ok := th >= 0.0 and th <= max_dist
	var body_ok: bool = body_t >= 0.0 and body_t <= max_dist
	if not head_ok and not body_ok:
		return {"hit": false, "headshot": false, "t": -1.0}
	if head_ok and (not body_ok or th <= body_t):
		return {"hit": true, "headshot": true, "t": th}
	return {"hit": true, "headshot": false, "t": body_t}
