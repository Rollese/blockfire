class_name Prediction
extends RefCounted
## Client-side prediction + reconciliation for the local pawn (movement only in M2).

var predicted := Pawn.new(0)
var pending: Array = []   # [{tick, move_x, move_y, yaw}], ascending tick
var world_half: float = Pawn.WORLD_HALF   # set from the map so prediction clamps like the server
# Optional client-mirror of the server's StructureStore. When set, prediction stops the predicted
# pawn at walls EXACTLY like the server's SimLoop._step_normal (resolve_movement) — without it the
# client predicts straight through structures and the server yanks it back (the wall rubber-band).
var structures = null

## One collision-aware movement step: integrate, then (like the server) clamp the horizontal move
## back out of any structure it would have entered.
func _advance(cmd: Dictionary) -> void:
	var prev := predicted.pos
	predicted.step(SimLoop.DT, cmd, world_half)
	if structures != null:
		predicted.pos = structures.resolve_movement(prev, predicted.pos)

func record_input(client_tick: int, move_x: float, move_y: float, yaw: float) -> void:
	_advance({"move_x": move_x, "move_y": move_y, "yaw": yaw})
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
		_advance({"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]})

func record_cmd(client_tick: int, cmd: Dictionary) -> void:
	_advance(cmd)
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
			_advance(inp["cmd"])
		else:
			_advance({"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]})
