class_name BuildController
extends RefCounted
## M12 client build-placement: the pure build-tool state machine + aim/placement geometry. Holds
## build-mode state (active / selected piece / ghost yaw) and the decision logic the renderer + wire
## need. No Input, no nodes, no rendering — unit-testable. The server re-validates everything; the
## optimistic helpers here only colour the placement ghost and pick PLACE vs SHOVEL.

const NONE := 0
const PLACE := 1
const SHOVEL := 2

# Match the server's authoritative placement range (StructureStore.BUILD_RANGE) so the green ghost
# only appears where a BUILD_REQUEST will actually be accepted.
const BUILD_REACH := StructureStore.BUILD_RANGE

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

## Length of the piece cycle right now: fortifications, plus the FOB for a squad leader. (No array
## allocation — current_type/cycle call this every frame.)
func _cycle_len(is_leader: bool) -> int:
	return _fort_types.size() + (1 if is_leader and _fob_type >= 0 else 0)

func cycle(dir: int, is_leader: bool) -> void:
	var n := _cycle_len(is_leader)
	if n > 0:
		_index = wrapi(_index + dir, 0, n)

func rotate() -> void:
	yaw = (yaw + 1) % BuildGrid.YAW_STEPS

func current_type(is_leader: bool) -> int:
	var n := _cycle_len(is_leader)
	if n == 0:
		return -1
	var i := _index % n
	return _fob_type if i == _fort_types.size() else int(_fort_types[i])

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
		# Looking level/up: project the HORIZONTAL aim out to reach so the cell is ahead of the player,
		# never snapped onto their own feet (which would let you build on yourself looking level/up).
		var h := Vector2(fwd.x, fwd.z)
		if h.length() < 0.001:
			h = Vector2(0.0, 1.0)   # degenerate (straight up/down): arbitrary forward
		h = h.normalized() * BUILD_REACH
		p = Vector3(eye.x + h.x, 0.0, eye.z + h.y)
	p.y = 0.0
	return BuildGrid.cell_of(p)

## Optimistic client-side validity for the green/red ghost: in bounds + the ground layer + within the
## server's placement range of the player + the cell is not already occupied. Server is authoritative.
## `eye` is the player's eye (its X/Z match the feet the server measures from); pass Vector3.INF to
## skip the range check.
func placement_valid(cell: Vector3i, structures: Dictionary, eye: Vector3 = Vector3.INF) -> bool:
	return _geom_ok(cell, eye) and not _occupied(cell, structures)

## PLACE on a valid empty cell, SHOVEL when aiming at a known under-construction site, else NONE.
## Single pass over the structure set (called per tick AND per frame while build mode is active).
func action_at(cell: Vector3i, structures: Dictionary, eye: Vector3 = Vector3.INF) -> int:
	var occupied := false
	for id_v: Variant in structures:
		var rec: Dictionary = structures[id_v]
		if (rec["cell"] as Vector3i) == cell:
			if int(rec.get("under_construction", 0)) == 1:
				return SHOVEL   # an under-construction site here -> shovel it
			occupied = true     # a completed piece blocks placement
	if not occupied and _geom_ok(cell, eye):
		return PLACE
	return NONE

## Ground-layer + in-bounds + within the server's build range (no structure scan).
func _geom_ok(cell: Vector3i, eye: Vector3) -> bool:
	if cell.y != 0:
		return false
	if not BuildGrid.in_bounds(cell, Pawn.WORLD_HALF):
		return false
	if eye.is_finite():
		var c := BuildGrid.world_of(cell)
		if Vector2(c.x - eye.x, c.z - eye.z).length() > StructureStore.BUILD_RANGE:
			return false
	return true

func _occupied(cell: Vector3i, structures: Dictionary) -> bool:
	for id_v: Variant in structures:
		if ((structures[id_v] as Dictionary)["cell"] as Vector3i) == cell:
			return true
	return false
