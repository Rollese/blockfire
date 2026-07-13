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
var ssao_enabled: bool = true   # SSAO on by default; toggle in settings
var volumetric_fog_enabled: bool = true   # volumetric fog on by default; toggle in settings
var use_model_characters: bool = true   # default ON: imported GLB soldier; set false for procedural CharacterKit
var player_name: String = "Player"
var resolution_x: int = 1920
var resolution_y: int = 1080
var window_mode: String = "windowed"   # windowed | fullscreen | borderless
var output_device: String = ""         # "" = system default
var input_device: String = ""          # "" = system default
## action -> {type, physical_keycode|button_index} — see InputBindings
var bindings: Dictionary = {}
## Per-class loadout memory (M19 loadout-UI redesign): class-id STRING -> loadout dict. Persisted so
## a player's class choices stick across matches AND servers. Written on every class-select edit; the
## deploy screen seeds from it. Stored/returned as DEEP copies so no caller aliases the live store.
var class_loadouts: Dictionary = {}

func save_to(path: String = "user://settings.cfg") -> void:
	var cf := ConfigFile.new()
	cf.set_value("player", "name", player_name)
	cf.set_value("input", "sensitivity", sensitivity)
	cf.set_value("input", "invert_y", invert_y)
	cf.set_value("video", "fov", fov)
	cf.set_value("video", "renderer_fallback", renderer_fallback)
	cf.set_value("video", "ssao_enabled", ssao_enabled)
	cf.set_value("video", "volumetric_fog_enabled", volumetric_fog_enabled)
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
	# Per-class loadouts: one key per class, value a JSON-encoded string (ConfigFile-safe, mirrors the
	# bindings dict precedent above — nested dicts survive a round trip as text).
	for cls_key in class_loadouts:
		cf.set_value("loadouts", String(cls_key), JSON.stringify(class_loadouts[cls_key]))
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
	ssao_enabled = bool(cf.get_value("video", "ssao_enabled", ssao_enabled))
	volumetric_fog_enabled = bool(cf.get_value("video", "volumetric_fog_enabled", volumetric_fog_enabled))
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
	# Per-class loadouts: JSON-decode each key; skip malformed/non-string entries (never crash).
	class_loadouts = {}
	if cf.has_section("loadouts"):
		for key in cf.get_section_keys("loadouts"):
			var raw = cf.get_value("loadouts", key)
			if typeof(raw) != TYPE_STRING:
				continue
			var parsed = JSON.parse_string(raw)
			if typeof(parsed) == TYPE_DICTIONARY:
				class_loadouts[String(key)] = parsed

## The stored loadout for a class (DEEP copy), or {} if none is remembered yet. Keyed by the class
## enum int, stringified so it survives the ConfigFile round trip.
func get_class_loadout(cls_id) -> Dictionary:
	var v = class_loadouts.get(str(int(cls_id)), null)
	if typeof(v) == TYPE_DICTIONARY:
		return (v as Dictionary).duplicate(true)
	return {}

## Remember `cfg` (a DEEP copy) as this class's loadout. Caller keeps ownership of its dict.
func set_class_loadout(cls_id, cfg: Dictionary) -> void:
	class_loadouts[str(int(cls_id))] = cfg.duplicate(true)
