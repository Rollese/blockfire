class_name ChunkMask
extends Object
## Pure 64-bit sub-cell alive-mask helpers (M11). A piece face is an NxN grid (N=grid, max 8 ->
## 64 chunks fit one 64-bit int). Bit (row*grid+col) set = chunk intact; bit 0 = U/V-min corner.
## U = horizontal axis rotated by yaw (face width); V = world-up scaled to the face `height`
## (full piece = CELL_SIZE, half piece = CELL_SIZE*0.5). Masks are bit patterns (full 8x8 == -1).
## See docs/specs/destructible-buildings.md §A.
## Callers guarantee grid in 1..MAX_GRID (chunk math divides by grid).

const MAX_GRID := 8

static func count(grid: int) -> int:
	return grid * grid

static func full_mask(grid: int) -> int:
	var n := grid * grid
	if n >= 64:
		return ~0            # all 64 bits set (== -1 signed); bit pattern is what matters
	return (1 << n) - 1

static func popcount(mask: int) -> int:
	var c := 0
	for i in 64:
		if (mask & (1 << i)) != 0:
			c += 1
	return c

static func is_empty(mask: int) -> bool:
	return mask == 0

static func _u_axis(yaw: int) -> Vector3:
	var a := BuildGrid.yaw_radians(yaw)
	return Vector3(cos(a), 0.0, sin(a))

## World-space centre of chunk (row,col) on the piece at `cell`, oriented by `yaw`, face `height`.
static func chunk_center(cell: Vector3i, yaw: int, row: int, col: int, grid: int, height: float) -> Vector3:
	var origin := BuildGrid.cell_min(cell)
	var u := _u_axis(yaw)
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	return origin + u * ((float(col) + 0.5) * ustep) + Vector3(0.0, (float(row) + 0.5) * vstep, 0.0)

## Bit index of the chunk at world `point` on the piece face (clamped into the grid).
static func bit_at(cell: Vector3i, yaw: int, grid: int, height: float, point: Vector3) -> int:
	var rel := point - BuildGrid.cell_min(cell)
	var u := _u_axis(yaw)
	var col := clampi(int(rel.dot(u) / (BuildGrid.CELL_SIZE / float(grid))), 0, grid - 1)
	var row := clampi(int(rel.y / (height / float(grid))), 0, grid - 1)
	return row * grid + col

static func is_alive_at(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, point: Vector3) -> bool:
	return (mask & (1 << bit_at(cell, yaw, grid, height, point))) != 0

## Clear every intact chunk whose centre is within `radius` (world) of `impact`. New mask.
static func clear_in_radius(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, impact: Vector3, radius: float) -> int:
	var m := mask
	for row in grid:
		for col in grid:
			var bit := row * grid + col
			if (m & (1 << bit)) == 0:
				continue
			if chunk_center(cell, yaw, row, col, grid, height).distance_to(impact) <= radius:
				m &= ~(1 << bit)
	return m
