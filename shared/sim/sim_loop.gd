class_name SimLoop
extends RefCounted
## Fixed-timestep authoritative simulation. The SAME code runs on the server
## (authority) and the client (prediction) so they cannot diverge. See AGENTS.md §7.

const DT := 1.0 / 30.0   # 30 Hz

var tick: int = 0
var world := World.new()

## inputs: Dictionary[int id -> {move_x, move_y, yaw}]. Pawns with no input hold still.
func step(inputs: Dictionary) -> void:
	for id in world.pawns:
		var inp = inputs.get(id)
		if inp == null:
			continue
		(world.pawns[id] as Pawn).step(DT, inp["move_x"], inp["move_y"], inp["yaw"])
	tick += 1
