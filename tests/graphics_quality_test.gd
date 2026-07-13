extends TestCase

# Task 1: new [video] fields round-trip + clamp + defaults.

func test_new_video_fields_default_on() -> void:
	var s := ClientSettings.new()
	assert_true(s.glow_enabled, "glow on by default (full desktop look)")
	assert_true(s.sun_shadow_enabled, "sun shadow on by default")
	assert_almost_eq(s.render_scale, 1.0, 0.0001)

func test_new_video_fields_round_trip() -> void:
	var path := "user://gfx_quality_%d.cfg" % Time.get_ticks_usec()
	var a := ClientSettings.new()
	a.glow_enabled = false
	a.sun_shadow_enabled = false
	a.render_scale = 0.75
	a.save_to(path)
	var b := ClientSettings.new()
	b.load_from(path)
	assert_false(b.glow_enabled, "glow toggle persists")
	assert_false(b.sun_shadow_enabled, "sun-shadow toggle persists")
	assert_almost_eq(b.render_scale, 0.75, 0.0001)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_render_scale_clamps_on_load() -> void:
	var lo := "user://gfx_lo_%d.cfg" % Time.get_ticks_usec()
	var a := ClientSettings.new()
	a.render_scale = 0.2   # below floor
	a.save_to(lo)
	var b := ClientSettings.new()
	b.load_from(lo)
	assert_almost_eq(b.render_scale, 0.5, 0.0001, "render_scale clamps up to 0.5 floor")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lo))

	var hi := "user://gfx_hi_%d.cfg" % Time.get_ticks_usec()
	var c := ClientSettings.new()
	c.render_scale = 2.0   # above ceiling
	c.save_to(hi)
	var d := ClientSettings.new()
	d.load_from(hi)
	assert_almost_eq(d.render_scale, 1.0, 0.0001, "render_scale clamps down to 1.0 ceiling")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(hi))

# Task 2: quality preset mapper + apply_preset.

func test_preset_high() -> void:
	var b := ClientSettings.quality_preset("high")
	assert_true(b["ssao_enabled"] and b["volumetric_fog_enabled"] and b["glow_enabled"] and b["sun_shadow_enabled"])
	assert_almost_eq(float(b["render_scale"]), 1.0, 0.0001)

func test_preset_balanced() -> void:
	var b := ClientSettings.quality_preset("balanced")
	assert_false(b["ssao_enabled"])
	assert_false(b["volumetric_fog_enabled"])
	assert_true(b["glow_enabled"], "balanced keeps glow")
	assert_true(b["sun_shadow_enabled"], "balanced keeps shadow")
	assert_almost_eq(float(b["render_scale"]), 1.0, 0.0001)

func test_preset_performance() -> void:
	var b := ClientSettings.quality_preset("performance")
	assert_false(b["ssao_enabled"])
	assert_false(b["volumetric_fog_enabled"])
	assert_false(b["glow_enabled"], "performance cuts glow (the biggest per-pixel cost)")
	assert_true(b["sun_shadow_enabled"], "performance keeps shadow")
	assert_almost_eq(float(b["render_scale"]), 1.0, 0.0001)

func test_preset_potato() -> void:
	var b := ClientSettings.quality_preset("potato")
	assert_false(b["ssao_enabled"])
	assert_false(b["volumetric_fog_enabled"])
	assert_false(b["glow_enabled"])
	assert_false(b["sun_shadow_enabled"], "potato drops sun shadow")
	assert_almost_eq(float(b["render_scale"]), 0.8, 0.0001)

func test_preset_unknown_falls_back_to_high() -> void:
	var b := ClientSettings.quality_preset("nonsense")
	var h := ClientSettings.quality_preset("high")
	assert_eq(b, h, "unknown preset name is a safe fall back to high")

func test_apply_preset_mutates_fields() -> void:
	var s := ClientSettings.new()
	s.apply_preset("performance")
	assert_false(s.ssao_enabled)
	assert_false(s.volumetric_fog_enabled)
	assert_false(s.glow_enabled)
	assert_true(s.sun_shadow_enabled)
	assert_almost_eq(s.render_scale, 1.0, 0.0001)

	s.apply_preset("potato")
	assert_false(s.sun_shadow_enabled)
	assert_almost_eq(s.render_scale, 0.8, 0.0001)

	s.apply_preset("high")
	assert_true(s.ssao_enabled and s.volumetric_fog_enabled and s.glow_enabled and s.sun_shadow_enabled)
	assert_almost_eq(s.render_scale, 1.0, 0.0001)
