extends TestCase

# Never write the real user://settings.cfg from a test — apply() must save to an injectable path.
const TEMP_PATH := "user://test_settings_menu.cfg"

func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))

func test_apply_writes_settings_and_emits() -> void:
	var s := ClientSettings.new()
	var menu := SettingsMenu.new()
	menu.save_path = TEMP_PATH
	menu.bind_settings(s)
	var emitted := {"hit": false}
	menu.settings_applied.connect(func(_x): emitted["hit"] = true)
	menu.apply()
	assert_true(emitted["hit"], "apply emits settings_applied")
	menu.free()
	_cleanup()

func test_apply_preserves_unedited_flags() -> void:
	# Regression for the settings clobber: apply() must NOT reset fields the menu has no control for
	# (e.g. use_model_characters). It writes via the bound settings object + injectable path, so the
	# flag round-trips intact instead of being reset to the default.
	var s := ClientSettings.new()
	s.use_model_characters = true
	s.player_name = "TestPilot"
	s.voice_volume = 0.42
	var menu := SettingsMenu.new()
	menu.save_path = TEMP_PATH
	menu.bind_settings(s)
	menu.apply()
	var reloaded := ClientSettings.new()
	reloaded.load_from(TEMP_PATH)
	assert_true(reloaded.use_model_characters, "apply() preserves use_model_characters (no clobber)")
	assert_eq(reloaded.player_name, "TestPilot")
	assert_almost_eq(reloaded.voice_volume, 0.42, 0.001)
	menu.free()
	_cleanup()

func test_settings_roundtrip_new_fields() -> void:
	var s := ClientSettings.new()
	s.player_name = "Ranger"
	s.resolution_x = 2560
	s.resolution_y = 1440
	s.window_mode = "borderless"
	s.voice_volume = 0.55
	s.output_device = "Fake Output"
	s.bindings = {"jump": {"type": "key", "physical_keycode": 32}}
	s.save_to(TEMP_PATH)
	var r := ClientSettings.new()
	r.load_from(TEMP_PATH)
	assert_eq(r.player_name, "Ranger")
	assert_eq(r.resolution_x, 2560)
	assert_eq(r.window_mode, "borderless")
	assert_almost_eq(r.voice_volume, 0.55, 0.001)
	assert_eq(r.bindings["jump"]["type"], "key")
	_cleanup()
