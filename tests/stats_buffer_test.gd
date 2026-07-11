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

func test_shots_hits_headshots_and_damage_accumulate() -> void:
	var b := _seed()
	for i in range(100):
		b.record_shot(1, "ar")
	for i in range(40):
		b.record_hit(1, "ar", i < 5)   # 5 of the hits are headshots
	b.record_damage(1, "ar", 30)
	b.record_damage(1, "ar", 20)
	var a := _player(b.build_match_report("s", "e"), "name:Bot_A")
	var w := _weapon(a, "ar")
	assert_eq(w["shots"], 100, "shots")
	assert_eq(w["hits"], 40, "hits")
	assert_eq(w["headshots"], 5, "headshots")
	assert_eq(w["damage"], 50, "summed damage")
	# The P1 gate's balancing query — hit rate:
	assert_true(abs(float(w["hits"]) / float(w["shots"]) - 0.40) < 1e-6, "hit rate 0.40")

func test_take_event_batch_increments_seq_and_clears() -> void:
	var b := _seed()
	b.record_kill(1, 2, "ar", true, 10.0, 1, Vector3.ZERO, Vector3.ZERO)
	var batch0 := b.take_event_batch()
	assert_eq(batch0["batch_seq"], 0, "first batch seq 0")
	assert_eq(batch0["events"].size(), 1, "one event")
	assert_eq(batch0["match_id"], "m1", "match id present")
	var empty := b.take_event_batch()
	assert_true(empty.is_empty(), "no pending events -> empty dict")
	b.record_kill(1, 2, "ar", false, 20.0, 2, Vector3.ZERO, Vector3.ZERO)
	var batch1 := b.take_event_batch()
	assert_eq(batch1["batch_seq"], 1, "second batch seq 1")

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
