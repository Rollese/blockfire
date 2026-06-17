class_name InputController
extends Node
## Reads the real Input singleton each sim tick and produces the command dict consumed by the
## predictor + InputCommand.encode: {move_x, move_y (WORLD-space), yaw, pitch, buttons}. Mouse
## relative motion accumulates in _input; look feel/sign is a playtest knob (Task 26). Pure
## button mapping is delegated to InputMap2; the world-space rotation matches yaw 0 = +Z.

const LOOK_RAD_PER_PIXEL := 0.003   # base mouse gain; multiplied by settings.sensitivity

var yaw: float = 0.0
var pitch: float = 0.0
var _mouse_rel: Vector2 = Vector2.ZERO
var motion_events: int = 0   # diagnostic: count of mouse-motion events seen (proves window input)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_rel += (event as InputEventMouseMotion).relative
		motion_events += 1

## Apply accumulated look. Separated out so it is unit-testable without the Input singleton.
func apply_look(rel: Vector2, settings: ClientSettings) -> void:
	var gain := LOOK_RAD_PER_PIXEL * settings.sensitivity
	yaw = wrapf(yaw - rel.x * gain, -PI, PI)
	var inv := -1.0 if settings.invert_y else 1.0
	pitch = clampf(pitch - rel.y * gain * inv, -Pawn.MAX_PITCH, Pawn.MAX_PITCH)

func gather(settings: ClientSettings) -> Dictionary:
	apply_look(_mouse_rel, settings)
	_mouse_rel = Vector2.ZERO
	var local_x: float = Input.get_axis("move_left", "move_right")   # +X = right
	var local_z: float = Input.get_axis("move_back", "move_fwd")     # +Z = forward
	var f := Vector2(local_x, local_z).rotated(yaw)            # local -> world (sign verified in playtest)
	var pressed := {
		"jump": Input.is_action_pressed("jump"),
		"crouch": Input.is_action_pressed("crouch"),
		"prone": Input.is_action_pressed("prone"),
		"sprint": Input.is_action_pressed("sprint"),
		"lean_left": Input.is_action_pressed("lean_left"),
		"lean_right": Input.is_action_pressed("lean_right"),
		"fire": Input.is_action_pressed("fire"),
		"reload": Input.is_action_pressed("reload"),
	}
	return {"move_x": f.x, "move_y": f.y, "yaw": yaw, "pitch": pitch,
		"buttons": InputMap2.buttons_from(pressed)}

func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
