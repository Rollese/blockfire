class_name StancePose
extends Object
## Pure: replicated entity state -> placeholder-capsule render pose. The renderer applies this; no
## gameplay logic. Heights track Stance.body_height so the capsule matches the sim's stance.

const LEAN_TILT := 0.18   # radians

## Local first-person camera lean. `lat` = signed lateral peek along the camera's right vector
## (matches the server's LEAN_OFFSET shot-origin shift so the crosshair lines up with the shot);
## `roll` = view roll about forward. Left peeks/rolls one way, right the other. Pure for testing.
static func camera_lean(lean: int) -> Dictionary:
	if lean == Stance.LEAN_LEFT:
		return {"lat": -Stance.LEAN_OFFSET, "roll": LEAN_TILT}
	elif lean == Stance.LEAN_RIGHT:
		return {"lat": Stance.LEAN_OFFSET, "roll": -LEAN_TILT}
	return {"lat": 0.0, "roll": 0.0}

static func of(stance: int, lean: int, downed: bool, climbing: bool) -> Dictionary:
	var s := Stance.PRONE if downed else stance
	var h := Stance.body_height(s)
	var tilt := 0.0
	if lean == Stance.LEAN_LEFT: tilt = LEAN_TILT
	elif lean == Stance.LEAN_RIGHT: tilt = -LEAN_TILT
	return {"height": h, "y_offset": h * 0.5, "tilt": tilt, "climbing": climbing}
