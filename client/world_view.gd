class_name WorldView
extends RefCounted
## Client mirror of authoritative state. Applies snapshots into the entity view, buffers
## self-excluded remotes for interpolation, and exposes read-only remotes_at(now) (interpolated)
## + self_state() (latest authoritative, for reconcile). View only — no gameplay logic.

var _local_id: int = 0
var _view: Dictionary = {}      # id -> EntityState (latest authoritative)
var _view_v: Dictionary = {}    # vid -> VehicleState
var _interp := Interpolation.new()
var last_header: Dictionary = {}
var _structs: Dictionary = {}
var _roster: Array = []

func set_local_id(id: int) -> void:
	_local_id = id

func apply_snapshot(bytes: PackedByteArray, now: float) -> Dictionary:
	last_header = Snapshot.decode_apply(bytes, _view, _view_v)
	var remotes := {}
	for id in _view:
		if id != _local_id:
			remotes[id] = (_view[id] as EntityState).clone()
	_interp.push(now, remotes)
	return last_header

func remotes_at(now: float) -> Dictionary:
	return _interp.sample(now)

func self_state() -> EntityState:
	return _view.get(_local_id)

func vehicles() -> Dictionary:
	return _view_v

func apply_structure_baseline(bytes: PackedByteArray) -> void:
	for rec in Protocol.decode_structure_baseline(bytes)["records"]:
		_structs[int(rec["id"])] = rec

func apply_structure_delta(bytes: PackedByteArray) -> void:
	var d := Protocol.decode_structure_delta(bytes)
	match int(d["op"]):
		Protocol.OP_PLACE: _structs[int(d["rec"]["id"])] = d["rec"]
		Protocol.OP_REMOVE: _structs.erase(int(d["id"]))
		Protocol.OP_CHUNK:
			if _structs.has(int(d["id"])):
				_structs[int(d["id"])]["chunks"] = int(d["mask"])

func structures() -> Dictionary:
	return _structs

func set_roster(rows: Array) -> void:
	_roster = rows

func roster() -> Array:
	return _roster
