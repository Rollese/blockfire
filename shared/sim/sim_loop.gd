class_name SimLoop
extends RefCounted
## Fixed-timestep authoritative simulation. Same code runs on server (authority) and
## client (prediction). inputs: Dictionary[int id -> command dict]. See AGENTS.md §7.

const DT := 1.0 / 30.0   # 30 Hz

var tick: int = 0
var world := World.new()

func step(inputs: Dictionary) -> void:
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		if not p.alive:
			continue
		p.step(DT, inputs.get(id, {}))
	tick += 1
