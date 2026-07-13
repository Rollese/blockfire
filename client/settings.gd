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
var glow_enabled: bool = true   # bloom/glow on by default; single biggest per-pixel cost on weak iGPUs
var sun_shadow_enabled: bool = true   # DirectionalLight3D shadow on by default
var render_scale: float = 1.0   # viewport 3D render scale; clamped [0.5, 1.0], BILINEAR upscale
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
	cf.set_value("video", "glow_enabled", glow_enabled)
	cf.set_value("video", "sun_shadow_enabled", sun_shadow_enabled)
	cf.set_value("video", "render_scale", render_scale)
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
	glow_enabled = bool(cf.get_value("video", "glow_enabled", glow_enabled))
	sun_shadow_enabled = bool(cf.get_value("video", "sun_shadow_enabled", sun_shadow_enabled))
	render_scale = clampf(float(cf.get_value("video", "render_scale", render_scale)), 0.5, 1.0)
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

# ---- graphics-quality presets ----------------------------------------------
## Ordered preset ids, cheapest last. "performance" is the recommended pick for weak/integrated GPUs.
const QUALITY_PRESETS := ["high", "balanced", "performance", "potato"]

## Pure mapper: preset name -> the video-settings bundle it implies. Unknown names fall back to
## "high" (the default look) so callers never get a partial/empty dict. Per-effect iGPU costs that
## motivate the tiers: glow ~4.3ms, ssao+volfog ~4.1ms, sun shadow ~3.0ms, render-scale ~1.8ms.
static func quality_preset(name: String) -> Dictionary:
	match name:
		"balanced":
			# Drop the SSAO+volfog pair (~4.1ms) but keep glow and shadows for the full-fat look.
			return {"ssao_enabled": false, "volumetric_fog_enabled": false,
				"glow_enabled": true, "sun_shadow_enabled": true, "render_scale": 1.0}
		"performance":
			# Also cut glow (~4.3ms, the single biggest cost) — recommended for integrated GPUs.
			return {"ssao_enabled": false, "volumetric_fog_enabled": false,
				"glow_enabled": false, "sun_shadow_enabled": true, "render_scale": 1.0}
		"potato":
			# All post off, no sun shadow (~3.0ms), and render at 0.8x (~1.4ms) — last-resort floor.
			return {"ssao_enabled": false, "volumetric_fog_enabled": false,
				"glow_enabled": false, "sun_shadow_enabled": false, "render_scale": 0.8}
		_:
			# "high" and any unknown name: everything on, full resolution (unchanged desktop look).
			return {"ssao_enabled": true, "volumetric_fog_enabled": true,
				"glow_enabled": true, "sun_shadow_enabled": true, "render_scale": 1.0}

## Mutate this settings object's video fields to match the named preset. Unknown -> "high" (see
## quality_preset). Caller still persists/applies as usual (save_to + settings_applied).
func apply_preset(name: String) -> void:
	var b := quality_preset(name)
	ssao_enabled = bool(b["ssao_enabled"])
	volumetric_fog_enabled = bool(b["volumetric_fog_enabled"])
	glow_enabled = bool(b["glow_enabled"])
	sun_shadow_enabled = bool(b["sun_shadow_enabled"])
	render_scale = clampf(float(b["render_scale"]), 0.5, 1.0)
