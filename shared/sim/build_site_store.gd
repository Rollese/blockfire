class_name BuildSiteStore
extends Object
## Holds active build sites (M12-P2). Sites are under-construction fortifications with NO collision
## or cover — keeping them out of StructureStore means none of the M11 collision queries
## (march/resolve_movement/floor_height_at/...) accidentally treat a ghost site as solid. On completion
## the server removes the site here and calls StructureStore.place to create the real piece.
## Indexing mirrors StructureStore (occupancy by cell + region buckets) so placement can validate
## against both stores and sites stream by interest region.

const REGION_CELL := 64.0   # must match StructureStore.REGION_CELL / InterestGrid

var _by_id: Dictionary = {}        # id -> site record
var _occupancy: Dictionary = {}    # Vector3i cell -> id
var _by_owner: Dictionary = {}     # owner -> Array[int] ids (FIFO)
var _by_region: Dictionary = {}    # Vector2i region -> {id: true}

func count() -> int:
	return _by_id.size()

func get_site(id: int) -> Dictionary:
	return _by_id.get(id, {})

func occupied(cell: Vector3i) -> bool:
	return _occupancy.has(cell)

func owner_count(owner: int) -> int:
	return (_by_owner.get(owner, []) as Array).size()

func region_of(cell: Vector3i) -> Vector2i:
	return Vector2i(int(floor(float(cell.x) * BuildGrid.CELL_SIZE / REGION_CELL)),
		int(floor(float(cell.z) * BuildGrid.CELL_SIZE / REGION_CELL)))

func ids() -> Array:
	return _by_id.keys()

func add(rec: Dictionary) -> void:
	var id := int(rec["id"])
	_by_id[id] = rec
	_occupancy[rec["cell"]] = id
	var owner := int(rec["owner"])
	if not _by_owner.has(owner):
		_by_owner[owner] = []
	(_by_owner[owner] as Array).append(id)
	var region := region_of(rec["cell"])
	if not _by_region.has(region):
		_by_region[region] = {}
	_by_region[region][id] = true

func remove(id: int) -> void:
	if not _by_id.has(id):
		return
	var rec: Dictionary = _by_id[id]
	_occupancy.erase(rec["cell"])
	var owner := int(rec["owner"])
	if _by_owner.has(owner):
		(_by_owner[owner] as Array).erase(id)
	var region := region_of(rec["cell"])
	if _by_region.has(region):
		(_by_region[region] as Dictionary).erase(id)
		if (_by_region[region] as Dictionary).is_empty():
			_by_region.erase(region)
	_by_id.erase(id)

func oldest_id(owner: int) -> int:
	var arr: Array = _by_owner.get(owner, [])
	return int(arr[0]) if not arr.is_empty() else 0

func records_in_region(region: Vector2i) -> Array:
	var out: Array = []
	for id in _by_region.get(region, {}):
		out.append(_by_id[id])
	return out
