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
# Dirty piece ids since the renderer last drained (incremental MultiMesh rebuild): a delta
# dirties one id; a baseline (or anything bulk) sets `all` so the renderer does a full rebuild.
var _struct_dirty: Dictionary = {}
var _struct_dirty_all := false
var _struct_fx: Array = []   # M11-P4: cosmetic destruction events {cell, yaw, kind:"destroy"|"damage"} drained by renderer
var _roster: Array = []
# Single-entry memo for remotes_at(): the interp clock advances at 30 Hz but callers sample
# up to 4x per render frame with the same `now` — each miss clones the whole remote set.
var _remotes_memo_now: float = -INF
var _remotes_memo: Dictionary = {}

func set_local_id(id: int) -> void:
	_local_id = id

func local_id() -> int:
	return _local_id

func apply_snapshot(bytes: PackedByteArray, now: float) -> Dictionary:
	last_header = Snapshot.decode_apply(bytes, _view, _view_v)
	var remotes := {}
	for id in _view:
		if id != _local_id:
			remotes[id] = (_view[id] as EntityState).clone()
	_interp.push(now, remotes, int(last_header.get("server_tick", 0)))
	_remotes_memo_now = -INF   # new data: same-`now` samples must re-run
	return last_header

## Interpolated remote set at `now`. Memoized per `now` (invalidated on apply_snapshot) —
## callers treat the returned dict + states as READ-ONLY within the frame.
func remotes_at(now: float) -> Dictionary:
	if now == _remotes_memo_now:
		return _remotes_memo
	_remotes_memo = _interp.sample(now)
	_remotes_memo_now = now
	return _remotes_memo

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
	_struct_dirty_all = true
	_structs_version += 1

func apply_structure_delta(bytes: PackedByteArray) -> void:
	var d := Protocol.decode_structure_delta(bytes)
	match int(d["op"]):
		Protocol.OP_PLACE:
			_structs[int(d["rec"]["id"])] = d["rec"]
			_struct_dirty[int(d["rec"]["id"])] = true
			_structs_version += 1
		Protocol.OP_REMOVE:
			var rid := int(d["id"])
			if _structs.has(rid):
				# M11-P4: a piece reaching 0 chunks is a destruction moment — queue a debris/dust burst
				# at its cell before dropping the record (the batched renderer can't infer per-piece removals).
				var rrec: Dictionary = _structs[rid]
				_struct_fx.append({"cell": rrec["cell"], "yaw": int(rrec.get("yaw", 0)), "kind": "destroy"})
				_structs.erase(rid)
				_struct_dirty[rid] = true
				_structs_version += 1
		Protocol.OP_PROGRESS:
			# M12-P2: a build site advanced its shovel progress. The wire carries only id+progress;
			# the renderer derives the fill fraction from build_progress vs its own PieceCatalog cost.
			var pid := int(d["id"])
			if _structs.has(pid):
				var prec: Dictionary = _structs[pid]
				if int(prec.get("build_progress", -1)) != int(d["progress"]):
					prec["build_progress"] = int(d["progress"])
					_struct_dirty[pid] = true
					_structs_version += 1
		Protocol.OP_CHUNK:
			var cid := int(d["id"])
			if _structs.has(cid):
				var crec: Dictionary = _structs[cid]
				var newmask := int(d["mask"])
				# Only react to a real carve — servers resend deltas under the per-tick cap, so an
				# unchanged mask must not re-fire the version bump or a cosmetic dust puff.
				if int(crec.get("chunks", -1)) != newmask:
					crec["chunks"] = newmask
					_struct_fx.append({"cell": crec["cell"], "yaw": int(crec.get("yaw", 0)), "kind": "damage"})
					_struct_dirty[cid] = true
					_structs_version += 1

func structures() -> Dictionary:
	return _structs

## Drain the dirty-piece set for the incremental batch rebuild. {"all": bool, "ids": Array}.
## `all` (baseline / first sync) means group state is unknown -> full rebuild.
func take_struct_dirty() -> Dictionary:
	var out := {"all": _struct_dirty_all, "ids": _struct_dirty.keys()}
	_struct_dirty_all = false
	_struct_dirty = {}
	return out

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
		_struct_dirty[id] = true
	if not drop.is_empty():
		_structs_version += 1
	_collapsed_buildings.append(building_id)

## Drain + clear the collapse queue (renderer calls this each frame to spawn rubble markers).
func take_collapsed() -> Array:
	var out := _collapsed_buildings.duplicate()
	_collapsed_buildings.clear()
	return out

## M11-P4: drain + clear the per-piece destruction-cosmetic queue (renderer spawns debris/dust).
func take_struct_fx() -> Array:
	var out := _struct_fx.duplicate()
	_struct_fx.clear()
	return out

func set_roster(rows: Array) -> void:
	_roster = rows

func roster() -> Array:
	return _roster
