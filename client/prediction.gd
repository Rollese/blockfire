class_name Prediction
extends RefCounted
## Client-side prediction + reconciliation for the local pawn (movement only in M2).

var predicted := Pawn.new(0)
var pending: Array = []   # [{tick, move_x, move_y, yaw}], ascending tick

func record_input(client_tick: int, move_x: float, move_y: float, yaw: float) -> void:
	predicted.step(SimLoop.DT, {"move_x": move_x, "move_y": move_y, "yaw": yaw})
	pending.append({"tick": client_tick, "move_x": move_x, "move_y": move_y, "yaw": yaw})

func reconcile(auth_pos: Vector3, auth_yaw: float, last_input_tick: int) -> void:
	var kept := []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	for inp in pending:
		predicted.step(SimLoop.DT, {"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]})
