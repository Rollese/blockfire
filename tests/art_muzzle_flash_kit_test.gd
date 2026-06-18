extends TestCase

func test_build_returns_emissive_unshaded_mesh() -> void:
	var flash := MuzzleFlashKit.build()
	assert_true(flash is MeshInstance3D, "returns a MeshInstance3D")
	assert_true(flash.mesh is BoxMesh, "uses a box mesh (welded-primitive kit style)")
	var mat := flash.material_override as StandardMaterial3D
	assert_true(mat != null, "carries a material override")
	assert_true(mat.emission_enabled, "emissive so it reads as a bright flash")
	assert_eq(mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "unshaded — full brightness")
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA, "alpha-blended for the fade-out")

func test_build_mesh_is_small_and_no_shadow() -> void:
	var flash := MuzzleFlashKit.build()
	var size := (flash.mesh as BoxMesh).size
	assert_almost_eq(size.x, MuzzleFlashKit.SIZE, 0.001, "flash width == SIZE")
	assert_true(size.z < size.x, "flash is a thin facing plate, not a cube")
	assert_eq(flash.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a flash casts no shadow")

func test_alpha_for_is_linear_and_clamped() -> void:
	var ttl := MuzzleFlashKit.TTL
	assert_almost_eq(MuzzleFlashKit.alpha_for(ttl, ttl), 1.0, 0.001, "full life = fully opaque")
	assert_almost_eq(MuzzleFlashKit.alpha_for(0.0, ttl), 0.0, 0.001, "no life left = invisible")
	assert_almost_eq(MuzzleFlashKit.alpha_for(ttl * 0.5, ttl), 0.5, 0.001, "half life = half alpha")
	assert_almost_eq(MuzzleFlashKit.alpha_for(ttl * 2.0, ttl), 1.0, 0.001, "over-full clamps to 1")
	assert_almost_eq(MuzzleFlashKit.alpha_for(-1.0, ttl), 0.0, 0.001, "negative clamps to 0")

func test_alpha_for_handles_zero_ttl() -> void:
	assert_almost_eq(MuzzleFlashKit.alpha_for(1.0, 0.0), 0.0, 0.001, "zero/invalid ttl -> 0, never divide-by-zero")
