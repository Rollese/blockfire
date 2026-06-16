class_name VehicleState
extends RefCounted
## Replicated view of one vehicle. Vehicle snapshots are maps of vid -> VehicleState.

var pos: Vector3 = Vector3.ZERO
var heading: float = 0.0       # body yaw
var turret_yaw: float = 0.0
var hp: int = 0
var type: int = 0
var seats: Array = []          # seat-index -> occupant pawn id (0 = empty)

func clone() -> VehicleState:
	var e := VehicleState.new()
	e.pos = pos
	e.heading = heading
	e.turret_yaw = turret_yaw
	e.hp = hp
	e.type = type
	e.seats = seats.duplicate()
	return e
