extends TestCase

const Buffer := preload("res://server/stats/stats_buffer.gd")

func _seed() -> Buffer:
	var b: Buffer = Buffer.new()
	b.begin_match("m1", "game2-dev-1", "dust", "conquest")
	b.register_player(1, "Bot_A", 0, 0)
	b.register_player(2, "Bot_B", 0, 1)
	return b

func test_kill_updates_killer_victim_and_weapon_counters() -> void:
	var b := _seed()
	b.record_kill(1, 2, "ar", false, 142.3, 1234, Vector3.ZERO, Vector3(140, 0, 0))
	var report := b.build_match_report("2026-07-11T10:00:00Z", "2026-07-11T10:20:00Z")
	var a := _player(report, "name:Bot_A")
	var v := _player(report, "name:Bot_B")
	assert_eq(a["kills"], 1, "killer kills")
	assert_eq(v["deaths"], 1, "victim deaths")
	assert_eq(a["longest_kill_m"], 142.3, "longest kill recorded")
	assert_eq(_weapon(a, "ar")["kills"], 1, "per-weapon kills")

func test_longest_kill_keeps_the_max() -> void:
	var b := _seed()
	b.record_kill(1, 2, "ar", false, 50.0, 1, Vector3.ZERO, Vector3.ZERO)
	b.record_kill(1, 2, "ar", false, 200.0, 2, Vector3.ZERO, Vector3.ZERO)
	b.record_kill(1, 2, "ar", false, 120.0, 3, Vector3.ZERO, Vector3.ZERO)
	var a := _player(b.build_match_report("s", "e"), "name:Bot_A")
	assert_eq(a["longest_kill_m"], 200.0, "max distance kept")

func test_player_key_uses_steam_id_when_present() -> void:
	var b: Buffer = Buffer.new()
	b.begin_match("m1", "s", "dust", "conquest")
	b.register_player(1, "Someone", 76561198000000000, 0)
	var report := b.build_match_report("s", "e")
	assert_eq(report["players"][0]["steam_id"], 76561198000000000, "steam id passed through")

# --- helpers ---
func _player(report: Dictionary, key: String) -> Dictionary:
	for p in report["players"]:
		var pk := ("steam:%d" % p["steam_id"]) if p["steam_id"] != null else ("name:%s" % p["name"])
		if pk == key:
			return p
	return {}

func _weapon(pl: Dictionary, wid: String) -> Dictionary:
	for w in pl["weapons"]:
		if w["weapon_id"] == wid:
			return w
	return {}
