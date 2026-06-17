class_name StancePose
extends Object
## Pure: replicated entity state -> placeholder-capsule render pose. The renderer applies this; no
## gameplay logic. Heights track Stance.body_height so the capsule matches the sim's stance.

const LEAN_TILT := 0.18   # radians

static func of(stance: int, lean: int, downed: bool, climbing: bool) -> Dictionary:
	var s := Stance.PRONE if downed else stance
	var h := Stance.body_height(s)
	var tilt := 0.0
	if lean == Stance.LEAN_LEFT: tilt = LEAN_TILT
	elif lean == Stance.LEAN_RIGHT: tilt = -LEAN_TILT
	return {"height": h, "y_offset": h * 0.5, "tilt": tilt, "climbing": climbing}
