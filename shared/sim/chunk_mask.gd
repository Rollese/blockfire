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

## Face WIDTH axis, matching the renderer's _structure_xform (Godot Basis.from_euler Y-rotation of local
## +X = (cos a, 0, -sin a)). The sim USED (cos a, 0, +sin a) — opposite Z — so a chunk the sim carved
## rendered MIRRORED on E/W-facing walls (yaw 2/6, sin != 0); N/S walls (sin ~ 0) happened to match.
static func _u_axis(yaw: int) -> Vector3:
	var a := BuildGrid.yaw_radians(yaw)
	return Vector3(cos(a), 0.0, -sin(a))

## World XZ centre of the piece's cell (the face's origin along U is the CELL CENTRE, so the face spans
## -half..+half along U and stays inside the cell for ANY yaw — the old cmin origin put the face outside
## the cell when u pointed in a negative world direction, yaw 4/6).
static func _cell_centre_xz(cell: Vector3i) -> Vector3:
	var half := BuildGrid.CELL_SIZE * 0.5
	return BuildGrid.cell_min(cell) + Vector3(half, 0.0, half)

## World-space centre of chunk (row,col) on the piece at `cell`, oriented by `yaw`, face `height`.
static func chunk_center(cell: Vector3i, yaw: int, row: int, col: int, grid: int, height: float) -> Vector3:
	var half := BuildGrid.CELL_SIZE * 0.5
	var u := _u_axis(yaw)
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	return _cell_centre_xz(cell) + u * ((float(col) + 0.5) * ustep - half) \
		+ Vector3(0.0, (float(row) + 0.5) * vstep, 0.0)

## Bit index of the chunk at world `point` on the piece face (clamped into the grid).
static func bit_at(cell: Vector3i, yaw: int, grid: int, height: float, point: Vector3) -> int:
	var half := BuildGrid.CELL_SIZE * 0.5
	var uc := (point - _cell_centre_xz(cell)).dot(_u_axis(yaw)) + half   # 0..CELL along the face width
	var col := clampi(int(uc / (BuildGrid.CELL_SIZE / float(grid))), 0, grid - 1)
	var row := clampi(int((point.y - float(BuildGrid.cell_min(cell).y)) / (height / float(grid))), 0, grid - 1)
	return row * grid + col

static func is_alive_at(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, point: Vector3) -> bool:
	return (mask & (1 << bit_at(cell, yaw, grid, height, point))) != 0

## True if EVERY chunk overlapping the pawn's cross-section is cleared — a walk-through gap. The
## cross-section is a box of half-width `half_w` (along U, the face width) centred on world point `p`,
## rising `body_h` from `p`'s height. Bounded scan of just that rectangle of chunks (at most a few of
## the grid*grid), evaluated only when a pawn is already pressed against an occupied wall cell, so it
## adds no systematic tick cost. M11 Gate-B walk-through.
static func region_clear(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, p: Vector3, half_w: float, body_h: float) -> bool:
	var half := BuildGrid.CELL_SIZE * 0.5
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	var uc := (p - _cell_centre_xz(cell)).dot(_u_axis(yaw)) + half   # pawn centre along the face width (0..CELL)
	var rely := p.y - float(BuildGrid.cell_min(cell).y)
	var cmin := clampi(int((uc - half_w) / ustep), 0, grid - 1)
	var cmax := clampi(int((uc + half_w) / ustep), 0, grid - 1)
	var rmin := clampi(int(rely / vstep), 0, grid - 1)
	var rmax := clampi(int((rely + body_h) / vstep), 0, grid - 1)
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

## A blast is ignored on a piece whose face plane is farther than this (m) from the impact along the
## piece normal — so a blast carves the wall it HIT, not the parallel wall(s) behind it. Must exceed a
## contact impact's off-plane distance: a rocket detonates on the cell's AABB face (<=1 m off the wall
## centre) and a chunk_center impact is <= half*sqrt(2) ~ 1.41 m off, so 1.5 clears both while still
## rejecting a wall a full cell (2 m) behind.
const DEPTH_TOLERANCE := 1.5

## Clear intact chunks within `radius` of `impact`, measured IN THE FACE PLANE (width x height) — the
## depth/normal component is dropped so a wall carves the same whether the blast hits its +X/+Z or
## -X/-Z side (playtest: only S/W-facing walls destroyed; N/E took many rockets). A depth gate skips
## the piece if the impact is well off its plane (no punch-through to walls behind). Per-chunk radius
## jitter keeps the edge ragged (A1); isolated survivors drop. New mask.
static func clear_in_radius(mask: int, cell: Vector3i, yaw: int, grid: int, height: float, impact: Vector3, radius: float) -> int:
	var m := mask
	var cmin := BuildGrid.cell_min(cell)
	var half := BuildGrid.CELL_SIZE * 0.5
	var u := _u_axis(yaw)                           # face width axis (matches the renderer)
	var n := Vector3(-u.z, 0.0, u.x)               # face normal (horizontal, perpendicular to u)
	var centre := cmin + Vector3(half, half, half)
	if absf((impact - centre).dot(n)) > DEPTH_TOLERANCE:
		return m                                    # impact off this wall's plane -> don't carve it
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	var iu := (impact - _cell_centre_xz(cell)).dot(u)   # impact along the face width, from the centre (-half..+half)
	var iv := impact.y - float(cmin.y)                  # ... and up from the cell base (0..height)
	for row in grid:
		for col in grid:
			var bit := row * grid + col
			if (m & (1 << bit)) == 0:
				continue
			var du := ((float(col) + 0.5) * ustep - half) - iu
			var dv := (float(row) + 0.5) * vstep - iv
			var dist := sqrt(du * du + dv * dv)     # in-face distance (depth dropped)
			var edge := radius + _chunk_noise(cell, row, col) * clampf(dist / maxf(radius, 0.01), 0.0, 1.0)
			if dist <= edge:
				m &= ~(1 << bit)
	return _drop_isolated(m, grid)

## Drop any chunk left with NO surviving orthogonal (face) neighbour — a single brick can't hang alone
## in a hole (playtest: "isolated empty bricks in a wall"). One simultaneous pass over the pre-drop mask
## so it's order-independent; only fully-orphaned single chunks fall (connected remnants stay).
static func _drop_isolated(mask: int, grid: int) -> int:
	var m := mask
	for row in grid:
		for col in grid:
			var bit := row * grid + col
			if (mask & (1 << bit)) == 0:
				continue
			var neighbours := 0
			if row > 0 and (mask & (1 << (bit - grid))) != 0: neighbours += 1
			if row < grid - 1 and (mask & (1 << (bit + grid))) != 0: neighbours += 1
			if col > 0 and (mask & (1 << (bit - 1))) != 0: neighbours += 1
			if col < grid - 1 and (mask & (1 << (bit + 1))) != 0: neighbours += 1
			if neighbours == 0:
				m &= ~(1 << bit)
	return m
