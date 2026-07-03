class_name FootstepAudio
extends Object
## Pure map from locomotion context to the footstep audio event in data/sounds.json (M7, view-only).
## WASD bundle actions: Walk / Run / Sneak / Drop (land) / Jump on Dirt (default outdoor surface).

const WALK := 0
const RUN := 1
const SNEAK := 2
const LAND := 3
const JUMP := 4

const SPRINT_INTENSITY := 0.85   # FootstepCadence intensity at ~sprint speed

## Pick the catalog `type` for a footfall. When `action` is set (renderer always passes one),
## it wins; otherwise derive from stance + cadence intensity.
static func event_for(intensity: float, stance: int, action: int = -1) -> String:
	match action:
		LAND: return "footstep_land"
		JUMP: return "footstep_jump"
		SNEAK: return "footstep_sneak"
		RUN: return "footstep_run"
		WALK: return "footstep_walk"
	if stance == Stance.CROUCH:
		return "footstep_sneak"
	if intensity >= SPRINT_INTENSITY:
		return "footstep_run"
	return "footstep_walk"

## Infer action from cadence output when the renderer doesn't pass an explicit override.
static func action_from(intensity: float, stance: int) -> int:
	if stance == Stance.CROUCH:
		return SNEAK
	if intensity >= SPRINT_INTENSITY:
		return RUN
	return WALK
