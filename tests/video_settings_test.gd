extends TestCase

func test_common_resolutions_include_1080p() -> void:
	var presets := VideoSettings.common_resolutions()
	assert_true(presets.size() >= 3)
	var idx := VideoSettings.find_resolution_index(1920, 1080)
	assert_eq(idx, 2, "1920x1080 is in the preset list")

func test_resolution_label() -> void:
	assert_eq(VideoSettings.resolution_label(Vector2i(1280, 720)), "1280 × 720")

func test_window_modes() -> void:
	assert_true(VideoSettings.WINDOW_MODES.has("windowed"))
	assert_true(VideoSettings.WINDOW_MODES.has("fullscreen"))
