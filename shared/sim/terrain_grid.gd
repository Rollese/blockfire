class_name TerrainGrid
extends RefCounted
## Regular grid of terrain height samples (row-major, z-outer / x-inner). Pure data holder;
## all queries live in the stateless Terrain module. A null TerrainGrid means "flat map"
## (height 0 everywhere) — backward compatible with every pre-M15 map.

var cols: int = 0            # samples along X
var rows: int = 0            # samples along Z
var spacing: float = 2.0     # metres between samples (matches BuildGrid.CELL_SIZE)
var origin_x: float = 0.0    # world X of sample column 0 (== -world_half)
var origin_z: float = 0.0    # world Z of sample row 0    (== -world_half)
var samples: PackedFloat32Array = PackedFloat32Array()   # size cols*rows, height in metres
## Terrain-suppression footprints (tunnels): each {min_x,max_x,min_z,max_z,floor_y}. Inside one,
## height_at returns floor_y (a low value) so structure pieces own the column and march() does not
## treat the column as solid ground.
var cutouts: Array = []

func sample(cx: int, cz: int) -> float:
	return samples[cz * cols + cx]

## floor_y of the cutout containing (x,z), or NAN if none. NAN chosen so callers branch with is_nan().
func cutout_floor(x: float, z: float) -> float:
	for c in cutouts:
		if x >= c["min_x"] and x <= c["max_x"] and z >= c["min_z"] and z <= c["max_z"]:
			return float(c["floor_y"])
	return NAN
