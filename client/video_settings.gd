class_name VideoSettings
extends Object
## Pure video/display helpers — resolution presets and window-mode labels.
## apply() touches DisplayServer (runtime only); presets are headless-testable.

const WINDOW_MODES := ["windowed", "fullscreen", "borderless"]

static func common_resolutions() -> Array:
	return [
		Vector2i(1280, 720),
		Vector2i(1600, 900),
		Vector2i(1920, 1080),
		Vector2i(2560, 1440),
		Vector2i(3840, 2160),
	]

static func resolution_label(size: Vector2i) -> String:
	return "%d × %d" % [size.x, size.y]

static func find_resolution_index(x: int, y: int) -> int:
	var presets := common_resolutions()
	for i in presets.size():
		if presets[i].x == x and presets[i].y == y:
			return i
	return -1

## Apply persisted video settings to the OS window. No-op when headless.
static func apply(settings: ClientSettings) -> void:
	if DisplayServer.get_name() == "headless":
		return
	match settings.window_mode:
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"borderless":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(Vector2i(settings.resolution_x, settings.resolution_y))
