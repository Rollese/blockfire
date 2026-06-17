class_name ClientSettings
extends RefCounted
## Player settings persisted to a ConfigFile. Defaults are BattleBit-ish; renderer toggle is read
## at boot (ADR-0005).

var sensitivity: float = 0.25
var fov: float = 90.0
var master_volume: float = 0.8
var invert_y: bool = false
var renderer_fallback: bool = false   # true -> request GL Compatibility

func save_to(path: String = "user://settings.cfg") -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "sensitivity", sensitivity)
	cf.set_value("input", "invert_y", invert_y)
	cf.set_value("video", "fov", fov)
	cf.set_value("video", "renderer_fallback", renderer_fallback)
	cf.set_value("audio", "master_volume", master_volume)
	cf.save(path)

func load_from(path: String = "user://settings.cfg") -> void:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return   # keep defaults
	sensitivity = float(cf.get_value("input", "sensitivity", sensitivity))
	invert_y = bool(cf.get_value("input", "invert_y", invert_y))
	fov = float(cf.get_value("video", "fov", fov))
	renderer_fallback = bool(cf.get_value("video", "renderer_fallback", renderer_fallback))
	master_volume = float(cf.get_value("audio", "master_volume", master_volume))
