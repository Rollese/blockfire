class_name Support
extends Object
## Pure support-graph reasoning over a StructureStore building. A building's foundation is its
## structural pieces at cell.y == 0; any structural piece not reachable from the foundation by
## face-adjacency (same building_id) is orphaned. See docs/specs/destructible-buildings.md §C.

## Orphan-set size above which we collapse the whole building rather than streaming per-piece removes.
const COLLAPSE_THRESHOLD := 8

static func should_collapse(orphan_count: int) -> bool:
	return orphan_count > COLLAPSE_THRESHOLD

## Structural piece ids of `building_id` whose cell.y == 0.
static func foundation_ids(store: StructureStore, building_id: int) -> Array:
	var out: Array = []
	for id in store.ids_of_building(building_id):
		var rec := store.get_record(id)
		if rec.is_empty():
			continue
		if int((rec["cell"] as Vector3i).y) == 0:
			out.append(id)
	return out

## Ids of `building_id`'s pieces that are no longer connected to a foundation after `removed_ids`
## are gone. `removed_ids` is informational (the store should already reflect the removals).
static func orphaned_after(store: StructureStore, building_id: int, _removed_ids: Array) -> Array:
	var members := store.ids_of_building(building_id)
	if members.is_empty():
		return []
	# Build cell -> id for this building's live pieces.
	var cell_to_id := {}
	for id in members:
		var rec := store.get_record(id)
		if not rec.is_empty():
			cell_to_id[rec["cell"]] = id
	# BFS from every foundation cell over 6-neighbour adjacency within this building.
	var reached := {}
	var frontier: Array = []
	for fid in foundation_ids(store, building_id):
		var frec := store.get_record(fid)
		if not frec.is_empty():
			frontier.append(frec["cell"])
			reached[frec["cell"]] = true
	var dirs := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0), Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	while not frontier.is_empty():
		var c: Vector3i = frontier.pop_back()
		for d in dirs:
			var n: Vector3i = c + d
			if cell_to_id.has(n) and not reached.has(n):
				reached[n] = true
				frontier.append(n)
	# Any live member cell not reached is orphaned.
	var orphans: Array = []
	for c in cell_to_id:
		if not reached.has(c):
			orphans.append(cell_to_id[c])
	return orphans
