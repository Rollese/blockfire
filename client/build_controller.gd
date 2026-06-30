class_name BuildController
extends RefCounted
## M12 client build-placement: the pure build-tool state machine + aim/placement geometry. Holds
## build-mode state (active / selected piece / ghost yaw) and the decision logic the renderer + wire
## need. No Input, no nodes, no rendering — unit-testable. The server re-validates everything; the
## optimistic helpers here only colour the placement ghost and pick PLACE vs SHOVEL.

const NONE := 0
const PLACE := 1
const SHOVEL := 2

const BUILD_REACH := 7.0   # m: max distance ahead the ghost can be placed/snapped

# Buildable fortifications a player can cycle (by catalog id, in cycle order). The FOB is appended
# only for squad leaders (leader-only on the server too).
const FORT_NAMES := ["sandbag", "wall", "heavy_barricade"]

var active := false
var yaw := 0                 # 0..BuildGrid.YAW_STEPS-1
var _index := 0              # position in the (leader-dependent) cycle
var _fort_types: Array[int] = []
var _fob_type := -1

func _init(catalog: PieceCatalog) -> void:
	for n in FORT_NAMES:
		var t := catalog.index_of(n)
		if t >= 0:
			_fort_types.append(t)
	_fob_type = catalog.index_of("fob")

func set_active(on: bool) -> void:
	active = on

func toggle() -> void:
	active = not active

## The piece types the player can cycle right now: fortifications, plus the FOB for a squad leader.
func _cycle(is_leader: bool) -> Array:
	var out: Array = _fort_types.duplicate()
	if is_leader and _fob_type >= 0:
		out.append(_fob_type)
	return out

func cycle(dir: int, is_leader: bool) -> void:
	var n := _cycle(is_leader).size()
	if n > 0:
		_index = wrapi(_index + dir, 0, n)

func rotate() -> void:
	yaw = (yaw + 1) % BuildGrid.YAW_STEPS

func current_type(is_leader: bool) -> int:
	var c := _cycle(is_leader)
	if c.is_empty():
		return -1
	return int(c[_index % c.size()])

func current_is_fob(is_leader: bool) -> bool:
	return is_leader and _fob_type >= 0 and current_type(is_leader) == _fob_type

## Project the aim ray onto the ground plane (y==0) and snap to a build cell. If the ray points down,
## the cell is the ground hit (clamped to BUILD_REACH); otherwise it is BUILD_REACH ahead, on the
## ground layer. Pure — eye + forward are supplied by the caller.
func aimed_cell(eye: Vector3, fwd: Vector3) -> Vector3i:
	var p: Vector3
	if fwd.y < -0.01 and eye.y > 0.0:
		var t: float = minf(-eye.y / fwd.y, BUILD_REACH)
		p = eye + fwd * t
	else:
		p = eye + fwd * BUILD_REACH
	p.y = 0.0
	return BuildGrid.cell_of(p)

## Optimistic client-side validity for the green/red ghost: in bounds + the ground layer + the cell is
## not already occupied by any known structure or site. Server is authoritative.
func placement_valid(cell: Vector3i, structures: Dictionary) -> bool:
	if cell.y != 0:
		return false
	if not BuildGrid.in_bounds(cell, Pawn.WORLD_HALF):
		return false
	return not _occupied(cell, structures)

## PLACE on a valid empty cell, SHOVEL when aiming at a known under-construction site, else NONE.
func action_at(cell: Vector3i, structures: Dictionary) -> int:
	if _site_id_at(cell, structures) != 0:
		return SHOVEL
	if placement_valid(cell, structures):
		return PLACE
	return NONE

## Struct id of an under-construction site occupying `cell`, or 0.
func _site_id_at(cell: Vector3i, structures: Dictionary) -> int:
	for id_v: Variant in structures:
		var rec: Dictionary = structures[id_v]
		if (rec["cell"] as Vector3i) == cell and int(rec.get("under_construction", 0)) == 1:
			return int(id_v)
	return 0

func _occupied(cell: Vector3i, structures: Dictionary) -> bool:
	for id_v: Variant in structures:
		if ((structures[id_v] as Dictionary)["cell"] as Vector3i) == cell:
			return true
	return false
