class_name SimLoop
extends RefCounted
## Fixed-timestep authoritative simulation. Same code runs on server (authority) and
## client (prediction). inputs: Dictionary[int id -> command dict]. See AGENTS.md §7.

const DT := 1.0 / 30.0   # 30 Hz

var tick: int = 0
var world := World.new()
var structures = null   # optional StructureStore; when set, resolves movement collision

func step(inputs: Dictionary) -> void:
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		if not p.alive:
			continue
		var prev := p.pos
		p.step(DT, inputs.get(id, {}))
		if structures != null:
			p.pos = structures.resolve_movement(prev, p.pos)
	tick += 1
