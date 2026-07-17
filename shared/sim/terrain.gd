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

## Build a TerrainGrid from a grayscale Image. Red channel 0..1 -> [height_min, height_min+scale].
## Image is cols x rows; samples read row-major with z increasing downward (image row 0 = z=-world_half).
static func build_grid(img: Image, spacing: float, world_half: float, height_min: float, height_scale: float) -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = img.get_width()
	g.rows = img.get_height()
	g.spacing = spacing
	g.origin_x = -world_half
	g.origin_z = -world_half
	var s := PackedFloat32Array()
	s.resize(g.cols * g.rows)
	for zi in g.rows:
		for xi in g.cols:
			var v := img.get_pixel(xi, zi).r   # grayscale: r==g==b
			s[zi * g.cols + xi] = height_min + v * height_scale
	g.samples = s
	return g

## Level every sample whose world column falls in the AABB [min_x..max_x]x[min_z..max_z] to `height`.
## The +/- spacing slack guarantees the pad covers samples straddling the footprint edge so a building
## foundation never floats over a half-flattened boundary cell.
static func flatten_pad(grid: TerrainGrid, min_x: float, max_x: float, min_z: float, max_z: float, height: float) -> void:
	if grid == null:
		return
	for zi in grid.rows:
		var wz := grid.origin_z + float(zi) * grid.spacing
		if wz < min_z - grid.spacing or wz > max_z + grid.spacing:
			continue
		for xi in grid.cols:
			var wx := grid.origin_x + float(xi) * grid.spacing
			if wx < min_x - grid.spacing or wx > max_x + grid.spacing:
				continue
			grid.samples[zi * grid.cols + xi] = height

## Record a terrain-suppression AABB (tunnel). Inside it, height_at returns floor_y (a low value)
## so structure pieces own the column and march() does not treat the column as solid ground.
static func carve_cutout(grid: TerrainGrid, min_x: float, max_x: float, min_z: float, max_z: float, floor_y: float) -> void:
	if grid == null:
		return
	grid.cutouts.append({"min_x": min_x, "max_x": max_x, "min_z": min_z, "max_z": max_z, "floor_y": floor_y})

## Cutout floor sentinel: well below any real terrain so the maxf(structure, terrain) chain always
## lets a structure floor win inside a tunnel, and march never treats the column as solid ground.
const CUTOUT_FLOOR := -1000.0

## Round a sampled terrain height to a BuildGrid cell base (buildings are cell-aligned; a fractional
## foundation would need sub-cell offsets, out of scope per spec).
static func snap_pad_height(h: float) -> float:
	return roundf(h / BuildGrid.CELL_SIZE) * BuildGrid.CELL_SIZE

## Load the map's heightmap PNG (relative to base_dir), build the grid, and apply the load-time
## footprint pass: flatten a flat pad under each building (or carve a cutout when terrain_cutout),
## snapping origin_cell.y to the pad. Returns null when the map has no terrain (flat).
## Accepts float EXR (what the M22 map editor writes — exact heights) or legacy 8-bit greyscale PNG
## (256 levels; kept loading so pre-M22 maps never break). Image.load() handles both by extension.
## Deterministic:
## server and client call this with the same map + PNG and get an identical grid + origin_cell.y
## writeback (no wire cost, no divergence). `footprint_fn` (Callable) maps a building entry ->
## {min_x,max_x,min_z,max_z}; pass an invalid Callable to default to the origin cell only.
static func load_for_map(map: MapDef, base_dir: String, footprint_fn: Callable) -> TerrainGrid:
	if map == null or map.terrain.is_empty():
		return null
	var t: Dictionary = map.terrain
	var path: String = base_dir.path_join(String(t["heightmap"]))
	var img := Image.new()
	var err := img.load(path)
	if err != OK:
		push_error("[terrain] failed to load heightmap %s (err %d)" % [path, err])
		return null
	if img.get_format() != Image.FORMAT_RGBF:
		img.convert(Image.FORMAT_RGBF)
	# The map editor (M22) generates heightmaps, so a dimension/world_half disagreement is now a real
	# authoring mistake rather than an impossible one. Refuse it: a silently-wrong grid would misplace
	# EVERY column on the map (origin is -world_half and spacing is fixed), which is far harder to
	# diagnose downstream than a load failure here.
	var spacing := float(t["sample_spacing"])
	var expect := int(round(map.world_half * 2.0 / spacing)) + 1
	if img.get_width() != expect or img.get_height() != expect:
		push_error("[terrain] heightmap %s is %dx%d but world_half %.1f @ spacing %.1f needs %dx%d" \
			% [path, img.get_width(), img.get_height(), map.world_half, spacing, expect, expect])
		return null
	var grid := build_grid(img, spacing, map.world_half, float(t["height_min"]), float(t["height_scale"]))
	for b in map.buildings:
		var oc: Vector3i = b["origin_cell"]
		var fp: Dictionary
		if footprint_fn.is_valid():
			fp = footprint_fn.call(b)
		elif b.has("footprint"):
			fp = b["footprint"]   # baked world-AABB from map_gen -> flatten the FULL building pad
		else:
			var mn := BuildGrid.cell_min(oc)
			fp = {"min_x": mn.x, "max_x": mn.x + BuildGrid.CELL_SIZE, "min_z": mn.z, "max_z": mn.z + BuildGrid.CELL_SIZE}
		var cx := (float(fp["min_x"]) + float(fp["max_x"])) * 0.5
		var cz := (float(fp["min_z"]) + float(fp["max_z"])) * 0.5
		if bool(b.get("terrain_cutout", false)):
			carve_cutout(grid, fp["min_x"], fp["max_x"], fp["min_z"], fp["max_z"], CUTOUT_FLOOR)
			# a cutout building keeps its authored origin_cell.y (it sits below grade by design)
		else:
			var h := snap_pad_height(height_at(grid, cx, cz))
			flatten_pad(grid, fp["min_x"], fp["max_x"], fp["min_z"], fp["max_z"], h)
			b["origin_cell"] = Vector3i(oc.x, int(round(h / BuildGrid.CELL_SIZE)), oc.z)
	# Terrain-adjust standalone map geometry (authored at y=0 for a flat map) so it sits ON the terrain
	# instead of floating above / buried below it. Ladders shift by the terrain height at their foot
	# (length preserved); platforms shift by the terrain height at their centre. Both server and client
	# derive this identically (same grid), so climb/platform-floor stay consistent with the render.
	for lad in map.ladders:
		var b: Vector3 = lad["bottom"]
		var dy := height_at(grid, b.x, b.z)
		lad["bottom"] = b + Vector3(0.0, dy, 0.0)
		lad["top"] = (lad["top"] as Vector3) + Vector3(0.0, dy, 0.0)
	for pf in map.platforms:
		var pmn: Vector3 = pf["min"]
		var pmx: Vector3 = pf["max"]
		var pdy := height_at(grid, (pmn.x + pmx.x) * 0.5, (pmn.z + pmx.z) * 0.5)
		pf["min"] = pmn + Vector3(0.0, pdy, 0.0)
		pf["max"] = pmx + Vector3(0.0, pdy, 0.0)
	return grid
