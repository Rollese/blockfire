class_name Pawn
extends RefCounted
## Kinematic player pawn. Authoritative on the server; predicted on the client.
## Movement is world-space for M1 (no yaw-relative strafe yet). See M1 spec.

const SPEED := 6.0          # metres / second
const WORLD_HALF := 1000.0  # square world bound (metres)

var id: int
var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0

func _init(p_id: int = 0) -> void:
	id = p_id

func step(dt: float, move_x: float, move_y: float, p_yaw: float) -> void:
	yaw = p_yaw
	var dir := Vector3(move_x, 0.0, move_y)
	if dir.length() > 1.0:
		dir = dir.normalized()
	pos += dir * SPEED * dt
	pos.y = 0.0
	pos.x = clampf(pos.x, -WORLD_HALF, WORLD_HALF)
	pos.z = clampf(pos.z, -WORLD_HALF, WORLD_HALF)

func to_state() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	return e
