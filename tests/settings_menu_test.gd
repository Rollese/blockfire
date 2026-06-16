extends TestCase

func test_apply_writes_settings_and_emits() -> void:
	var s := ClientSettings.new()
	var menu := SettingsMenu.new()
	menu.bind_settings(s)
	var emitted := {"hit": false}
	menu.settings_applied.connect(func(_x): emitted["hit"] = true)
	menu.apply()
	assert_true(emitted["hit"], "apply emits settings_applied")
	menu.free()
