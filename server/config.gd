class_name ServerConfig
extends RefCounted
## M8-P3: server config file (data/server_config.json) + CLI merge. Pure — no engine
## state; server_main applies the resolved dict. Spec: docs/specs/server-ops.md.
## tick_rate is deliberately NOT a key: SimLoop.DT is a compile-time sim constant.

const DEFAULT_PATH := "res://data/server_config.json"

## Accepted file keys -> required decoded JSON type (numbers arrive as TYPE_FLOAT).
const FILE_KEYS := {
	"port": TYPE_FLOAT, "max_players": TYPE_FLOAT, "tickets": TYPE_FLOAT,
	"time_limit": TYPE_FLOAT, "maps": TYPE_ARRAY,
	"degrade_high_ms": TYPE_FLOAT, "degrade_low_ms": TYPE_FLOAT,
}

## {ok: bool, config: Dictionary, error: String} — the repo catalog-load contract.
## A missing file at any path is ok+empty (the config file is optional); malformed
## content is an error (an operator wrote it and got it wrong — fail loud).
static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "config": {}, "error": ""}
	var text := FileAccess.get_file_as_string(path)
	# JSON.new().parse() (not the static JSON.parse_string()) returns an error code
	# without also engine-logging an ERROR — parse_string's internal ERR_PRINT would
	# trip the test harness's runtime-SCRIPT-ERROR tally for a case we handle here.
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "config": {}, "error": "malformed JSON in %s: %s" % [path, json.get_error_message()]}
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "config": {}, "error": "config root must be an object in %s" % path}
	var out := {}
	for key in (parsed as Dictionary):
		if not FILE_KEYS.has(key):
			push_warning("[config] unknown key '%s' in %s (ignored)" % [key, path])
			continue
		if typeof(parsed[key]) != FILE_KEYS[key]:
			push_warning("[config] key '%s' has wrong type in %s (ignored)" % [key, path])
			continue
		out[key] = parsed[key]
	if out.has("maps"):
		var maps: Array = []
		for m in (out["maps"] as Array):
			if typeof(m) == TYPE_STRING:
				maps.append(m)
			else:
				push_warning("[config] non-string maps entry %s in %s (dropped)" % [str(m), path])
		out["maps"] = maps
	return {"ok": true, "config": out, "error": ""}

## Effective settings: CLI (bootstrap args, string values) > file > built-in default.
## Pure. Keys out: port, max_players, tickets, time_limit, maps, rotate,
## degrade_high_ms, degrade_low_ms (-1.0 = "not set, keep server default").
static func resolve(file_cfg: Dictionary, cli: Dictionary) -> Dictionary:
	var e := {
		"port": int(cli["port"]) if cli.has("port") else int(file_cfg.get("port", 27015.0)),
		"max_players": int(file_cfg.get("max_players", 128.0)),
		"tickets": int(cli["tickets"]) if cli.has("tickets") else int(file_cfg.get("tickets", -1.0)),
		"time_limit": float(cli["time-limit"]) if cli.has("time-limit") else float(file_cfg.get("time_limit", -1.0)),
		"degrade_high_ms": float(cli["degrade-high-ms"]) if cli.has("degrade-high-ms") else float(file_cfg.get("degrade_high_ms", -1.0)),
		"degrade_low_ms": float(cli["degrade-low-ms"]) if cli.has("degrade-low-ms") else float(file_cfg.get("degrade_low_ms", -1.0)),
	}
	if cli.has("map"):
		e["maps"] = [String(cli["map"])]
		e["rotate"] = false
	else:
		var maps: Array = file_cfg.get("maps", [])
		e["maps"] = maps
		e["rotate"] = not maps.is_empty()
	return e

static func next_map_index(current: int, count: int) -> int:
	return (current + 1) % count if count > 0 else 0
