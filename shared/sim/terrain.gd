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
