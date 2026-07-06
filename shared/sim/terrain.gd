class_name Terrain
extends RefCounted
## Stateless heightmap-terrain queries over a TerrainGrid handle. Pure, like structure.gd/stairs.gd
## — the grid IS the state. A null grid = flat map (height 0). O(1) bilinear sampling: safe in the
## movement hot path. See docs/specs/heightmap-terrain.md.

## Slope beyond this (degrees) is unwalkable/undriveable. ~50° per BattleBit/typical-FPS feel;
## tune against the demo map's cliff during the gate.
const MAX_WALKABLE_SLOPE_DEG := 50.0

## Bilinearly-interpolated terrain height at world (x,z). null grid or inside a cutout handled first.
static func height_at(grid: TerrainGrid, x: float, z: float) -> float:
	if grid == null:
		return 0.0
	var cf := grid.cutout_floor(x, z)
	if not is_nan(cf):
		return cf
	var gx := (x - grid.origin_x) / grid.spacing
	var gz := (z - grid.origin_z) / grid.spacing
	var x0 := clampi(int(floor(gx)), 0, grid.cols - 1)
	var z0 := clampi(int(floor(gz)), 0, grid.rows - 1)
	var x1 := mini(x0 + 1, grid.cols - 1)
	var z1 := mini(z0 + 1, grid.rows - 1)
	var fx := clampf(gx - float(x0), 0.0, 1.0)
	var fz := clampf(gz - float(z0), 0.0, 1.0)
	var h00 := grid.sample(x0, z0)
	var h10 := grid.sample(x1, z0)
	var h01 := grid.sample(x0, z1)
	var h11 := grid.sample(x1, z1)
	var h0 := lerpf(h00, h10, fx)
	var h1 := lerpf(h01, h11, fx)
	return lerpf(h0, h1, fz)

## Local slope angle (degrees) via a central-difference gradient of height_at. Continuous
## everywhere (not a per-cell facet). The primitive a future nav milestone consumes as its
## walkability/steepness test.
static func slope_at(grid: TerrainGrid, x: float, z: float) -> float:
	if grid == null:
		return 0.0
	var e := grid.spacing   # cell-scale central difference
	var dhx := (height_at(grid, x + e, z) - height_at(grid, x - e, z)) / (2.0 * e)
	var dhz := (height_at(grid, x, z + e) - height_at(grid, x, z - e)) / (2.0 * e)
	var grad := sqrt(dhx * dhx + dhz * dhz)
	return rad_to_deg(atan(grad))

## Horizontal blocker mirroring structure.gd::resolve_movement: if the destination column is too
## steep, try axis-separated slides so the mover slides along the slope face instead of advancing
## into it; if both blocked, stay. y is preserved (caller re-clamps y via _apply_platform_floor).
## One function covers walking, jumping (horizontal advance still runs through here), and vehicles.
static func resolve_movement(grid: TerrainGrid, from: Vector3, to: Vector3) -> Vector3:
	if grid == null:
		return to
	if slope_at(grid, to.x, to.z) <= MAX_WALKABLE_SLOPE_DEG:
		return to
	var try_x := Vector3(to.x, to.y, from.z)
	if slope_at(grid, try_x.x, try_x.z) <= MAX_WALKABLE_SLOPE_DEG:
		return try_x
	var try_z := Vector3(from.x, to.y, to.z)
	if slope_at(grid, try_z.x, try_z.z) <= MAX_WALKABLE_SLOPE_DEG:
		return try_z
	return Vector3(from.x, to.y, from.z)
