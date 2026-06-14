class_name Pawn
extends RefCounted
## Kinematic player pawn. Authoritative on the server; predicted on the client.
## step() takes a command dict {move_x,move_y,yaw,pitch,buttons}; missing keys default,
## so partial dicts are tolerated. Movement is world-space planar + vertical jump/gravity.

const SPRINT_MULT := 1.6
const GRAVITY := 14.0
const JUMP_V0 := 4.5
const JUMP_COST := 10.0
const SPRINT_DRAIN := 15.0
const STAMINA_REGEN := 12.0
const STAMINA_REGEN_DELAY := 1.0
const STAMINA_MAX := 100.0
const WORLD_HALF := 1000.0
const MAX_PITCH := 1.4835  # ~85 degrees

var id: int
var pos: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var stance: int = 0
var lean: int = 0
var stamina: float = STAMINA_MAX
var grounded: bool = true
var health: int = 100
var alive: bool = true
var team: int = 0
var squad: int = 0
var _regen_cooldown: float = 0.0

func _init(p_id: int = 0) -> void:
	id = p_id

func step(dt: float, cmd: Dictionary) -> void:
	yaw = cmd.get("yaw", yaw)
	pitch = clampf(cmd.get("pitch", pitch), -MAX_PITCH, MAX_PITCH)
	var buttons: int = cmd.get("buttons", 0)

	# stance
	if buttons & InputCommand.BTN_PRONE:
		stance = Stance.PRONE
	elif buttons & InputCommand.BTN_CROUCH:
		stance = Stance.CROUCH
	else:
		stance = Stance.STAND
	# lean
	if buttons & InputCommand.BTN_LEAN_L:
		lean = Stance.LEAN_LEFT
	elif buttons & InputCommand.BTN_LEAN_R:
		lean = Stance.LEAN_RIGHT
	else:
		lean = Stance.LEAN_NONE

	var move := Vector3(cmd.get("move_x", 0.0), 0.0, cmd.get("move_y", 0.0))
	if move.length() > 1.0:
		move = move.normalized()
	var has_move := move.length() > 0.01

	var sprinting := bool(buttons & InputCommand.BTN_SPRINT) and stance == Stance.STAND and stamina > 0.0 and has_move
	var speed := Stance.speed(stance) * (SPRINT_MULT if sprinting else 1.0)
	velocity.x = move.x * speed
	velocity.z = move.z * speed

	# jump
	if (buttons & InputCommand.BTN_JUMP) and grounded and stamina >= JUMP_COST:
		velocity.y = JUMP_V0
		stamina -= JUMP_COST
		_regen_cooldown = STAMINA_REGEN_DELAY
		grounded = false

	# gravity + integrate
	velocity.y -= GRAVITY * dt
	pos += velocity * dt
	if pos.y <= 0.0:
		pos.y = 0.0
		velocity.y = 0.0
		grounded = true

	# stamina
	if sprinting:
		stamina -= SPRINT_DRAIN * dt
		_regen_cooldown = STAMINA_REGEN_DELAY
	else:
		_regen_cooldown = maxf(0.0, _regen_cooldown - dt)
		if _regen_cooldown <= 0.0:
			stamina += STAMINA_REGEN * dt
	stamina = clampf(stamina, 0.0, STAMINA_MAX)

	pos.x = clampf(pos.x, -WORLD_HALF, WORLD_HALF)
	pos.z = clampf(pos.z, -WORLD_HALF, WORLD_HALF)

func eye_position() -> Vector3:
	return pos + Vector3(0.0, Stance.eye_height(stance), 0.0)

func to_state() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	e.pitch = pitch
	e.stance = stance
	e.lean = lean
	e.team = team
	e.squad = squad
	e.alive = alive
	e.health = health
	return e
