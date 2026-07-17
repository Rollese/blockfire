class_name TerrainBrush
extends RefCounted
## Pure heightmap brush ops for the M22 map editor. No editor/engine-node dependency: operates on a
## flat PackedFloat32Array laid out exactly like TerrainGrid.samples (row-major, z outer / x inner),
## so a brushed array can be handed straight to a TerrainGrid. Deterministic — same inputs, same bytes.
## See docs/superpowers/specs/2026-07-16-map-editor-design.md §4.

enum Mode { RAISE, LOWER, SMOOTH, FLATTEN }

## Smooth radial falloff: 1 at the centre -> 0 at the rim. smoothstep, so strokes blend without a
## visible cone edge (a linear falloff leaves a crease the owner would have to sculpt back out).
static func _falloff(dist: float, radius: float) -> float:
	if radius <= 0.0:
		return 0.0
	var t := clampf(dist / radius, 0.0, 1.0)
	var s := 1.0 - t
	return s * s * (3.0 - 2.0 * s)

## Mutates `heights` in place. `origin_xz` is the world position of sample (0,0) (== -world_half on
## both axes). `center_xz` is the brush centre in world metres. `radius` in metres. `strength` is
## metres-per-stroke for RAISE/LOWER, a 0..1 blend factor for SMOOTH/FLATTEN. `target` is the height
## FLATTEN converges to (ignored by the other modes).
static func apply(heights: PackedFloat32Array, cols: int, rows: int, spacing: float,
		origin_xz: Vector2, center_xz: Vector2, radius: float, strength: float,
		mode: Mode, target: float = 0.0) -> void:
	if cols <= 0 or rows <= 0 or radius <= 0.0 or spacing <= 0.0:
		return
	# Only visit samples whose world column can fall inside the brush disc.
	var xi0 := clampi(int(floor((center_xz.x - radius - origin_xz.x) / spacing)), 0, cols - 1)
	var xi1 := clampi(int(ceil((center_xz.x + radius - origin_xz.x) / spacing)), 0, cols - 1)
	var zi0 := clampi(int(floor((center_xz.y - radius - origin_xz.y) / spacing)), 0, rows - 1)
	var zi1 := clampi(int(ceil((center_xz.y + radius - origin_xz.y) / spacing)), 0, rows - 1)
	# SMOOTH reads neighbours, so it must sample the ORIGINAL heights, not partially-written ones.
	var src := heights.duplicate() if mode == Mode.SMOOTH else heights
	for zi in range(zi0, zi1 + 1):
		var wz := origin_xz.y + float(zi) * spacing
		for xi in range(xi0, xi1 + 1):
			var wx := origin_xz.x + float(xi) * spacing
			var d := Vector2(wx, wz).distance_to(center_xz)
			if d > radius:
				continue
			var w := _falloff(d, radius)
			if w <= 0.0:
				continue
			var i := zi * cols + xi
			match mode:
				Mode.RAISE:
					heights[i] = src[i] + strength * w
				Mode.LOWER:
					heights[i] = src[i] - strength * w
				Mode.FLATTEN:
					heights[i] = lerpf(src[i], target, clampf(strength, 0.0, 1.0) * w)
				Mode.SMOOTH:
					heights[i] = lerpf(src[i], _neighbour_mean(src, cols, rows, xi, zi), clampf(strength, 0.0, 1.0) * w)

## Mean of the 3x3 neighbourhood (edge samples clamp), including the centre.
static func _neighbour_mean(src: PackedFloat32Array, cols: int, rows: int, xi: int, zi: int) -> float:
	var sum := 0.0
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var nx := clampi(xi + dx, 0, cols - 1)
			var nz := clampi(zi + dz, 0, rows - 1)
			sum += src[nz * cols + nx]
	return sum / 9.0
