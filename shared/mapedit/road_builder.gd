class_name RoadBuilder
extends RefCounted
## Pure road geometry + terrain regrade for the M22 map editor. No editor dependency: the CLIENT
## imports this to render spline roads at map load, and the headless suite tests it directly.
##
## Roads are COSMETIC. Pawns and vehicles resolve against terrain height (terrain.gd), never against
## road meshes — so nothing here touches the sim or the wire. The corridor grade is the one exception
## and it is not an exception at all: it edits the HEIGHTMAP, which the sim already reads.
## See docs/superpowers/specs/2026-07-16-map-editor-design.md §4.

## Metres between resampled points along a spline. Fine enough that a ribbon follows terrain relief
## without visibly faceting; coarse enough that a 300 m road is ~150 quads, not thousands.
const RESAMPLE_STEP := 2.0

## Gaussian sigma (metres) for the along-road height profile smoothing. ~26 m matches the established
## regrade in tools/map_gen.py::gen_town_heightmap, tuned so the ~65 m grassy rolls stop oscillating
## the road while the long primary swell survives. See memory: blockfire-wavy-roads-open — the OWNER'S
## RULE is that roads follow the LONG smooth trend, they do NOT flatten the world.
const GRADE_SIGMA := 26.0

## Resample a polyline to evenly-spaced points (metres apart). Returns the input unchanged when it is
## too short to resample. Both the ribbon and the grade consume this so their samples line up.
static func resample(spline: PackedVector2Array, step: float = RESAMPLE_STEP) -> PackedVector2Array:
	if spline.size() < 2 or step <= 0.0:
		return spline
	var out := PackedVector2Array([spline[0]])
	var carry := 0.0
	for i in range(1, spline.size()):
		var a := spline[i - 1]
		var b := spline[i]
		var seg := a.distance_to(b)
		if seg <= 0.0001:
			continue
		var dir := (b - a) / seg
		var t := step - carry
		while t <= seg:
			out.append(a + dir * t)
			t += step
		carry = fposmod(carry + seg, step)
	if out[out.size() - 1].distance_to(spline[spline.size() - 1]) > 0.0001:
		out.append(spline[spline.size() - 1])
	return out

## Sample a profile at a possibly out-of-range index by extrapolating along the profile's GLOBAL
## end-to-end slope — the long-trend rise/fall from first sample to last — rather than clamping to
## the edge value or chasing the noisy LOCAL two-point slope. Clamping would flatten a long, consistent
## grade right where it nears the map boundary (the "flattens the world" bug the owner's rule forbids).
## Local-slope extrapolation blows up on oscillatory profiles (a ripple's instantaneous edge slope is
## not its trend). The global slope is exactly the road's long trend: near-zero for a ripple that
## begins and ends in phase, and exactly the true grade for an actual straight incline — both of which
## is exactly what a wide Gaussian along a corridor should extend past its ends.
static func _profile_sample(prof: PackedFloat32Array, j: int, end_slope: float) -> float:
	var n := prof.size()
	if j < 0:
		return prof[0] + end_slope * float(j)
	if j >= n:
		return prof[n - 1] + end_slope * float(j - (n - 1))
	return prof[j]

## 1-D Gaussian smoothing of a height profile. Out-of-range samples extrapolate the profile's global
## end-to-end slope (see _profile_sample) so a long, consistent grade survives right up to the edge of
## the spline, without oscillatory profiles blowing up past their ends.
static func smooth_profile(prof: PackedFloat32Array, sigma: float, step: float) -> PackedFloat32Array:
	var n := prof.size()
	if n == 0 or sigma <= 0.0:
		return prof
	var sig_samples := sigma / maxf(step, 0.0001)
	var r := int(ceil(sig_samples * 3.0))
	if r < 1:
		return prof
	var end_slope := 0.0
	if n > 1:
		end_slope = (prof[n - 1] - prof[0]) / float(n - 1)
	var ker := PackedFloat32Array()
	ker.resize(r * 2 + 1)
	var sum := 0.0
	for i in ker.size():
		var d := float(i - r) / sig_samples
		var w := exp(-0.5 * d * d)
		ker[i] = w
		sum += w
	for i in ker.size():
		ker[i] = ker[i] / sum
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var acc := 0.0
		for k in ker.size():
			var j := i + k - r
			acc += _profile_sample(prof, j, end_slope) * ker[k]
		out[i] = acc
	return out

## Bilinear height sample from a raw sample array (same maths as Terrain.height_at, but on the flat
## normalised/metre array the editor holds, with no TerrainGrid handle).
static func _sample_bilinear(h: PackedFloat32Array, cols: int, rows: int, spacing: float,
		origin_xz: Vector2, x: float, z: float) -> float:
	var gx := (x - origin_xz.x) / spacing
	var gz := (z - origin_xz.y) / spacing
	var x0 := clampi(int(floor(gx)), 0, cols - 1)
	var z0 := clampi(int(floor(gz)), 0, rows - 1)
	var x1 := mini(x0 + 1, cols - 1)
	var z1 := mini(z0 + 1, rows - 1)
	var fx := clampf(gx - float(x0), 0.0, 1.0)
	var fz := clampf(gz - float(z0), 0.0, 1.0)
	var h0 := lerpf(h[z0 * cols + x0], h[z0 * cols + x1], fx)
	var h1 := lerpf(h[z1 * cols + x0], h[z1 * cols + x1], fx)
	return lerpf(h0, h1, fz)

## Regrade the heightmap under a road: sample terrain along the spline, smooth that profile with a
## wide Gaussian, write it back within width/2, blending to natural terrain over `blend` metres.
## Mutates `heights` in place. Samples outside width/2 + blend are NEVER touched.
static func corridor_grade(heights: PackedFloat32Array, cols: int, rows: int, spacing: float,
		origin_xz: Vector2, spline: PackedVector2Array, width: float, blend: float,
		sigma: float = GRADE_SIGMA) -> void:
	if spline.size() < 2 or cols <= 0 or rows <= 0 or width <= 0.0:
		return
	var pts := resample(spline, RESAMPLE_STEP)
	if pts.size() < 2:
		return
	# 1. Natural height profile along the centreline.
	var prof := PackedFloat32Array()
	prof.resize(pts.size())
	for i in pts.size():
		prof[i] = _sample_bilinear(heights, cols, rows, spacing, origin_xz, pts[i].x, pts[i].y)
	# 2. Wide-Gaussian smooth -> the consistent long-trend grade.
	var graded := smooth_profile(prof, sigma, RESAMPLE_STEP)
	# 3. Write back within the corridor, blending out to natural terrain.
	var half := width * 0.5
	var reach := half + blend
	for zi in rows:
		var wz := origin_xz.y + float(zi) * spacing
		for xi in cols:
			var wx := origin_xz.x + float(xi) * spacing
			var near := _nearest_on_polyline(pts, Vector2(wx, wz), reach)
			var d: float = near["dist"]
			if d > reach:
				continue
			var target: float = graded[int(near["index"])]
			var w := 1.0
			if d > half:
				var t := (d - half) / maxf(blend, 0.0001)
				w = 1.0 - (t * t * (3.0 - 2.0 * t))   # smoothstep: 1 at the road edge -> 0 at the rim
			var i := zi * cols + xi
			heights[i] = lerpf(heights[i], target, clampf(w, 0.0, 1.0))

## Nearest resampled point to `p`. Returns {"index": int, "dist": float}. `reach` lets callers skip
## the scan cheaply — a coarse AABB reject on the polyline's bounds would be a later optimisation.
static func _nearest_on_polyline(pts: PackedVector2Array, p: Vector2, reach: float) -> Dictionary:
	var best := INF
	var best_i := 0
	for i in pts.size():
		var d := pts[i].distance_squared_to(p)
		if d < best:
			best = d
			best_i = i
	return {"index": best_i, "dist": sqrt(best)}
