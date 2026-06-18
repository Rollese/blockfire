class_name AiTuning
extends RefCounted
## Loads data/ai_tuning.json (difficulty profiles + utility weights). Data-only; no logic.

static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[ai] cannot open tuning %s" % path)
		return {}
	var txt := f.get_as_text()
	var parsed = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}
