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

## The owner's oldest piece id (FIFO front) without removing it, or 0 if none.
func oldest_id(owner: int) -> int:
	var ids: Array = _by_owner.get(owner, [])
	return ids[0] if not ids.is_empty() else 0

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

const MARCH_STEP := 0.5   # ray-march sampling step (m); < CELL_SIZE so no cell is skipped

## Walk a ray through the build grid up to max_dist. Returns {hit:bool, dist:float, id:int}.
## Samples cells along the ray (coarse discovery), then runs an exact height-aware ray-AABB
## test on each occupied cell; returns the nearest blocking hit. Bounded by max_dist/MARCH_STEP.
func march(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var d := dir.normalized()
	var best_t := INF
	var best_id := 0
	var seen := {}
	var t := 0.0
	while t <= max_dist:
		var cell := BuildGrid.cell_of(origin + d * t)
		if not seen.has(cell):
			seen[cell] = true
			var id: int = _occupancy.get(cell, 0)
			if id != 0:
				var hit_t := _ray_piece(origin, d, _by_id[id])
				if hit_t >= 0.0 and hit_t <= max_dist and hit_t < best_t:
					best_t = hit_t
					best_id = id
		t += MARCH_STEP
	if best_id != 0:
		return {"hit": true, "dist": best_t, "id": best_id}
	return {"hit": false, "dist": INF, "id": 0}

func _ray_piece(origin: Vector3, d: Vector3, rec: Dictionary) -> float:
	var mn := BuildGrid.cell_min(rec["cell"])
	var h := BuildGrid.CELL_SIZE * (0.5 if _catalog.is_half(rec["type"]) else 1.0)
	var mx := Vector3(mn.x + BuildGrid.CELL_SIZE, mn.y + h, mn.z + BuildGrid.CELL_SIZE)
	return _ray_aabb(origin, d, mn, mx)

## Slab test. Returns entry distance >= 0 if the ray hits the AABB, else -1.
func _ray_aabb(origin: Vector3, d: Vector3, mn: Vector3, mx: Vector3) -> float:
	var tmin := 0.0
	var tmax := INF
	for a in 3:
		var o: float = origin[a]
		var dir_a: float = d[a]
		if absf(dir_a) < 1.0e-9:
			if o < mn[a] or o > mx[a]:
				return -1.0
		else:
			var inv := 1.0 / dir_a
			var t1 := (mn[a] - o) * inv
			var t2 := (mx[a] - o) * inv
			if t1 > t2:
				var tmp := t1; t1 = t2; t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return -1.0
	if tmax < 0.0:
		return -1.0
	return tmin

## Coarse movement collision: if the destination ground cell is blocked, slide axis-separated;
## if both axes blocked, stay. y is preserved (movement uses the ground cell). All v1 pieces block.
func resolve_movement(from: Vector3, to: Vector3) -> Vector3:
	if not _blocks_ground(to):
		return to
	var try_x := Vector3(to.x, to.y, from.z)
	if not _blocks_ground(try_x):
		return try_x
	var try_z := Vector3(from.x, to.y, to.z)
	if not _blocks_ground(try_z):
		return try_z
	return Vector3(from.x, to.y, from.z)

func _blocks_ground(p: Vector3) -> bool:
	return _occupancy.has(BuildGrid.cell_of(Vector3(p.x, 0.0, p.z)))
