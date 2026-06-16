class_name EntityState
extends RefCounted
## The replicated view of one entity. Snapshots are maps of id -> EntityState.

var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var stance: int = 0   # Stance.STAND/CROUCH/PRONE
var lean: int = 0     # Stance.LEAN_*
var team: int = 0
var alive: bool = true
var health: int = 100
var is_downed: bool = false
var climbing: bool = false
var squad: int = 0

func clone() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	e.pitch = pitch
	e.stance = stance
	e.lean = lean
	e.team = team
	e.alive = alive
	e.health = health
	e.is_downed = is_downed
	e.climbing = climbing
	e.squad = squad
	return e
