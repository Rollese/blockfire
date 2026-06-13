class_name World
extends RefCounted
## Authoritative entity registry. id -> Pawn.

var pawns: Dictionary = {}

func spawn(id: int) -> Pawn:
	var p := Pawn.new(id)
	pawns[id] = p
	return p

func despawn(id: int) -> void:
	pawns.erase(id)

func get_pawn(id: int) -> Pawn:
	return pawns.get(id)

## A fresh id -> EntityState map (decoupled clones, safe to store/send).
func state_map() -> Dictionary:
	var m := {}
	for id in pawns:
		m[id] = (pawns[id] as Pawn).to_state()
	return m
