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
var _structs_version: int = 0   # bumped on every structure mutation; renderer skips its O(N) pool sync when unchanged
var _collapsed_buildings: Array = []   # M11: building_ids that COLLAPSED this window — drained by the renderer to spawn rubble
var _roster: Array = []

func set_local_id(id: int) -> void:
	_local_id = id

func apply_snapshot(bytes: PackedByteArray, now: float) -> Dictionary:
	last_header = Snapshot.decode_apply(bytes, _view, _view_v)
	var remotes := {}
	for id in _view:
		if id != _local_id:
			remotes[id] = (_view[id] as EntityState).clone()
	_interp.push(now, remotes, int(last_header.get("server_tick", 0)))
	return last_header

func remotes_at(now: float) -> Dictionary:
	return _interp.sample(now)

## Server tick the local player is currently RENDERING remotes at (now - interp DELAY). Sent as
## view_server_tick so lag-comp rewinds enemies to where they were seen (no leading required).
func view_tick(now: float) -> int:
	return _interp.sample_tick(now)

func self_state() -> EntityState:
	return _view.get(_local_id)

func vehicles() -> Dictionary:
	return _view_v

func apply_structure_baseline(bytes: PackedByteArray) -> void:
	for rec in Protocol.decode_structure_baseline(bytes)["records"]:
		_structs[int(rec["id"])] = rec
	_structs_version += 1

func apply_structure_delta(bytes: PackedByteArray) -> void:
	var d := Protocol.decode_structure_delta(bytes)
	match int(d["op"]):
		Protocol.OP_PLACE:
			_structs[int(d["rec"]["id"])] = d["rec"]
			_structs_version += 1
		Protocol.OP_REMOVE:
			if _structs.erase(int(d["id"])):
				_structs_version += 1
		Protocol.OP_CHUNK:
			if _structs.has(int(d["id"])):
				_structs[int(d["id"])]["chunks"] = int(d["mask"])
				_structs_version += 1

func structures() -> Dictionary:
	return _structs

## Monotonic counter incremented on every structure add/remove/damage/collapse. The renderer
## caches the last value it synced and skips the full pool walk while this is unchanged (the
## steady state — structures are static, so per-frame re-posing of every piece was pure waste).
func structs_version() -> int:
	return _structs_version

## M11: a building fully collapsed server-side — drop all its piece records (renderer swaps rubble).
func apply_collapse(building_id: int) -> void:
	if building_id == 0:
		return  # sentinel / loose pieces are never a valid collapse target
	var drop: Array = []
	for id in _structs:
		if int(_structs[id].get("building_id", 0)) == building_id:
			drop.append(id)
	for id in drop:
		_structs.erase(id)
	if not drop.is_empty():
		_structs_version += 1
	_collapsed_buildings.append(building_id)

## Drain + clear the collapse queue (renderer calls this each frame to spawn rubble markers).
func take_collapsed() -> Array:
	var out := _collapsed_buildings.duplicate()
	_collapsed_buildings.clear()
	return out

func set_roster(rows: Array) -> void:
	_roster = rows

func roster() -> Array:
	return _roster
