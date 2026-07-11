class_name StatsBuffer
extends RefCounted

# Accumulates per-player / per-weapon stats and raw events for one match, then
# serializes to the P1-A ingest contract. Pure logic — no HTTP, no scene tree.

var match_id: String = ""
var server_id: String = ""
var map_name: String = ""
var mode: String = ""

var _players: Dictionary = {}   # id:int -> accumulator Dictionary
var _events: Array = []         # pending event Dictionaries (flushed in batches)
var _batch_seq: int = 0
var _winner_team: int = -1

func begin_match(p_match_id: String, p_server_id: String, p_map: String, p_mode: String) -> void:
	match_id = p_match_id
	server_id = p_server_id
	map_name = p_map
	mode = p_mode
	_players.clear()
	_events.clear()
	_batch_seq = 0
	_winner_team = -1

func register_player(id: int, name: String, steam_id: int, team: int) -> void:
	if _players.has(id):
		var p: Dictionary = _players[id]
		p["name"] = name
		p["team"] = team
		if steam_id != 0:
			p["steam_id"] = steam_id
		return
	_players[id] = {
		"name": name, "steam_id": steam_id, "team": team,
		"kills": 0, "deaths": 0, "assists": 0, "downs": 0, "revives": 0,
		"captures": 0, "neutralizes": 0, "xp_earned": 0,
		"longest_kill_m": 0.0, "playtime_s": 0, "result": "",
		"weapons": {},   # weapon_key -> {shots,hits,kills,headshots,damage,time_used_s}
	}

func _ensure(id: int) -> Dictionary:
	if not _players.has(id):
		register_player(id, "id:%d" % id, 0, -1)
	return _players[id]

func _wslot(id: int, wkey: String) -> Dictionary:
	var p := _ensure(id)
	var weapons: Dictionary = p["weapons"]
	if not weapons.has(wkey):
		weapons[wkey] = {"shots": 0, "hits": 0, "kills": 0, "headshots": 0,
			"damage": 0, "time_used_s": 0}
	return weapons[wkey]

func _key(id: int) -> String:
	var p := _ensure(id)
	if int(p["steam_id"]) != 0:
		return "steam:%d" % int(p["steam_id"])
	return "name:%s" % String(p["name"])

func record_kill(killer_id: int, victim_id: int, wkey: String, headshot: bool,
		distance_m: float, tick: int, killer_pos: Vector3, victim_pos: Vector3) -> void:
	var killer := _ensure(killer_id)
	var victim := _ensure(victim_id)
	if killer_id != victim_id:
		killer["kills"] = int(killer["kills"]) + 1
		var w := _wslot(killer_id, wkey)
		w["kills"] = int(w["kills"]) + 1
		if distance_m > float(killer["longest_kill_m"]):
			killer["longest_kill_m"] = distance_m
	victim["deaths"] = int(victim["deaths"]) + 1
	_events.append({
		"tick": tick, "type": "kill",
		"actor": _key(killer_id), "target": _key(victim_id), "weapon_id": wkey,
		"payload": {
			"distance_m": distance_m, "hitzone": ("head" if headshot else "body"),
			"actor_pos": [killer_pos.x, killer_pos.y, killer_pos.z],
			"target_pos": [victim_pos.x, victim_pos.y, victim_pos.z],
		},
	})

func record_shot(shooter_id: int, wkey: String) -> void:
	var w := _wslot(shooter_id, wkey)
	w["shots"] = int(w["shots"]) + 1

func record_hit(shooter_id: int, wkey: String, headshot: bool) -> void:
	var w := _wslot(shooter_id, wkey)
	w["hits"] = int(w["hits"]) + 1
	if headshot:
		w["headshots"] = int(w["headshots"]) + 1

func record_damage(attacker_id: int, wkey: String, dmg: int) -> void:
	var w := _wslot(attacker_id, wkey)
	w["damage"] = int(w["damage"]) + dmg

func record_down(victim_id: int) -> void:
	var p := _ensure(victim_id)
	p["downs"] = int(p["downs"]) + 1

func record_revive(rescuer_id: int) -> void:
	var p := _ensure(rescuer_id)
	p["revives"] = int(p["revives"]) + 1

func set_results(winner_team: int) -> void:
	_winner_team = winner_team
	for id in _players:
		var p: Dictionary = _players[id]
		p["result"] = "win" if int(p["team"]) == winner_team else "loss"

func take_event_batch() -> Dictionary:
	if _events.is_empty():
		return {}
	var batch := {"match_id": match_id, "batch_seq": _batch_seq, "events": _events}
	_batch_seq += 1
	_events = []
	return batch

func build_match_report(started_at: String, ended_at: String) -> Dictionary:
	var players_arr: Array = []
	for id in _players:
		var p: Dictionary = _players[id]
		var weapons_arr: Array = []
		for wkey in p["weapons"]:
			var w: Dictionary = p["weapons"][wkey]
			weapons_arr.append({
				"weapon_id": wkey, "shots": w["shots"], "hits": w["hits"],
				"kills": w["kills"], "headshots": w["headshots"],
				"damage": w["damage"], "time_used_s": w["time_used_s"],
			})
		var sid: int = int(p["steam_id"])
		players_arr.append({
			"name": p["name"], "steam_id": (sid if sid != 0 else null),
			"team": "team_%d" % int(p["team"]),
			"kills": p["kills"], "deaths": p["deaths"], "assists": p["assists"],
			"downs": p["downs"], "revives": p["revives"],
			"captures": p["captures"], "neutralizes": p["neutralizes"],
			"xp_earned": p["xp_earned"], "longest_kill_m": p["longest_kill_m"],
			"playtime_s": p["playtime_s"], "result": p["result"],
			"weapons": weapons_arr,
		})
	return {
		"report_version": 1,
		"match": {
			"match_id": match_id, "server_id": server_id, "map": map_name,
			"mode": mode, "started_at": started_at, "ended_at": ended_at,
			"winner": ("team_%d" % _winner_team if _winner_team >= 0 else null),
		},
		"players": players_arr,
	}
