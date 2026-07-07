class_name BuildGrid
extends Object
## Snap-to-grid quantization for fortification placement. 2.4 m cubic cells, 8 yaw steps.
## Pure functions; the single source of truth for cell<->world math shared by server, bots,
## and the structure store. See docs/specs/building.md.

const CELL_SIZE := 2.4   # global cube (owner-chosen 2026-07-07): a clear standing volume per cell
const YAW_STEPS := 8
const MAX_STACK := 8   # cells high; bounds vertical stacking

## World position -> integer cell (floor-divide on each axis).
static func cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / CELL_SIZE), floori(p.y / CELL_SIZE), floori(p.z / CELL_SIZE))

## Cell -> its XZ centre at the cell's base Y (where a ground piece sits).
static func world_of(cell: Vector3i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL_SIZE, float(cell.y) * CELL_SIZE, (float(cell.z) + 0.5) * CELL_SIZE)

## Cell -> its low corner (min of the AABB).
static func cell_min(cell: Vector3i) -> Vector3:
	return Vector3(float(cell.x) * CELL_SIZE, float(cell.y) * CELL_SIZE, float(cell.z) * CELL_SIZE)

static func in_bounds(cell: Vector3i, world_half: float) -> bool:
	if cell.y < 0 or cell.y >= MAX_STACK:
		return false
	var max_c := int(floor(world_half / CELL_SIZE))
	return abs(cell.x) <= max_c and abs(cell.z) <= max_c

static func yaw_radians(step: int) -> float:
	return (TAU / float(YAW_STEPS)) * float(step % YAW_STEPS)
