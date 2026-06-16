class_name World
extends RefCounted
## Authoritative entity registry. id -> Pawn.

var pawns: Dictionary = {}
var vehicles: Dictionary = {}   # vid -> Vehicle (ids in Vehicle.ID_BASE range, disjoint from pawns)

func spawn(id: int) -> Pawn:
	var p := Pawn.new(id)
	pawns[id] = p
	return p

func despawn(id: int) -> void:
	pawns.erase(id)

func get_pawn(id: int) -> Pawn:
	return pawns.get(id)

func spawn_vehicle(v: Vehicle) -> void:
	vehicles[v.id] = v

func vehicle_state_map() -> Dictionary:
	var m := {}
	for vid in vehicles:
		m[vid] = (vehicles[vid] as Vehicle).to_state()
	return m

## A fresh id -> EntityState map (decoupled clones, safe to store/send).
func state_map() -> Dictionary:
	var m := {}
	for id in pawns:
		m[id] = (pawns[id] as Pawn).to_state()
	return m
