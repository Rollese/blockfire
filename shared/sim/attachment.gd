class_name Attachment
extends RefCounted
## Data-driven weapon attachment catalog (loadout-time only; no mid-match swap, spec §"Weapon
## attachments"). Three slots — optic/barrel/underbarrel. Each attachment carries stat
## MULTIPLIERS applied to the base weapon record before hit resolution (Weapon.effective_def).
## Missing multipliers default neutral (1.0 / false). The server refuses to start on an invalid
## catalog (same contract as PieceCatalog). Parsed from data/attachments.json.

const SLOTS := ["optic", "barrel", "underbarrel"]

# id -> {slot, spread_mult, recoil_mult, range_mult, move_spread_mult, prone_spread_zero}
var _by_id: Dictionary = {}

func multipliers(selection: Dictionary) -> Dictionary:
	# Aggregate the chosen attachment per slot into one multiplier dict (neutral baseline).
	var m := {"spread_mult": 1.0, "recoil_mult": 1.0, "range_mult": 1.0,
		"move_spread_mult": 1.0, "prone_spread_zero": false}
	for slot in SLOTS:
		var aid := String(selection.get(slot, ""))
		if aid == "" or not _by_id.has(aid):
			continue
		var a: Dictionary = _by_id[aid]
		m["spread_mult"] *= float(a["spread_mult"])
		m["recoil_mult"] *= float(a["recoil_mult"])
		m["range_mult"] *= float(a["range_mult"])
		m["move_spread_mult"] *= float(a["move_spread_mult"])
		if bool(a["prone_spread_zero"]):
			m["prone_spread_zero"] = true
	return m

## The slot ("optic"/"barrel"/"underbarrel") an attachment id belongs to, or "" if unknown.
## Public read accessor over the private catalog so loadout sanitize can validate slot membership.
func slot_of(id: String) -> String:
	var a = _by_id.get(id, null)
	return String(a["slot"]) if a != null else ""

func has_id(id: String) -> bool:
	return _by_id.has(id)

static func from_json_string(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "catalog": null, "error": "root is not an object"}
	return from_dict(data)

static func from_dict(data: Dictionary) -> Dictionary:
	var c := Attachment.new()
	var raw = data.get("attachments", [])
	if typeof(raw) != TYPE_ARRAY or raw.is_empty():
		return {"ok": false, "catalog": null, "error": "attachments must be a non-empty array"}
	for a in raw:
		if not (a is Dictionary):
			return {"ok": false, "catalog": null, "error": "each attachment must be an object"}
		var id := String(a.get("id", ""))
		if id == "" or c._by_id.has(id):
			return {"ok": false, "catalog": null, "error": "attachment id must be non-empty and unique"}
		var slot := String(a.get("slot", ""))
		if not SLOTS.has(slot):
			return {"ok": false, "catalog": null, "error": "slot must be one of %s" % str(SLOTS)}
		c._by_id[id] = {
			"slot": slot,
			"spread_mult": float(a.get("spread_mult", 1.0)),
			"recoil_mult": float(a.get("recoil_mult", 1.0)),
			"range_mult": float(a.get("range_mult", 1.0)),
			"move_spread_mult": float(a.get("move_spread_mult", 1.0)),
			"prone_spread_zero": bool(a.get("prone_spread_zero", false)),
		}
	return {"ok": true, "catalog": c, "error": ""}

static func load_file(path: String) -> Attachment:
	if not FileAccess.file_exists(path):
		push_error("[attachments] not found: %s" % path)
		return null
	var res := from_json_string(FileAccess.get_file_as_string(path))
	if not res["ok"]:
		push_error("[attachments] invalid %s: %s" % [path, res["error"]])
		return null
	return res["catalog"]
