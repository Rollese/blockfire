class_name Prediction
extends RefCounted
## Client-side prediction + reconciliation for the local pawn (movement only in M2).

var predicted := Pawn.new(0)
var pending: Array = []   # [{tick, move_x, move_y, yaw}], ascending tick
var world_half: float = Pawn.WORLD_HALF   # set from the map so prediction clamps like the server

func record_input(client_tick: int, move_x: float, move_y: float, yaw: float) -> void:
	predicted.step(SimLoop.DT, {"move_x": move_x, "move_y": move_y, "yaw": yaw}, world_half)
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
		predicted.step(SimLoop.DT, {"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]}, world_half)

func record_cmd(client_tick: int, cmd: Dictionary) -> void:
	predicted.step(SimLoop.DT, cmd, world_half)
	pending.append({"tick": client_tick, "cmd": cmd})

func reconcile_full(auth_pos: Vector3, auth_yaw: float, auth_pitch: float, last_input_tick: int) -> void:
	var kept: Array = []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	predicted.pitch = auth_pitch
	for inp in pending:
		if inp.has("cmd"):
			predicted.step(SimLoop.DT, inp["cmd"], world_half)
		else:
			predicted.step(SimLoop.DT, {"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]}, world_half)
