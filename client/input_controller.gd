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
var _prone_on: bool = false   # prone is a TOGGLE (press to flip), not hold-to-prone

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_rel += (event as InputEventMouseMotion).relative
		motion_events += 1

## Rotate local move intent (x=right, z=forward) into world space by yaw. Pure, so it is
## unit-testable without the Input singleton. Result is consumed as Vector3(move_x,0,move_y)
## by Pawn.step, so it must match the codebase aim convention (Combat._forward):
## forward(yaw)=(sin,cos), right(yaw)=(cos,-sin) on the XZ plane.
static func move_world(local_x: float, local_z: float, yaw: float) -> Vector2:
	# Godot's Vector2.rotated() is the opposite handedness to the sim's Y-axis yaw, so rotate
	# by -yaw: forward (0,1) -> (sin,cos), right (1,0) -> (cos,-sin), matching Combat._forward.
	return Vector2(local_x, local_z).rotated(-yaw)

## Apply accumulated look. Separated out so it is unit-testable without the Input singleton.
func apply_look(rel: Vector2, settings: ClientSettings) -> void:
	var gain := LOOK_RAD_PER_PIXEL * settings.sensitivity
	yaw = wrapf(yaw - rel.x * gain, -PI, PI)
	var inv := -1.0 if settings.invert_y else 1.0
	pitch = clampf(pitch - rel.y * gain * inv, -Pawn.MAX_PITCH, Pawn.MAX_PITCH)

## Apply the mouse delta accumulated since the last call, then clear it. Called at RENDER rate
## (not the 30 Hz sim tick) so mouse-look is smooth — gather() then just reads the current yaw/pitch.
func update_look(settings: ClientSettings) -> void:
	apply_look(_mouse_rel, settings)
	_mouse_rel = Vector2.ZERO

func gather(settings: ClientSettings) -> Dictionary:
	# Look is applied at render rate via update_look(); gather() reads the current yaw/pitch.
	var local_x: float = Input.get_axis("move_left", "move_right")   # +X = right
	# W must drive the player toward the camera's forward. The camera (Godot) looks down -Z, which
	# is the opposite of the sim's +Z "forward" yaw convention, so feed move_fwd as the negative
	# axis (Task 20 sign knob; flip back here if forward/back ever reads inverted again).
	var local_z: float = Input.get_axis("move_fwd", "move_back")
	var f := move_world(local_x, local_z, yaw)                 # local -> world
	if Input.is_action_just_pressed("prone"):
		_prone_on = not _prone_on   # toggle on each press
	var pressed := {
		"jump": Input.is_action_pressed("jump"),
		"crouch": Input.is_action_pressed("crouch"),
		"prone": _prone_on,
		"sprint": Input.is_action_pressed("sprint"),
		"lean_left": Input.is_action_pressed("lean_left"),
		"lean_right": Input.is_action_pressed("lean_right"),
		"fire": Input.is_action_pressed("fire"),
		"reload": Input.is_action_pressed("reload"),
	}
	return {"move_x": f.x, "move_y": f.y, "yaw": yaw, "pitch": pitch,
		"buttons": InputMap2.buttons_from(pressed)}

## Clear the prone toggle (call on death/deploy so the player never spawns prone).
func reset_prone() -> void:
	_prone_on = false

func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## Discard any accumulated look delta. Call while a menu owns the cursor so the view does
## not snap by the menu-time mouse travel when input resumes.
func drain_look() -> void:
	_mouse_rel = Vector2.ZERO
