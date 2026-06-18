class_name CharacterAnim
extends Object
## Pure mapping: replicated render state -> Kenney clip name + whether it loops. No gameplay logic
## (AGENTS.md §7). Speed is the renderer's per-frame horizontal speed estimate in m/s (velocity is
## not on the wire). Crouch/prone *shape* stays in WorldRenderer._pose_entity (shrink/tip) for v1;
## this only selects the locomotion/holding/down clip. Returns {"clip": String, "loop": bool}.

const WALK_SPEED := 0.6     # m/s above which the figure is "moving"
const SPRINT_SPEED := 4.5   # m/s above which it is "sprinting"

static func clip_for(downed: bool, speed: float, _stance: int) -> Dictionary:
	if downed:
		# DBNO: alive but incapacitated. The renderer lays the body on its back (face-up); a calm
		# looping idle reads as "downed, breathing" — not the `die` collapse clip (arm-flail).
		return {"clip": "idle", "loop": true}
	if speed >= SPRINT_SPEED:
		return {"clip": "sprint", "loop": true}
	if speed >= WALK_SPEED:
		return {"clip": "walk", "loop": true}
	# Stationary + alive: two-handed weapon-ready hold (the soldier carries a HeldWeapon), so it reads
	# as an armed combatant rather than an arms-down civilian idle.
	return {"clip": "holding-both", "loop": true}
