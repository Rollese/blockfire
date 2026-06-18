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
	var menu := SettingsMenu.new()
	menu.save_path = TEMP_PATH
	menu.bind_settings(s)
	menu.apply()
	var reloaded := ClientSettings.new()
	reloaded.load_from(TEMP_PATH)
	assert_true(reloaded.use_model_characters, "apply() preserves use_model_characters (no clobber)")
	menu.free()
	_cleanup()
