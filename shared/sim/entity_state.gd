class_name EntityState
extends RefCounted
## The replicated view of one entity. Snapshots are maps of id -> EntityState.

var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0

func clone() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	return e
