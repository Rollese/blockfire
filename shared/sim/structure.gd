class_name StructureStore
extends RefCounted
## Authoritative store of placed fortification pieces. id -> record, plus an occupancy index
## (cell -> id; this IS the spatial index, never rebuilt per tick), a per-owner FIFO (for cap
## recycle), and a region index keyed to InterestGrid cells (for replication baselines). All
## placement rules live here so server authority and future client prediction can't diverge.
## Pieces are static and (Phase 1) indestructible. See docs/specs/building.md.
##
## A record is: {id:int, type:int, cell:Vector3i, yaw:int, health:int, owner:int}

const MAX_PIECES_PER_PLAYER := 12
const BUILD_COOLDOWN_TICKS := 150   # 5s @30Hz
const BUILD_RANGE := 5.0            # max placement distance from the player (m)
const REGION_CELL := 64.0           # must match server InterestGrid CELL_SIZE

var _catalog: PieceCatalog
var _by_id: Dictionary = {}         # id -> record
var _occupancy: Dictionary = {}     # Vector3i cell -> id
var _by_owner: Dictionary = {}      # owner -> Array[int] ids, oldest first
var _by_region: Dictionary = {}     # Vector2i region -> Dictionary[id->true]

func _init(catalog: PieceCatalog) -> void:
	_catalog = catalog

func count() -> int:
	return _by_id.size()

func occupied(cell: Vector3i) -> bool:
	return _occupancy.has(cell)

func owner_count(owner: int) -> int:
	return _by_owner.get(owner, []).size()

func get_record(id: int) -> Dictionary:
	return _by_id.get(id, {})

func region_of(cell: Vector3i) -> Vector2i:
	var w := BuildGrid.world_of(cell)
	return Vector2i(floori(w.x / REGION_CELL), floori(w.z / REGION_CELL))

func records_in_region(region: Vector2i) -> Array:
	var out: Array = []
	for id in _by_region.get(region, {}):
		out.append(_by_id[id])
	return out

## Insert a record. Returns the record on success, {} if the cell is occupied.
func place(id: int, type: int, cell: Vector3i, yaw: int, owner: int) -> Dictionary:
	if _occupancy.has(cell):
		return {}
	var rec := {"id": id, "type": type, "cell": cell, "yaw": yaw,
		"health": _catalog.health_of(type), "owner": owner}
	return insert(rec)

## Insert a fully-formed record (used by clients applying deltas/baselines).
func insert(rec: Dictionary) -> Dictionary:
	var cell: Vector3i = rec["cell"]
	if _occupancy.has(cell):
		return {}
	var id: int = rec["id"]
	var owner: int = rec["owner"]
	_by_id[id] = rec
	_occupancy[cell] = id
	if not _by_owner.has(owner):
		_by_owner[owner] = []
	_by_owner[owner].append(id)
	var region := region_of(cell)
	if not _by_region.has(region):
		_by_region[region] = {}
	_by_region[region][id] = true
	return rec

func remove(id: int) -> void:
	if not _by_id.has(id):
		return
	var rec: Dictionary = _by_id[id]
	_occupancy.erase(rec["cell"])
	var owner: int = rec["owner"]
	if _by_owner.has(owner):
		_by_owner[owner].erase(id)
	var region := region_of(rec["cell"])
	if _by_region.has(region):
		_by_region[region].erase(id)
	_by_id.erase(id)

## Remove the owner's oldest piece. Returns the removed id, or 0 if none.
func recycle_oldest(owner: int) -> int:
	var ids: Array = _by_owner.get(owner, [])
	if ids.is_empty():
		return 0
	var id: int = ids[0]
	remove(id)
	return id

## Validate a placement request. Returns {ok:bool, reason:String}. Cap is NOT checked here
## (the server recycles the oldest piece at the cap); this covers cooldown/bounds/self-cell/
## range/occupancy/support. Pure over store state + params, so it is unit-testable.
func validate_place(cell: Vector3i, player_pos: Vector3, now_tick: int, last_build_tick: int, world_half: float) -> Dictionary:
	if now_tick - last_build_tick < BUILD_COOLDOWN_TICKS:
		return {"ok": false, "reason": "cooldown"}
	if not BuildGrid.in_bounds(cell, world_half):
		return {"ok": false, "reason": "bounds"}
	if cell == BuildGrid.cell_of(Vector3(player_pos.x, 0.0, player_pos.z)):
		return {"ok": false, "reason": "self_cell"}
	var c := BuildGrid.world_of(cell)
	if Vector2(c.x - player_pos.x, c.z - player_pos.z).length() > BUILD_RANGE:
		return {"ok": false, "reason": "range"}
	if _occupancy.has(cell):
		return {"ok": false, "reason": "occupied"}
	if cell.y > 0 and not _occupancy.has(Vector3i(cell.x, cell.y - 1, cell.z)):
		return {"ok": false, "reason": "support"}
	return {"ok": true, "reason": ""}
