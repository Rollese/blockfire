extends TestCase
const RoadBuilder := preload("res://shared/mapedit/road_builder.gd")

# 41x41 grid, spacing 2 m, origin (-40,-40) -> world [-40..40].
const N := 41
const SP := 2.0
const ORIGIN := Vector2(-40, -40)

func _at(h: PackedFloat32Array, xi: int, zi: int) -> float:
	return h[zi * N + xi]

# Rolling terrain: a sine ripple along x with ~20 m wavelength and 3 m amplitude — the "grassy rolls"
# a road must smooth THROUGH without flattening the surrounding land.
func _rolling() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(N * N)
	for zi in N:
		for xi in N:
			var wx := ORIGIN.x + float(xi) * SP
			h[zi * N + xi] = 3.0 * sin(wx * TAU / 20.0)
	return h

# A straight road down the middle along x (z = 0 -> zi = 20).
func _spline() -> PackedVector2Array:
	return PackedVector2Array([Vector2(-40, 0), Vector2(40, 0)])

func test_grade_smooths_ripple_along_the_road() -> void:
	var h := _rolling()
	var before_var := _variance_along_road(h)
	RoadBuilder.corridor_grade(h, N, N, SP, ORIGIN, _spline(), 8.0, 12.0)
	var after_var := _variance_along_road(h)
	assert_true(after_var < before_var * 0.5, "road profile variance %f -> %f (ripple smoothed out)" % [before_var, after_var])

func _variance_along_road(h: PackedFloat32Array) -> float:
	var vals := []
	for xi in N:
		vals.append(_at(h, xi, 20))
	var mean := 0.0
	for v in vals:
		mean += v
	mean /= float(vals.size())
	var s := 0.0
	for v in vals:
		s += (v - mean) * (v - mean)
	return s / float(vals.size())

func test_grade_does_not_flatten_the_surrounding_world() -> void:
	# THE OWNER'S RULE: roads follow the long trend; they must not bulldoze the countryside.
	var h := _rolling()
	var far_before := _at(h, 10, 0)   # z = -40, far from the road at z = 0
	RoadBuilder.corridor_grade(h, N, N, SP, ORIGIN, _spline(), 8.0, 12.0)
	assert_almost_eq(_at(h, 10, 0), far_before, 0.001, "terrain far from the corridor is untouched")

func test_grade_follows_the_long_trend() -> void:
	# A long linear slope (no ripple): the road must KEEP the slope, not level it.
	var h := PackedFloat32Array()
	h.resize(N * N)
	for zi in N:
		for xi in N:
			h[zi * N + xi] = (ORIGIN.x + float(xi) * SP) * 0.1   # 10% grade along x
	RoadBuilder.corridor_grade(h, N, N, SP, ORIGIN, _spline(), 8.0, 12.0)
	assert_almost_eq(_at(h, 30, 20) - _at(h, 10, 20), 4.0, 0.3, "the 40 m long-trend rise is preserved")

func test_grade_blends_at_the_corridor_edge() -> void:
	var h := _rolling()
	var natural := _at(h, 5, 32)   # 24 m from the road centre: outside width/2 + blend
	RoadBuilder.corridor_grade(h, N, N, SP, ORIGIN, _spline(), 8.0, 12.0)
	assert_almost_eq(_at(h, 5, 32), natural, 0.001, "beyond the blend band -> natural terrain")
	# On the centreline the road profile wins outright.
	var centre_line_is_smooth := absf(_at(h, 5, 20) - _at(h, 6, 20)) < 1.0
	assert_true(centre_line_is_smooth, "adjacent centreline samples differ gently (consistent grade)")

func test_empty_or_degenerate_spline_is_safe() -> void:
	var h := _rolling()
	var copy := h.duplicate()
	RoadBuilder.corridor_grade(h, N, N, SP, ORIGIN, PackedVector2Array(), 8.0, 12.0)
	for i in h.size():
		assert_almost_eq(h[i], copy[i], 0.0, "empty spline changes nothing")
	RoadBuilder.corridor_grade(h, N, N, SP, ORIGIN, PackedVector2Array([Vector2(0, 0)]), 8.0, 12.0)
	assert_true(true, "single-point spline does not crash")
