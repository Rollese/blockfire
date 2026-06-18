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
		if not store.is_structural(id):
			continue
		if (rec["cell"] as Vector3i).y == 0:
			out.append(id)
	return out

## Ids of `building_id`'s pieces that are no longer connected to a foundation after `removed_ids`
## are gone. `_removed_ids` is reserved for a future incremental flood-fill; the store already
## reflects removals.
## Non-structural pieces (props, railings) never propagate support through the BFS — they are
## orphaned if no face-neighbour structural cell was reached.
static func orphaned_after(store: StructureStore, building_id: int, _removed_ids: Array) -> Array:
	var members := store.ids_of_building(building_id)
	if members.is_empty():
		return []
	# Split members into structural cell->id and non-structural cell->id maps.
	var structural_cell_to_id := {}
	var nonstructural_cell_to_id := {}
	for id in members:
		var rec := store.get_record(id)
		if rec.is_empty():
			continue
		if store.is_structural(id):
			structural_cell_to_id[rec["cell"]] = id
		else:
			nonstructural_cell_to_id[rec["cell"]] = id
	# BFS from every structural foundation cell over structural cells only.
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
			if structural_cell_to_id.has(n) and not reached.has(n):
				reached[n] = true
				frontier.append(n)
	# Structural orphans: cells not reached by the BFS.
	var orphans: Array = []
	for c in structural_cell_to_id:
		if not reached.has(c):
			orphans.append(structural_cell_to_id[c])
	# Non-structural orphans: no face-neighbour is a reached structural cell.
	for c in nonstructural_cell_to_id:
		var has_support := false
		for d in dirs:
			if reached.has(c + d):
				has_support = true
				break
		if not has_support:
			orphans.append(nonstructural_cell_to_id[c])
	return orphans
