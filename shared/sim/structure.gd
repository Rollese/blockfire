class_name StructureStore
extends RefCounted
## Authoritative store of placed fortification pieces. id -> record, plus an occupancy index
## (cell -> id; this IS the spatial index, never rebuilt per tick), a per-owner FIFO (for cap
## recycle), and a region index keyed to InterestGrid cells (for replication baselines). All
## placement rules live here so server authority and future client prediction can't diverge.
## Pieces are placed statically; their chunks are destructible via damage_chunks(). See docs/specs/destructible-buildings.md.
##
## A record is: {id:int, type:int, cell:Vector3i, yaw:int, chunks:int, building_id:int, owner:int}

const MAX_PIECES_PER_PLAYER := 12
const BUILD_COOLDOWN_TICKS := 150   # 5s @30Hz
const BUILD_RANGE := 5.0            # max placement distance from the player (m)
const REGION_CELL := 64.0           # must match server InterestGrid CELL_SIZE


var _catalog: PieceCatalog
var _by_id: Dictionary = {}         # id -> record
var _occupancy: Dictionary = {}     # Vector3i cell -> id
var _by_owner: Dictionary = {}      # owner -> Array[int] ids, oldest first
var _by_region: Dictionary = {}     # Vector2i region -> Dictionary[id->true]
var _by_building: Dictionary = {}   # building_id -> {id: true}
var terrain: TerrainGrid = null     # M15: heightmap occlusion sampled per DDA step in march()

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

func is_structural(id: int) -> bool:
	var rec: Dictionary = _by_id.get(id, {})
	if rec.is_empty():
		return false
	return _catalog.is_structural(int(rec["type"]))

func ids_of_building(building_id: int) -> Array:
	return _by_building.get(building_id, {}).keys()

func region_of(cell: Vector3i) -> Vector2i:
	var w := BuildGrid.world_of(cell)
	return Vector2i(floori(w.x / REGION_CELL), floori(w.z / REGION_CELL))

func records_in_region(region: Vector2i) -> Array:
	var out: Array = []
	for id in _by_region.get(region, {}):
		out.append(_by_id[id])
	return out

## Piece count in a region without materialising the records — for the baseline pacer's per-tick
## budget (avoid building the full record array just to size a region).
func region_count(region: Vector2i) -> int:
	return (_by_region.get(region, {}) as Dictionary).size()

## Insert a record. Returns the record on success, {} if the cell is occupied.
## `team` -1 = neutral/world piece; player fortifications record their builder's team at completion
## so friend/foe shovel classification survives the owner disconnecting (was derived from the live pawn).
func place(id: int, type: int, cell: Vector3i, yaw: int, owner: int, building_id: int = 0, team: int = -1) -> Dictionary:
	if _occupancy.has(cell):
		return {}
	var rec := {"id": id, "type": type, "cell": cell, "yaw": yaw,
		"chunks": ChunkMask.full_mask(_catalog.chunk_grid_of(type)),
		"building_id": building_id, "owner": owner, "team": team}
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
	var bid: int = int(rec.get("building_id", 0))
	if bid != 0:
		if not _by_building.has(bid):
			_by_building[bid] = {}
		_by_building[bid][id] = true
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
	var bid: int = int(rec.get("building_id", 0))
	if bid != 0 and _by_building.has(bid):
		_by_building[bid].erase(id)
	_by_id.erase(id)

## Face vertical extent of a piece: full = CELL_SIZE, half = CELL_SIZE*0.5.
func _face_height(type: int) -> float:
	return BuildGrid.CELL_SIZE * (0.5 if _catalog.is_half(type) else 1.0)

## Clear chunks within `radius` of world `impact` on piece `id`, if the source can damage this
## piece type. Returns {hit, holed, destroyed, mask}; removes the piece when the mask empties.
## Pure over store state + catalog — unit-testable.
## `holed` is true whenever chunks were cleared (currently equals `hit`); reserved for a future line-of-sight/penetration distinction.
func damage_chunks(id: int, source_type: int, impact: Vector3, radius: float) -> Dictionary:
	if not _by_id.has(id):
		return {"hit": false, "holed": false, "destroyed": false, "mask": 0}
	var rec: Dictionary = _by_id[id]
	var type := int(rec["type"])
	var before := int(rec["chunks"])
	if not _catalog.takes_damage(type, source_type):
		return {"hit": false, "holed": false, "destroyed": false, "mask": before}
	var grid := _catalog.chunk_grid_of(type)
	var after := ChunkMask.clear_in_radius(before, rec["cell"], int(rec["yaw"]), grid,
		_face_height(type), impact, radius)
	if after == before:
		return {"hit": false, "holed": false, "destroyed": false, "mask": before}
	if after == 0:
		remove(id)
		return {"hit": true, "holed": true, "destroyed": true, "mask": 0}
	rec["chunks"] = after
	return {"hit": true, "holed": true, "destroyed": false, "mask": after}

## Inverse of damage_chunks: re-sets (heals) chunk bits within `radius` of `impact`, toward the full
## mask. Used by M12-P2 friendly shovel-repair. Returns {changed:bool, mask:int}. No-op if already full.
func repair_chunks(id: int, impact: Vector3, radius: float) -> Dictionary:
	if not _by_id.has(id):
		return {"changed": false, "mask": 0}
	var rec: Dictionary = _by_id[id]
	var type := int(rec["type"])
	var grid := _catalog.chunk_grid_of(type)
	var full := ChunkMask.full_mask(grid)
	var cur := int(rec["chunks"])
	if cur == full:
		return {"changed": false, "mask": cur}
	# clear_in_radius on a FULL mask clears exactly the in-radius chunks; full XOR that = the in-radius
	# bit set. Re-set those bits in the current (damaged) mask to heal the hole.
	var in_radius := full ^ ChunkMask.clear_in_radius(full, rec["cell"], int(rec["yaw"]), grid,
		_face_height(type), impact, radius)
	var healed := cur | in_radius
	if healed == cur:
		return {"changed": false, "mask": cur}
	rec["chunks"] = healed
	return {"changed": true, "mask": healed}

## Ids of occupied pieces whose cell-centre is within `radius_m` of the world point `center`.
## Bounded by the (small) blast cell neighbourhood; used by explosive area damage. Array[int].
func ids_in_radius(center: Vector3, radius_m: float) -> Array:
	var out: Array = []
	var cr := int(ceil(radius_m / BuildGrid.CELL_SIZE))
	var cc := BuildGrid.cell_of(center)
	var half := BuildGrid.CELL_SIZE * 0.5
	for dx in range(-cr, cr + 1):
		for dy in range(-cr, cr + 1):
			for dz in range(-cr, cr + 1):
				var cell := Vector3i(cc.x + dx, cc.y + dy, cc.z + dz)
				if not _occupancy.has(cell):
					continue
				var wc := BuildGrid.cell_min(cell) + Vector3(half, half, half)
				if wc.distance_to(center) <= radius_m:
					out.append(int(_occupancy[cell]))
	return out

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

const FLOOR_REACH_EPS := 0.35   # m; a pawn within this distance below a flat surface "catches" it (small step-up)
const RAMP_REACH_EPS := 0.6     # m; ramps need a larger catch = max per-tick climb at sprint (9.6 m/s * dt on a 1:1 slope ~0.32) + margin

## Walk a ray through the build grid up to max_dist. Returns {hit:bool, dist:float, id:int}.
## Amanatides–Woo 3D DDA: visits EVERY cell the ray crosses, exactly once, in ray order —
## replaces 0.5 m point-sampling, which stepped over corner-clipped cells (through-the-corner
## bullets) and always walked max_dist/0.5 samples with a per-call `seen` dict. Cells arrive
## nearest-first, so the first height-aware AABB hit is the nearest (early exit).
func march(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var d := dir.normalized()
	if d == Vector3.ZERO:
		return {"hit": false, "dist": INF, "id": 0}
	var cell := BuildGrid.cell_of(origin)
	# signf, not signi: signi(int) would truncate 0.707 -> 0 and freeze the walk on diagonals
	var step := Vector3i(int(signf(d.x)), int(signf(d.y)), int(signf(d.z)))
	var t_max := Vector3.INF     # ray distance to the next cell boundary, per axis
	var t_delta := Vector3.INF   # ray distance between successive boundaries, per axis
	for a in 3:
		if step[a] != 0:
			var edge := float(cell[a] + (1 if step[a] > 0 else 0)) * BuildGrid.CELL_SIZE
			t_max[a] = (edge - origin[a]) / d[a]
			t_delta[a] = BuildGrid.CELL_SIZE / absf(d[a])
	var t := 0.0
	while t <= max_dist:
		var id: int = _occupancy.get(cell, 0)
		if id != 0:
			var hit_t := _ray_piece(origin, d, _by_id[id])
			if hit_t >= 0.0 and hit_t <= max_dist:
				return {"hit": true, "dist": hit_t, "id": id}
		# M15 terrain occlusion: if the ray has dropped to/below the terrain surface at this column,
		# the world (hill) blocks it — like striking a piece (id 0 = terrain, not a piece).
		if terrain != null and t > 0.0:
			var pt := origin + d * t
			if pt.y <= Terrain.height_at(terrain, pt.x, pt.z):
				return {"hit": true, "dist": t, "id": 0}
		# advance to the nearest boundary crossing
		var axis := 0
		if t_max.y < t_max.x: axis = 1
		if t_max.z < t_max[axis]: axis = 2
		t = t_max[axis]
		cell[axis] += step[axis]
		t_max[axis] += t_delta[axis]
	return {"hit": false, "dist": INF, "id": 0}

## Like march(), but on a hit also returns the contact `point` and the axis-aligned surface `normal`
## of the struck piece's AABB face — used to bounce grenades off walls. {"hit": false} when nothing
## is struck within max_dist.
func march_normal(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var m := march(origin, dir, max_dist)
	if not bool(m["hit"]):
		return {"hit": false}
	if int(m.get("id", 0)) == 0:
		var d0 := dir.normalized()
		return {"hit": true, "dist": float(m["dist"]), "id": 0,
			"point": origin + d0 * float(m["dist"]), "normal": Vector3(0, 1, 0)}
	var d := dir.normalized()
	var pt: Vector3 = origin + d * float(m["dist"])
	var rec: Dictionary = _by_id[int(m["id"])]
	var mn := BuildGrid.cell_min(rec["cell"])
	var h := _face_height(int(rec["type"]))
	var mx := Vector3(mn.x + BuildGrid.CELL_SIZE, mn.y + h, mn.z + BuildGrid.CELL_SIZE)
	# Normal = the axis whose slab face the contact point sits on (smallest distance to a face plane).
	var n := Vector3.ZERO
	var best := INF
	for a in 3:
		var dlo: float = absf(pt[a] - mn[a])
		if dlo < best:
			best = dlo; n = Vector3.ZERO; n[a] = -1.0
		var dhi: float = absf(pt[a] - mx[a])
		if dhi < best:
			best = dhi; n = Vector3.ZERO; n[a] = 1.0
	return {"hit": true, "dist": float(m["dist"]), "id": int(m["id"]), "point": pt, "normal": n}

func _ray_piece(origin: Vector3, d: Vector3, rec: Dictionary) -> float:
	var mn := BuildGrid.cell_min(rec["cell"])
	var h := _face_height(int(rec["type"]))
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

const FEET_EPS := 0.1   # m; lift the collision sample off the floor plane into the wall's cell band

func _blocks_ground(p: Vector3) -> bool:
	var cell := BuildGrid.cell_of(Vector3(p.x, p.y + FEET_EPS, p.z))
	if not _occupancy.has(cell):
		return false
	# Walk-through pieces: doors (aperture), floors (you stand on them), stairs (you walk up them).
	var t := int(_by_id[_occupancy[cell]]["type"])
	return not (_catalog.passable_of(t) or _catalog.is_flat_surface(t) or _catalog.is_ramp(t))

## True when a pawn can stand at world point `p` (feet cell not blocked at ground level). Used by the
## vault landing scan to reject a landing spot that is inside the low blocker's own cell or a wall.
func stands_clear(p: Vector3) -> bool:
	return not _blocks_ground(p)

## True when the cell at `p` is a solid, non-vaultable blocker — a real wall (face taller than the vault
## clearance), as opposed to a low box/half-wall the pawn vaults over. The vault landing scan stops at
## the first tall blocker so a vault can never carry the pawn through a wall.
func is_tall_blocker(p: Vector3) -> bool:
	var cell := BuildGrid.cell_of(Vector3(p.x, p.y + FEET_EPS, p.z))
	if not _occupancy.has(cell):
		return false
	var t := int(_by_id[_occupancy[cell]]["type"])
	if _catalog.passable_of(t) or _catalog.is_flat_surface(t) or _catalog.is_ramp(t):
		return false
	return _face_height(t) > Vault.VAULT_MAX_HEIGHT

## Highest walkable structure surface at or below `y` at column (x,z); -INF if none. Floors yield
## their cell-base plane; stairs yield a ramped height. Bounded by building height (a handful of cells).
func floor_height_at(x: float, z: float, y: float) -> float:
	var col := BuildGrid.cell_of(Vector3(x, 0.0, z))
	var top := BuildGrid.cell_of(Vector3(x, y + RAMP_REACH_EPS, z)).y
	var best := -INF
	for cy in range(top, -1, -1):
		var cell := Vector3i(col.x, cy, col.z)
		if not _occupancy.has(cell):
			continue
		var rec: Dictionary = _by_id[_occupancy[cell]]
		var t := int(rec["type"])
		var surf: float
		var reach: float
		if _catalog.is_ramp(t):
			surf = Stairs.surface_at(cell, int(rec["yaw"]), x, z)
			reach = RAMP_REACH_EPS
		else:
			# Any solid piece provides a standable surface at its cell base, so a building level is a
			# continuous floor (interior floors + the base of perimeter walls) — no edge fall/oscillation.
			surf = float(cy) * BuildGrid.CELL_SIZE
			reach = FLOOR_REACH_EPS
		if surf <= y + reach and surf > best:
			best = surf
	return best

## Top height (m) of the piece occupying the ground cell at world point `p`, or 0.0 if none.
## Half pieces are 0.5*CELL_SIZE, full pieces CELL_SIZE. Used by the height-generic vault rule.
func ground_blocker_top(p: Vector3) -> float:
	# Height-aware (M14): the blocker the pawn walked into is at their feet cell; return its top
	# RELATIVE to the pawn's feet so the vault check works on any floor (ground stays identical at y=0).
	var cell := BuildGrid.cell_of(Vector3(p.x, p.y + FEET_EPS, p.z))
	if not _occupancy.has(cell):
		return 0.0
	var rec: Dictionary = _by_id[_occupancy[cell]]
	return float(cell.y) * BuildGrid.CELL_SIZE + _face_height(int(rec["type"])) - p.y
