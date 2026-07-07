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

## True if EVERY chunk overlapping the pawn's cross-section is cleared — a walk-through gap. The
## cross-section is a box of half-width `half_w` (along U, the face width) centred on world point `p`,
## rising `body_h` from `p`'s height. Bounded scan of just that rectangle of chunks (at most a few of
## the grid*grid), evaluated only when a pawn is already pressed against an occupied wall cell, so it
## adds no systematic tick cost. M11 Gate-B walk-through.
static func region_clear(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, p: Vector3, half_w: float, body_h: float) -> bool:
	var origin := BuildGrid.cell_min(cell)
	var u := _u_axis(yaw)
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	var rel := p - origin
	var uc := rel.dot(u)                       # pawn centre along the face width (m from the U-min edge)
	var cmin := clampi(int((uc - half_w) / ustep), 0, grid - 1)
	var cmax := clampi(int((uc + half_w) / ustep), 0, grid - 1)
	var rmin := clampi(int(rel.y / vstep), 0, grid - 1)
	var rmax := clampi(int((rel.y + body_h) / vstep), 0, grid - 1)
	for row in range(rmin, rmax + 1):
		for col in range(cmin, cmax + 1):
			if (mask & (1 << (row * grid + col))) != 0:
				return false   # a chunk still solid somewhere in the pawn's path -> not walk-through
	return true

## Height (m up the face) of the TOP surviving chunk row — the effective top of a carved wall. A wall
## shot down from the top has a lower top than its full face, so it becomes vault/step-able (playtest
## R4). Full mask -> full `height` (pristine walls are unchanged). Empty -> 0.
static func top_alive_height(mask: int, grid: int, height: float) -> float:
	var vstep := height / float(grid)
	for row in range(grid - 1, -1, -1):
		for col in grid:
			if (mask & (1 << (row * grid + col))) != 0:
				return float(row + 1) * vstep
	return 0.0

## Ragged-edge amplitude (m): per-chunk jitter on the carve radius so holes aren't perfect circles.
const CARVE_NOISE := 0.22

## Deterministic per-chunk noise in [-CARVE_NOISE, +CARVE_NOISE] — a pure hash of the world cell + chunk
## index (NO RNG, so server/client/bots agree and the hole edge never shimmers between carves).
static func _chunk_noise(cell: Vector3i, row: int, col: int) -> float:
	var n: int = (cell.x * 73856093) ^ (cell.y * 19349663) ^ (cell.z * 83492791) ^ (row * 26699) ^ (col * 40503)
	var f := float(n & 0xFFFF) / 65536.0        # [0,1)
	return (f - 0.5) * 2.0 * CARVE_NOISE

## Clear every intact chunk whose centre is within `radius` (world) of `impact`, with a deterministic
## per-chunk radius jitter so the boundary is ragged (irregular holes, not clean circles — playtest A1).
## New mask.
static func clear_in_radius(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, impact: Vector3, radius: float) -> int:
	var m := mask
	var origin := BuildGrid.cell_min(cell)
	var u := _u_axis(yaw)
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	for row in grid:
		for col in grid:
			var bit := row * grid + col
			if (m & (1 << bit)) == 0:
				continue
			var center := origin + u * ((float(col) + 0.5) * ustep) + Vector3(0.0, (float(row) + 0.5) * vstep, 0.0)
			var dist := center.distance_to(impact)
			# Jitter scales with distance: ~0 at the centre (the hit chunk always dies) and full at the
			# rim, so the boundary is ragged but the core of the hole is solid.
			var edge := radius + _chunk_noise(cell, row, col) * clampf(dist / maxf(radius, 0.01), 0.0, 1.0)
			if dist <= edge:
				m &= ~(1 << bit)
	return m
