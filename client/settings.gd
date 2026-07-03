class_name ClientSettings
extends RefCounted
## Player settings persisted to a ConfigFile. Defaults are BattleBit-ish; renderer toggle is read
## at boot (ADR-0005).

var sensitivity: float = 0.25
var fov: float = 90.0
var master_volume: float = 0.8
var voice_volume: float = 0.8
var invert_y: bool = false
var renderer_fallback: bool = false   # true -> request GL Compatibility
var use_model_characters: bool = true   # default ON: imported GLB soldier; set false for procedural CharacterKit
var player_name: String = "Player"
var resolution_x: int = 1920
var resolution_y: int = 1080
var window_mode: String = "windowed"   # windowed | fullscreen | borderless
var output_device: String = ""         # "" = system default
var input_device: String = ""          # "" = system default
## action -> {type, physical_keycode|button_index} — see InputBindings
var bindings: Dictionary = {}

func save_to(path: String = "user://settings.cfg") -> void:
	var cf := ConfigFile.new()
	cf.set_value("player", "name", player_name)
	cf.set_value("input", "sensitivity", sensitivity)
	cf.set_value("input", "invert_y", invert_y)
	cf.set_value("video", "fov", fov)
	cf.set_value("video", "renderer_fallback", renderer_fallback)
	cf.set_value("video", "use_model_characters", use_model_characters)
	cf.set_value("video", "resolution_x", resolution_x)
	cf.set_value("video", "resolution_y", resolution_y)
	cf.set_value("video", "window_mode", window_mode)
	cf.set_value("audio", "master_volume", master_volume)
	cf.set_value("audio", "voice_volume", voice_volume)
	cf.set_value("audio", "output_device", output_device)
	cf.set_value("audio", "input_device", input_device)
	for action in bindings:
		cf.set_value("bindings", action, bindings[action])
	cf.save(path)

func load_from(path: String = "user://settings.cfg") -> void:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return   # keep defaults
	player_name = String(cf.get_value("player", "name", player_name))
	sensitivity = float(cf.get_value("input", "sensitivity", sensitivity))
	invert_y = bool(cf.get_value("input", "invert_y", invert_y))
	fov = float(cf.get_value("video", "fov", fov))
	renderer_fallback = bool(cf.get_value("video", "renderer_fallback", renderer_fallback))
	use_model_characters = bool(cf.get_value("video", "use_model_characters", use_model_characters))
	resolution_x = int(cf.get_value("video", "resolution_x", resolution_x))
	resolution_y = int(cf.get_value("video", "resolution_y", resolution_y))
	window_mode = String(cf.get_value("video", "window_mode", window_mode))
	master_volume = float(cf.get_value("audio", "master_volume", master_volume))
	voice_volume = float(cf.get_value("audio", "voice_volume", voice_volume))
	output_device = String(cf.get_value("audio", "output_device", output_device))
	input_device = String(cf.get_value("audio", "input_device", input_device))
	bindings = {}
	if cf.has_section("bindings"):
		for key in cf.get_section_keys("bindings"):
			var val = cf.get_value("bindings", key)
			if typeof(val) == TYPE_DICTIONARY:
				bindings[key] = val
