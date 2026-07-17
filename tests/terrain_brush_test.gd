extends TestCase
const TerrainBrush := preload("res://shared/mapedit/terrain_brush.gd")

# An 11x11 grid, spacing 2 m, origin (-10,-10) -> covers world [-10..10] on both axes.
func _flat() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(121)
	h.fill(0.0)
	return h

func _at(h: PackedFloat32Array, xi: int, zi: int) -> float:
	return h[zi * 11 + xi]

# Centre sample (xi=5, zi=5) is world (0,0).
func test_raise_lifts_centre_most() -> void:
	var h := _flat()
	TerrainBrush.apply(h, 11, 11, 2.0, Vector2(-10, -10), Vector2(0, 0), 6.0, 3.0, TerrainBrush.Mode.RAISE)
	assert_almost_eq(_at(h, 5, 5), 3.0, 0.001, "centre gets full strength")
	assert_gt(_at(h, 5, 5), _at(h, 6, 5), "falloff: centre higher than 2 m out")
	assert_gt(_at(h, 6, 5), 0.0, "2 m out still inside radius 6")
	assert_almost_eq(_at(h, 0, 0), 0.0, 0.001, "far corner untouched")

func test_lower_is_the_inverse_of_raise() -> void:
	var h := _flat()
	TerrainBrush.apply(h, 11, 11, 2.0, Vector2(-10, -10), Vector2(0, 0), 6.0, 3.0, TerrainBrush.Mode.LOWER)
	assert_almost_eq(_at(h, 5, 5), -3.0, 0.001, "centre pushed down by strength")
	assert_true(_at(h, 6, 5) < 0.0, "neighbour also lowered")
	assert_true(_at(h, 6, 5) > _at(h, 5, 5), "falloff: neighbour lowered less than centre")

func test_radius_bounds_the_effect() -> void:
	var h := _flat()
	# radius 2.5 m reaches the sample 2 m away but not the one 4 m away
	TerrainBrush.apply(h, 11, 11, 2.0, Vector2(-10, -10), Vector2(0, 0), 2.5, 5.0, TerrainBrush.Mode.RAISE)
	assert_gt(_at(h, 6, 5), 0.0, "2 m out is inside radius 2.5")
	assert_almost_eq(_at(h, 7, 5), 0.0, 0.001, "4 m out is outside radius 2.5")

func test_smooth_reduces_variance() -> void:
	var h := _flat()
	h[5 * 11 + 5] = 10.0   # a spike at the centre
	var before := _at(h, 5, 5)
	TerrainBrush.apply(h, 11, 11, 2.0, Vector2(-10, -10), Vector2(0, 0), 6.0, 1.0, TerrainBrush.Mode.SMOOTH)
	assert_true(_at(h, 5, 5) < before, "spike is pulled down toward its neighbours")
	assert_gt(_at(h, 6, 5), 0.0, "neighbours are pulled up toward the spike")

func test_flatten_converges_to_target() -> void:
	var h := _flat()
	h[5 * 11 + 5] = 10.0
	# strength 1.0 = full blend to the target height in one stroke
	TerrainBrush.apply(h, 11, 11, 2.0, Vector2(-10, -10), Vector2(0, 0), 6.0, 1.0, TerrainBrush.Mode.FLATTEN, 4.0)
	assert_almost_eq(_at(h, 5, 5), 4.0, 0.001, "centre snaps to the flatten target")

func test_out_of_bounds_centre_is_safe() -> void:
	var h := _flat()
	TerrainBrush.apply(h, 11, 11, 2.0, Vector2(-10, -10), Vector2(500, 500), 6.0, 3.0, TerrainBrush.Mode.RAISE)
	assert_almost_eq(_at(h, 5, 5), 0.0, 0.001, "brush far outside the grid changes nothing, no crash")

func test_apply_is_deterministic() -> void:
	var a := _flat()
	var b := _flat()
	TerrainBrush.apply(a, 11, 11, 2.0, Vector2(-10, -10), Vector2(1.3, -2.7), 5.0, 2.0, TerrainBrush.Mode.RAISE)
	TerrainBrush.apply(b, 11, 11, 2.0, Vector2(-10, -10), Vector2(1.3, -2.7), 5.0, 2.0, TerrainBrush.Mode.RAISE)
	for i in 121:
		assert_almost_eq(a[i], b[i], 0.0, "same inputs -> byte-identical output at %d" % i)
