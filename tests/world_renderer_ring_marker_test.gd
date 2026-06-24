extends TestCase
## Zone markers (M7): capture/base points render as a flat ground RING at the true radius
## (TorusMesh), not a screen-filling solid disc.

func test_ring_marker_spans_the_true_radius() -> void:
	var r := WorldRenderer.new()
	var m := r._make_ring_marker(20.0, 0.6, Color(0.6, 0.6, 0.6))
	var mesh := m.mesh as TorusMesh
	assert_true(mesh != null, "ring uses a TorusMesh (lies flat in XZ)")
	assert_almost_eq(mesh.inner_radius, 19.4, 0.01, "inner edge = radius - tube")
	assert_almost_eq(mesh.outer_radius, 20.6, 0.01, "outer edge = radius + tube")
	r.free()

func test_ring_marker_is_unshaded_and_casts_no_shadow() -> void:
	var r := WorldRenderer.new()
	var m := r._make_ring_marker(22.0, 0.8, Color(0.2, 0.5, 1.0))
	var mat := m.material_override as StandardMaterial3D
	assert_eq(mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "glows as a marker at any range")
	assert_true(mat.emission_enabled, "emissive so it reads in shadow")
	assert_eq(m.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a marker never casts shadow")
	r.free()

func test_ring_inner_radius_never_negative() -> void:
	var r := WorldRenderer.new()
	var m := r._make_ring_marker(0.2, 0.8, Color.WHITE)
	var mesh := m.mesh as TorusMesh
	assert_true(mesh.inner_radius > 0.0, "tiny radius clamps inner edge above zero")
	r.free()
