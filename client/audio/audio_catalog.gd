class_name AudioCatalog
extends RefCounted
## Pure loader/validator for data/sounds.json. Maps event type -> sound def. Validation failures are
## collected in `errors` (reported, not silently dropped), mirroring the sim catalogs.

const _REQUIRED := ["type", "bus", "priority", "gain_db", "unit_size", "max_distance", "cutoff_hz", "stream"]

var _by_type: Dictionary = {}
var _buses: Array = ["SFX", "UI", "Listener"]
var errors: Array[String] = []

func load_from(path: String) -> void:
	_by_type = {}
	errors = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		errors.append("cannot open %s" % path)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s is not a JSON object" % path)
		return
	var data: Dictionary = parsed
	if data.has("buses"):
		_buses = data["buses"]
	var sounds: Array = data.get("sounds", [])
	errors = validate(sounds, _buses)
	for s in sounds:
		if s is Dictionary and s.has("type"):
			_by_type[String(s["type"])] = s

## Pure: return a list of error strings for malformed entries. Empty == all valid.
func validate(sounds: Array, buses: Array) -> Array[String]:
	var errs: Array[String] = []
	for s in sounds:
		if not (s is Dictionary):
			errs.append("entry is not an object")
			continue
		var d: Dictionary = s
		var tag := String(d.get("type", "?"))
		for k in _REQUIRED:
			if not d.has(k):
				errs.append("%s missing key %s" % [tag, k])
		if d.has("priority") and (int(d["priority"]) < 0 or int(d["priority"]) > 3):
			errs.append("%s priority out of range 0..3" % tag)
		if d.has("unit_size") and float(d["unit_size"]) <= 0.0:
			errs.append("%s unit_size must be > 0" % tag)
		if d.has("max_distance") and float(d["max_distance"]) < 0.0:
			errs.append("%s max_distance must be >= 0" % tag)
		if d.has("bus") and not buses.has(String(d["bus"])):
			errs.append("%s unknown bus %s" % [tag, String(d["bus"])])
	return errs

func def_for(event_type: String) -> Dictionary:
	if _by_type.has(event_type):
		return _by_type[event_type]
	return {"type": event_type, "bus": "SFX", "priority": 1, "gain_db": -6.0,
		"unit_size": 4.0, "max_distance": 80.0, "cutoff_hz": AudioMix.OPEN_CUTOFF_HZ, "stream": ""}

func is_spatial(event_type: String) -> bool:
	return float(def_for(event_type)["max_distance"]) > 0.0
