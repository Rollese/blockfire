class_name Stairs
extends Object
## Pure ramp-height math for walkable bstair pieces. A stair at cell Y rises CELL_SIZE across the cell
## from its low edge (surface Y*CELL_SIZE) to its high edge ((Y+1)*CELL_SIZE), along the run direction
## set by the piece yaw. Side-effect-free; shared by server + client. See docs/specs/walkable-multifloor.md.

## XZ ascent direction for a stair at the given yaw step. (yaw 0 ascends +Z; quarter-turns per 2 steps,
## matching BuildGrid's 8-step yaw and the bstair render orientation.)
static func run_dir(yaw: int) -> Vector2:
	var quarters := (yaw % BuildGrid.YAW_STEPS) / 2
	match quarters:
		0: return Vector2(0, 1)
		1: return Vector2(1, 0)
		2: return Vector2(0, -1)
		_: return Vector2(-1, 0)

## Walkable surface height at world (x,z) on a stair occupying `cell`, facing `yaw`. Linearly ramps
## from the cell base (low edge) to the next cell base (high edge) along run_dir.
static func surface_at(cell: Vector3i, yaw: int, x: float, z: float) -> float:
	var lo := BuildGrid.cell_min(cell)
	var lx := clampf((x - lo.x) / BuildGrid.CELL_SIZE, 0.0, 1.0)
	var lz := clampf((z - lo.z) / BuildGrid.CELL_SIZE, 0.0, 1.0)
	var d := run_dir(yaw)
	var f := d.x * lx + d.y * lz
	if d.x + d.y < 0.0:
		f += 1.0
	return float(cell.y) * BuildGrid.CELL_SIZE + clampf(f, 0.0, 1.0) * BuildGrid.CELL_SIZE
