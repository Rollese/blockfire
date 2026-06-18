class_name AiCover
extends RefCounted
## P2 cover behaviour: nearest-cover selection + stance choice under pressure
## (docs/specs/bot-ai.md §7). Coarse cover = structure cell-centres from the WorldModel.

const COVER_PRESSURE_THRESH := 0.5

## Nearest cover position to self, or self position if none known.
static func pick_cover(w: WorldModel) -> Vector3:
	var me: Vector3 = w.self_state.pos if w.self_state else Vector3.ZERO
	var best := me
	var best_d := INF
	for c in w.cover:
		var d: float = me.distance_to(c)
		if d < best_d:
			best_d = d; best = c
	return best

## Crouch when pressure exceeds the threshold; stand otherwise (§7 stance control).
static func desired_stance(incoming_fire: float) -> int:
	return Stance.CROUCH if incoming_fire >= COVER_PRESSURE_THRESH else Stance.STAND
