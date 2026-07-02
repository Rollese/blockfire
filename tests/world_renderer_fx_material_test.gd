extends TestCase
## fx_material factory (batch 5.3): the unshaded FX material recipe was hand-rolled ~12x in
## world_renderer (tracers, puffs, beams, blast cores, zone rings…). One factory, pinned here.


func test_plain_unshaded() -> void:
	var m := WorldRenderer.fx_material(Color(0.18, 0.16, 0.14))
	assert_eq(m.albedo_color, Color(0.18, 0.16, 0.14))
	assert_eq(m.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_eq(m.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED, "opaque unless asked")
	assert_false(m.emission_enabled)


func test_alpha_transparency() -> void:
	var m := WorldRenderer.fx_material(Color(0.5, 0.5, 0.5, 0.65), true)
	assert_eq(m.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)


func test_emissive_with_color_and_energy() -> void:
	var c := Color(1.0, 0.6, 0.2)
	var m := WorldRenderer.fx_material(c, true, true, c, 2.5)
	assert_true(m.emission_enabled)
	assert_eq(m.emission, c)
	assert_almost_eq(m.emission_energy_multiplier, 2.5, 0.001)


func test_emissive_default_color_matches_engine_default() -> void:
	# Pool materials enable emission at build time and get their colour assigned per frame —
	# the factory must leave emission BLACK (the StandardMaterial3D default), not albedo-tinted.
	var m := WorldRenderer.fx_material(Color.WHITE, true, true)
	assert_true(m.emission_enabled)
	assert_eq(m.emission, Color(0, 0, 0, 1), "engine default emission preserved")
	assert_almost_eq(m.emission_energy_multiplier, 1.0, 0.001, "engine default energy preserved")
