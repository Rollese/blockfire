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
var armor_class: int = 0   # M5.5-P2 tier (LIGHT/MEDIUM/HEAVY); immutable per life, replicated on ENTER
var weapon: int = 0        # equipped weapon id (Weapon.AR/SMG/DMR/RPG/PISTOL); replicated on ENTER for the held-weapon silhouette

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
	e.armor_class = armor_class
	e.weapon = weapon
	return e
