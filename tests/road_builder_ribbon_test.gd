extends TestCase
const RoadBuilder := preload("res://shared/mapedit/road_builder.gd")

# A height sampler shaped like a hill so we can prove the ribbon DRAPES rather than lying flat.
# NOTE: coefficient tuned so a 40 m road (x in [-20,20]) at the tested 8 m width produces a
# height swing clearly above the "not a flat plane" threshold below (0.001 was mathematically
# incapable of ever exceeding it: the x-domain is fixed by the spline, bounding the max possible
# swing to 0.4 regardless of implementation — verified independently before changing this).
func _hill(x: float, z: float) -> float:
	return 5.0 - 0.05 * (x * x + z * z) * 0.1

func _flat(_x: float, _z: float) -> float:
	return 2.0

func test_ribbon_has_verts_and_indices() -> void:
	var arrays := RoadBuilder.ribbon_mesh(PackedVector2Array([Vector2(-20, 0), Vector2(20, 0)]), 8.0, Callable(self, "_flat"))
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_gt(verts.size(), 0, "ribbon produced vertices")
	assert_eq(verts.size() % 2, 0, "vertices come in left/right pairs")
	assert_eq(idx.size() % 3, 0, "indices form whole triangles")
	# n pairs -> (n-1) quads -> (n-1)*2 tris -> (n-1)*6 indices
	var pairs := verts.size() / 2
	assert_eq(idx.size(), (pairs - 1) * 6, "index count matches the quad strip")

func test_ribbon_width_is_respected() -> void:
	var arrays := RoadBuilder.ribbon_mesh(PackedVector2Array([Vector2(-20, 0), Vector2(20, 0)]), 8.0, Callable(self, "_flat"))
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# A road along +x has its left/right pair separated along z by exactly `width`.
	var span := absf(verts[0].z - verts[1].z)
	assert_almost_eq(span, 8.0, 0.01, "left/right verts are `width` apart across the road")

func test_ribbon_drapes_on_the_height_sampler() -> void:
	var arrays := RoadBuilder.ribbon_mesh(PackedVector2Array([Vector2(-20, 0), Vector2(20, 0)]), 8.0, Callable(self, "_hill"))
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var ys := []
	for v in verts:
		ys.append(v.y)
	var lo: float = ys.min()
	var hi: float = ys.max()
	assert_gt(hi - lo, 0.5, "ribbon y follows the hill (it is not a flat plane)")
	# Every vertex sits slightly ABOVE the sampled ground so it never z-fights the terrain.
	for v in verts:
		assert_true(v.y > _hill(v.x, v.z) - 0.001, "vertex is not buried under the terrain")

func test_ribbon_lifts_off_the_ground_to_avoid_z_fight() -> void:
	var arrays := RoadBuilder.ribbon_mesh(PackedVector2Array([Vector2(-20, 0), Vector2(20, 0)]), 8.0, Callable(self, "_flat"))
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_almost_eq(verts[0].y, 2.0 + RoadBuilder.RIBBON_LIFT, 0.001, "vertex sits exactly RIBBON_LIFT above ground")

func test_ribbon_normals_and_uvs_present() -> void:
	var arrays := RoadBuilder.ribbon_mesh(PackedVector2Array([Vector2(-20, 0), Vector2(20, 0)]), 8.0, Callable(self, "_flat"))
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(norms.size(), verts.size(), "one normal per vertex")
	assert_eq(uvs.size(), verts.size(), "one uv per vertex")
	assert_gt(norms[0].y, 0.9, "flat road normal points up")

func test_degenerate_spline_returns_empty() -> void:
	var arrays := RoadBuilder.ribbon_mesh(PackedVector2Array([Vector2(0, 0)]), 8.0, Callable(self, "_flat"))
	assert_true(arrays.is_empty(), "a 1-point spline yields no mesh, no crash")

func test_curved_spline_produces_a_continuous_ribbon() -> void:
	# An L-bend: the ribbon must not tear or self-invert at the corner.
	var arrays := RoadBuilder.ribbon_mesh(PackedVector2Array([Vector2(-20, 0), Vector2(0, 0), Vector2(0, 20)]), 6.0, Callable(self, "_flat"))
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_gt(verts.size(), 8, "bend produces a run of pairs")
	# Consecutive centre points must advance monotonically along the path (no fold-back).
	for i in range(2, verts.size(), 2):
		var prev_mid := (verts[i - 2] + verts[i - 1]) * 0.5
		var mid := (verts[i] + verts[i + 1]) * 0.5
		assert_gt(prev_mid.distance_to(mid), 0.0, "ribbon advances at pair %d" % i)
