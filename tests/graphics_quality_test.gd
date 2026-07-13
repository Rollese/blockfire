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

func test_fsr_fields_default_on() -> void:
	var s := ClientSettings.new()
	assert_true(s.fsr_enabled, "FSR 2.2 on by default (native AA + upscaling)")
	assert_almost_eq(s.fsr_sharpness, 0.2, 0.0001)

func test_fsr_fields_round_trip() -> void:
	var path := "user://gfx_fsr_%d.cfg" % Time.get_ticks_usec()
	var a := ClientSettings.new()
	a.fsr_enabled = false
	a.fsr_sharpness = 0.8
	a.save_to(path)
	var b := ClientSettings.new()
	b.load_from(path)
	assert_false(b.fsr_enabled, "FSR toggle persists")
	assert_almost_eq(b.fsr_sharpness, 0.8, 0.0001)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_fsr_sharpness_clamps_on_load() -> void:
	var lo := "user://gfx_fsr_lo_%d.cfg" % Time.get_ticks_usec()
	var a := ClientSettings.new()
	a.fsr_sharpness = -1.0   # below floor
	a.save_to(lo)
	var b := ClientSettings.new()
	b.load_from(lo)
	assert_almost_eq(b.fsr_sharpness, 0.0, 0.0001, "fsr_sharpness clamps up to 0.0 floor")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lo))

	var hi := "user://gfx_fsr_hi_%d.cfg" % Time.get_ticks_usec()
	var c := ClientSettings.new()
	c.fsr_sharpness = 5.0   # above ceiling
	c.save_to(hi)
	var d := ClientSettings.new()
	d.load_from(hi)
	assert_almost_eq(d.fsr_sharpness, 2.0, 0.0001, "fsr_sharpness clamps down to 2.0 ceiling")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(hi))

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
	assert_true(b["fsr_enabled"], "balanced keeps FSR")

func test_preset_performance() -> void:
	var b := ClientSettings.quality_preset("performance")
	assert_false(b["ssao_enabled"])
	assert_false(b["volumetric_fog_enabled"])
	assert_false(b["glow_enabled"], "performance cuts glow (the biggest per-pixel cost)")
	assert_true(b["sun_shadow_enabled"], "performance keeps shadow")
	assert_almost_eq(float(b["render_scale"]), 1.0, 0.0001)
	assert_false(b["fsr_enabled"], "performance drops FSR (costlier than bilinear as an AA solution)")

func test_preset_potato() -> void:
	var b := ClientSettings.quality_preset("potato")
	assert_false(b["ssao_enabled"])
	assert_false(b["volumetric_fog_enabled"])
	assert_false(b["glow_enabled"])
	assert_false(b["sun_shadow_enabled"], "potato drops sun shadow")
	assert_almost_eq(float(b["render_scale"]), 0.8, 0.0001)
	assert_false(b["fsr_enabled"], "potato drops FSR")

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
	assert_false(s.fsr_enabled)

	s.apply_preset("potato")
	assert_false(s.sun_shadow_enabled)
	assert_almost_eq(s.render_scale, 0.8, 0.0001)

	s.apply_preset("high")
	assert_true(s.ssao_enabled and s.volumetric_fog_enabled and s.glow_enabled and s.sun_shadow_enabled)
	assert_almost_eq(s.render_scale, 1.0, 0.0001)

# Task 4: settings menu builds the new graphics widgets and a preset button drives settings live.

func test_menu_builds_and_preset_updates_settings() -> void:
	var path := "user://gfx_menu_%d.cfg" % Time.get_ticks_usec()
	var s := ClientSettings.new()
	var menu := SettingsMenu.new()
	menu._ready()   # builds the UI off-tree (validates the graphics tab constructs w/o error)
	menu.save_path = path
	menu.bind_settings(s)
	# New graphics widgets exist after build.
	assert_true(menu._glow_check != null, "glow checkbox built")
	assert_true(menu._shadow_check != null, "sun-shadow checkbox built")
	assert_true(menu._render_scale_option != null, "render-scale option built")
	assert_true(menu._fsr_check != null, "FSR checkbox built")
	assert_true(menu._fsr_sharpness_slider != null, "FSR sharpness slider built")
	var emitted := {"hit": false}
	menu.settings_applied.connect(func(_x): emitted["hit"] = true)
	menu._on_preset_pressed("performance")
	assert_false(s.glow_enabled, "Performance preset turned glow off on the settings object")
	assert_false(s.ssao_enabled)
	assert_true(s.sun_shadow_enabled, "Performance keeps sun shadow")
	assert_true(emitted["hit"], "preset applied live (settings_applied emitted)")
	assert_true(menu._glow_check.button_pressed == false, "glow checkbox refreshed to reflect preset")
	assert_false(menu._fsr_check.button_pressed, "FSR checkbox refreshed to reflect preset")
	assert_false(s.fsr_enabled, "Performance preset turned FSR off on the settings object")
	menu.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_render_scale_index_nearest() -> void:
	assert_eq(SettingsMenu._render_scale_index(1.0), 0)
	assert_eq(SettingsMenu._render_scale_index(0.85), 1)
	assert_eq(SettingsMenu._render_scale_index(0.6), 3)
	assert_eq(SettingsMenu._render_scale_index(0.62), 3, "nearest match")
