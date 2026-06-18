class_name AiDrill
extends RefCounted
## Re-homed M4.5-P3 driller exerciser (climbs/vaults gate artifact). Logic unchanged.

const DRILL_CLIMB := 0   # drill phase: go climb the ladder
const DRILL_VAULT := 1   # drill phase: go vault the sandbag
const DRILL_PHASE_TIMEOUT := 1500   # ticks (~50 s @30Hz): reset stuck driller to next phase

## Pure driller steering. phase 0 = go climb the ladder, phase 1 = go vault the sandbag.
## Returns {"move_to": Vector3, "force_climb": bool, "next_phase": int}.
## - CLIMB: steer toward the ladder base. force_climb=true once horizontally within (radius+0.5)
##   of the base. next_phase flips to VAULT once my_pos.y >= top.y - 0.3 (reached the top).
## - VAULT: steer toward the sandbag world point. next_phase flips back to CLIMB once
##   horizontally within ~1.5 m of the sandbag (vaulted past it).
static func drill_step(phase: int, my_pos: Vector3, ladder: Dictionary, sandbag_world: Vector3) -> Dictionary:
	if phase == DRILL_CLIMB:
		var base: Vector3 = ladder["bottom"]
		var top: Vector3 = ladder["top"]
		var radius: float = float(ladder["radius"])
		# Check if we've reached the ladder top (done climbing).
		if my_pos.y >= top.y - 0.3:
			return {"move_to": base, "force_climb": true, "next_phase": DRILL_VAULT}
		# Check horizontal distance to the base for force-climb engagement.
		var horiz_dist := Vector2(my_pos.x - base.x, my_pos.z - base.z).length()
		var force_climb := horiz_dist <= radius + 0.5
		return {"move_to": base, "force_climb": force_climb, "next_phase": DRILL_CLIMB}
	else:
		# VAULT phase: steer toward the sandbag; once within 1.5 m (vaulted past it), reset.
		var horiz_dist := Vector2(my_pos.x - sandbag_world.x, my_pos.z - sandbag_world.z).length()
		if horiz_dist <= 1.5:
			return {"move_to": sandbag_world, "force_climb": false, "next_phase": DRILL_CLIMB}
		return {"move_to": sandbag_world, "force_climb": false, "next_phase": DRILL_VAULT}
