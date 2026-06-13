class_name Prediction
extends RefCounted
## Client-side prediction + server reconciliation for the local pawn.
## Predicts immediately on input; when the authoritative state arrives it snaps to
## it and replays inputs the server hasn't consumed yet. See M1 spec.

var predicted := Pawn.new(0)
var pending: Array = []   # [{tick, move_x, move_y, yaw}], ascending tick

func record_input(client_tick: int, move_x: float, move_y: float, yaw: float) -> void:
	predicted.step(SimLoop.DT, move_x, move_y, yaw)
	pending.append({"tick": client_tick, "move_x": move_x, "move_y": move_y, "yaw": yaw})

## Apply authoritative own-pawn state. last_input_tick = last input the server consumed.
func reconcile(auth_pos: Vector3, auth_yaw: float, last_input_tick: int) -> void:
	var kept := []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	for inp in pending:
		predicted.step(SimLoop.DT, inp["move_x"], inp["move_y"], inp["yaw"])
