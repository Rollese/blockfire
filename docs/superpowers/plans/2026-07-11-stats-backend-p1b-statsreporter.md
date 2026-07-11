# Stats Backend P1-B — Game-Server StatsReporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a server-only `StatsReporter` to the Godot dedicated server that accumulates per-player/per-weapon counters and per-kill events during a match and POSTs them to the P1-A ingest API, with a local NDJSON fallback so a backend outage loses no data.

**Architecture:** Three GDScript units mirroring the backend's logic/transport split: `StatsBuffer` (pure accumulation + serialization, fully unit-tested), `StatsSpool` (NDJSON fallback file, unit-tested), and `StatsReporter` (a `Node` owning an `HTTPRequest` child that flushes the buffer and drains the spool). The server taps its two authoritative funnels — `_kill_pawn` and `_apply_pawn_damage` — plus shot/hit sites in `fire.gd`, and flushes once per second alongside the existing telemetry window.

**Tech Stack:** Godot 4.6 GDScript, `HTTPRequest`, `JSON`, the project's `TestCase` harness.

**Depends on:** P1-A (`2026-07-11-stats-backend-p1a-ingest-api.md`) — its `/ingest/events` and `/ingest/match` contract and `player_key` format (`steam:<id>` | `name:<name>`). Bring the P1-A backend up (`cd backend && docker compose up`) for the Task 9 live gate.

**Key codebase facts (verified):** the server is `server/server_main.gd` (`extends Node`, no `class_name`, no autoloads); `_stats` is already taken by `ServerStats` — the reporter is named **`_stats_reporter`**. Authoritative kill funnel `_kill_pawn(vid, victim, killer_id, weapon_id, headshot, source)` at `server_main.gd:690`; damage funnel `_apply_pawn_damage(...)` at `:752`; shot counter at `fire.gd:127`, hit at `fire.gd:295–302`; match-over hook at `server_main.gd:887`; per-second telemetry flush at `_log_telemetry` (`:2438`, called `:496`); player store `_clients[id]` (`:1177`, has `name`/`team`/`kills`); `weapon_id` is an int enum (`shared/sim/weapon.gd`, `Weapon.get_def(id)["name"]`); CLI parsed into `configure(args)` (`:176`, cf. `args.has("fast-nades")` at `:196`).

---

## File structure

```
server/stats/
  stats_buffer.gd      class_name StatsBuffer   (RefCounted) — accumulate + serialize
  stats_spool.gd       class_name StatsSpool    (RefCounted) — NDJSON fallback file
  stats_reporter.gd    class_name StatsReporter (Node)       — buffer + spool + HTTPRequest
tests/
  stats_buffer_test.gd
  stats_spool_test.gd
```
Modified: `server/server_main.gd` (config, instantiate, taps, flush), `server/fire.gd` (shot/hit taps).

**Run tests:** `godot --headless --path . -- --test --filter=stats` (expects `TESTS: N run, 0 failed`).

---

### Task 1: StatsBuffer — match/player setup + kill accumulation

**Files:**
- Create: `server/stats/stats_buffer.gd`
- Test: `tests/stats_buffer_test.gd`

- [ ] **Step 1: Write the failing test** `tests/stats_buffer_test.gd`

```gdscript
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=stats_buffer`
Expected: FAIL — cannot load `stats_buffer.gd`.

- [ ] **Step 3: Write `server/stats/stats_buffer.gd`**

```gdscript
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=stats_buffer`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_buffer.gd tests/stats_buffer_test.gd
git commit -m "feat(stats): StatsBuffer kill accumulation + match report"
```

---

### Task 2: StatsBuffer — shots/hits/damage counters + hit-rate

**Files:**
- Modify: `server/stats/stats_buffer.gd`, `tests/stats_buffer_test.gd`

- [ ] **Step 1: Add failing tests** (append to `tests/stats_buffer_test.gd`)

```gdscript
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=stats_buffer`
Expected: FAIL — `record_shot`/`record_hit`/`record_damage` not found.

- [ ] **Step 3: Add methods to `server/stats/stats_buffer.gd`**

```gdscript
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=stats_buffer`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_buffer.gd tests/stats_buffer_test.gd
git commit -m "feat(stats): StatsBuffer shot/hit/damage counters"
```

---

### Task 3: StatsBuffer — event batches (batch_seq, take_event_batch)

**Files:**
- Modify: `server/stats/stats_buffer.gd`, `tests/stats_buffer_test.gd`

- [ ] **Step 1: Add failing tests**

```gdscript
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=stats_buffer`
Expected: FAIL — `take_event_batch` not found.

- [ ] **Step 3: Add to `server/stats/stats_buffer.gd`**

```gdscript
func take_event_batch() -> Dictionary:
	if _events.is_empty():
		return {}
	var batch := {"match_id": match_id, "batch_seq": _batch_seq, "events": _events}
	_batch_seq += 1
	_events = []
	return batch
```

- [ ] **Step 4: Run test to verify it passes** — `godot --headless --path . -- --test --filter=stats_buffer` → PASS.

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_buffer.gd tests/stats_buffer_test.gd
git commit -m "feat(stats): StatsBuffer event batching"
```

---

### Task 4: StatsBuffer — results, downs/revives, and win/loss

**Files:**
- Modify: `server/stats/stats_buffer.gd`, `tests/stats_buffer_test.gd`

- [ ] **Step 1: Add failing tests**

```gdscript
func test_end_match_sets_win_loss_by_team() -> void:
	var b := _seed()  # Bot_A team 0, Bot_B team 1
	b.record_down(2)
	b.record_revive(1)
	b.set_results(0)  # team 0 wins
	var report := b.build_match_report("s", "e")
	assert_eq(report["match"]["winner"], "team_0", "winner serialized")
	assert_eq(_player(report, "name:Bot_A")["result"], "win", "team 0 win")
	assert_eq(_player(report, "name:Bot_B")["result"], "loss", "team 1 loss")
	assert_eq(_player(report, "name:Bot_B")["downs"], 1, "down counted")
	assert_eq(_player(report, "name:Bot_A")["revives"], 1, "revive counted")
```

- [ ] **Step 2: Run test to verify it fails** — expect `record_down`/`record_revive`/`set_results` not found.

- [ ] **Step 3: Add to `server/stats/stats_buffer.gd`**

```gdscript
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
```

- [ ] **Step 4: Run test to verify it passes** — PASS.

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_buffer.gd tests/stats_buffer_test.gd
git commit -m "feat(stats): StatsBuffer results + downs/revives"
```

---

### Task 5: StatsSpool — NDJSON fallback file

**Files:**
- Create: `server/stats/stats_spool.gd`
- Test: `tests/stats_spool_test.gd`

- [ ] **Step 1: Write the failing test** `tests/stats_spool_test.gd`

```gdscript
extends TestCase

const Spool := preload("res://server/stats/stats_spool.gd")

const PATH := "user://test_stats_spool.ndjson"

func teardown() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))

func test_append_and_read_all_roundtrips() -> void:
	var s: Spool = Spool.new(PATH)
	s.clear()
	s.append({"path": "/ingest/match", "body": {"match_id": "m1"}})
	s.append({"path": "/ingest/events", "body": {"batch_seq": 0}})
	var rows := s.read_all()
	assert_eq(rows.size(), 2, "two spooled rows")
	assert_eq(rows[0]["path"], "/ingest/match", "first row path")
	assert_eq(rows[1]["body"]["batch_seq"], 0, "second row body")

func test_clear_empties_the_spool() -> void:
	var s: Spool = Spool.new(PATH)
	s.append({"path": "/x", "body": {}})
	s.clear()
	assert_eq(s.read_all().size(), 0, "cleared")
```

- [ ] **Step 2: Run test to verify it fails** — cannot load `stats_spool.gd`.

- [ ] **Step 3: Write `server/stats/stats_spool.gd`**

```gdscript
class_name StatsSpool
extends RefCounted

# Append-only NDJSON fallback: when a POST fails, its {path, body} is spooled
# here and re-sent on the next successful drain. One JSON object per line.

var _path: String

func _init(path: String = "user://stats_spool.ndjson") -> void:
	_path = path

func append(record: Dictionary) -> void:
	var f := FileAccess.open(_path, FileAccess.READ_WRITE) if FileAccess.file_exists(_path) \
		else FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_error("StatsSpool: cannot open %s" % _path)
		return
	f.seek_end()
	f.store_line(JSON.stringify(record))
	f.close()

func read_all() -> Array:
	var out: Array = []
	if not FileAccess.file_exists(_path):
		return out
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges().is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed != null:
			out.append(parsed)
	f.close()
	return out

func clear() -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f != null:
		f.close()

func is_empty() -> bool:
	return read_all().is_empty()
```

- [ ] **Step 4: Run test to verify it passes** — `godot --headless --path . -- --test --filter=stats_spool` → PASS.

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_spool.gd tests/stats_spool_test.gd
git commit -m "feat(stats): StatsSpool NDJSON fallback"
```

---

### Task 6: StatsReporter node — weapon_key + HTTP POST + spool fallback

**Files:**
- Create: `server/stats/stats_reporter.gd`
- Test: `tests/stats_reporter_test.gd`

`HTTPRequest` is async and awkward to unit-test headless, so this task unit-tests only the pure pieces (`weapon_key`, spool-on-failure decision); the real HTTP path is exercised by the Task 9 live gate.

- [ ] **Step 1: Write the failing test** `tests/stats_reporter_test.gd`

```gdscript
extends TestCase

const Reporter := preload("res://server/stats/stats_reporter.gd")

func test_weapon_key_maps_enum_to_lowercase_label() -> void:
	# Weapon.AR == 0; get_def(0)["name"] == "AR"
	assert_eq(Reporter.weapon_key(0), "ar", "AR enum -> 'ar'")

func test_weapon_key_unknown_falls_back() -> void:
	assert_eq(Reporter.weapon_key(9999), "ar", "unknown id -> Weapon fallback name")
```

Note: `Weapon.get_def` falls back to the AR def for unknown ids (`shared/sim/weapon.gd:40`), so `weapon_key(9999)` resolves to `"ar"`. Under the weapon-variants worktree this becomes the variant `key`; update this test then.

- [ ] **Step 2: Run test to verify it fails** — cannot load `stats_reporter.gd`.

- [ ] **Step 3: Write `server/stats/stats_reporter.gd`**

```gdscript
class_name StatsReporter
extends Node

# Server-only. Owns a StatsBuffer + StatsSpool + an HTTPRequest child. Flushes
# event batches (~1 Hz) and the final match report to the P1-A ingest API;
# spools failed POSTs to NDJSON and drains them on the next success.

const Buffer := preload("res://server/stats/stats_buffer.gd")
const Spool := preload("res://server/stats/stats_spool.gd")

var buffer: Buffer = Buffer.new()

var _endpoint: String = ""
var _token: String = ""
var _spool: Spool = Spool.new()
var _http: HTTPRequest
var _inflight: bool = false

static func weapon_key(weapon_id: int) -> String:
	return String(Weapon.get_def(weapon_id).get("name", "unknown")).to_lower()

func configure(endpoint: String, token: String, spool_path: String = "user://stats_spool.ndjson") -> void:
	_endpoint = endpoint.rstrip("/")
	_token = token
	_spool = Spool.new(spool_path)

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

# --- serialization passthroughs used by server_main taps ---
func begin_match(match_id: String, server_id: String, map_name: String, mode: String) -> void:
	buffer.begin_match(match_id, server_id, map_name, mode)

# --- flushing ---
func flush_events() -> void:
	var batch := buffer.take_event_batch()
	if batch.is_empty():
		return
	_post("/ingest/events", batch)

func end_match(winner_team: int, elapsed_s: int, started_at: String, ended_at: String) -> void:
	buffer.set_results(winner_team)
	flush_events()  # drain any remaining events first
	_post("/ingest/match", buffer.build_match_report(started_at, ended_at))

func _post(path: String, body: Dictionary) -> void:
	if _endpoint.is_empty():
		return
	# Best-effort: if a request is already inflight, spool rather than block the tick.
	if _inflight:
		_spool.append({"path": path, "body": body})
		return
	_drain_spool_then(path, body)

func _drain_spool_then(path: String, body: Dictionary) -> void:
	# Re-send anything previously spooled, oldest first, then the new payload.
	var pending := _spool.read_all()
	pending.append({"path": path, "body": body})
	_spool.clear()
	_send_queue(pending)

var _queue: Array = []
func _send_queue(items: Array) -> void:
	_queue = items
	_send_next()

func _send_next() -> void:
	if _queue.is_empty():
		return
	var item: Dictionary = _queue[0]
	var headers := ["Authorization: Bearer %s" % _token, "Content-Type: application/json"]
	_inflight = true
	var err := _http.request(_endpoint + String(item["path"]), headers,
		HTTPClient.METHOD_POST, JSON.stringify(item["body"]))
	if err != OK:
		_inflight = false
		# Transport could not even start — spool the whole queue and give up for now.
		for it in _queue:
			_spool.append(it)
		_queue = []

func _on_request_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_inflight = false
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	if not ok:
		# Failed — spool this item and the rest of the queue for a later retry.
		for it in _queue:
			_spool.append(it)
		_queue = []
		return
	_queue.pop_front()
	_send_next()
```

- [ ] **Step 4: Run test to verify it passes** — `godot --headless --path . -- --test --filter=stats_reporter` → PASS.

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_reporter.gd tests/stats_reporter_test.gd
git commit -m "feat(stats): StatsReporter node (HTTP POST + spool drain)"
```

---

### Task 7: Server config — `--stats-endpoint` / `--stats-token`

**Files:**
- Modify: `server/server_main.gd` (`configure`, member vars)

- [ ] **Step 1: Add member vars** near the other server_main fields (by `var _stats := ServerStats.new()`, ~`:135`):

```gdscript
var _stats_endpoint: String = ""
var _stats_token: String = ""
var _stats_reporter: StatsReporter = null
```

- [ ] **Step 2: Read the flags in `configure(args)`** — add alongside the existing ad-hoc flags (near `_fast_nades = args.has("fast-nades")`, ~`:196`):

```gdscript
	_stats_endpoint = String(args.get("stats-endpoint", ""))
	_stats_token = String(args.get("stats-token", ""))
```

- [ ] **Step 3: Verify parsing** (no new test — reuses bootstrap's `--k=v` parser):

Run: `godot --headless --path . -- --server --stats-endpoint=http://localhost:8000 --stats-token=x --help 2>&1 | head` (server should start arg-parsing without error; Ctrl-C to stop). This is a smoke check; the real exercise is Task 9.

- [ ] **Step 4: Commit**

```bash
git add server/server_main.gd
git commit -m "feat(stats): --stats-endpoint / --stats-token server flags"
```

---

### Task 8: Wire StatsReporter into the tick loop and combat funnels

**Files:**
- Modify: `server/server_main.gd`, `server/fire.gd`

- [ ] **Step 1: Instantiate at match start.** In `_ready()` after `_start_match()` (`~:242`), and set `server_id` from config/host:

```gdscript
	if not _stats_endpoint.is_empty():
		_stats_reporter = StatsReporter.new()
		_stats_reporter.configure(_stats_endpoint, _stats_token)
		add_child(_stats_reporter)
		_stats_reporter.begin_match(_gen_match_id(), _stats_server_id(), _map.map_id, "conquest")
		_stats_match_started_at = Time.get_datetime_string_from_system(true) + "Z"
```

Add helpers + fields (near the other private helpers):

```gdscript
var _stats_match_started_at: String = ""

func _gen_match_id() -> String:
	return "%d-%04d" % [int(Time.get_unix_time_from_system()), (randi() % 10000)]

func _stats_server_id() -> String:
	return "game2-dev-%d" % _port
```

(Use whatever the map exposes for its id; if `_map.map_id` doesn't exist, substitute the field the map uses for its name — check `_start_match` at `:262`.)

- [ ] **Step 2: Register players on join.** In the HELLO handler where `_clients[id]` is built (`~:1189`), after the dict is assigned:

```gdscript
	if _stats_reporter != null:
		_stats_reporter.buffer.register_player(id, pname, int(_clients[id].get("steam_id", 0)), team)
```

(`_clients[id]` has no `steam_id` yet — `.get(...,0)` yields 0 → name-based key. When client Steam auth lands later, populate `_clients[id]["steam_id"]` at HELLO and this starts producing `steam:<id>` keys with no further change.)

- [ ] **Step 3: Tap the kill funnel.** In `_kill_pawn(vid, victim, killer_id, weapon_id, headshot, source)` (`:690`), after the existing `_clients` bookkeeping (`~:710`), where killer/victim positions are already computed (`~:723`):

```gdscript
	if _stats_reporter != null:
		var kp := _sim.world.get_pawn(killer_id)
		var kpos := kp.pos if kp != null else Vector3.ZERO
		var dist := victim.pos.distance_to(kpos) if kp != null else 0.0
		_stats_reporter.buffer.record_kill(killer_id, vid,
			StatsReporter.weapon_key(weapon_id), headshot, dist, _sim.tick, kpos, victim.pos)
```

- [ ] **Step 4: Tap the damage funnel.** In `_apply_pawn_damage(vid, victim, dmg, headshot, source, killer_id, weapon_id)` (`:752`), after `victim.health` is reduced (`~:766`):

```gdscript
	if _stats_reporter != null and killer_id != vid:
		_stats_reporter.buffer.record_damage(killer_id, StatsReporter.weapon_key(weapon_id), int(dmg))
```

- [ ] **Step 5: Tap downs.** In `_down_pawn(victim)` (`:659`), after `_stats.downed += 1` (`~:666`):

```gdscript
	if _stats_reporter != null:
		_stats_reporter.buffer.record_down(victim.id)
```

(Confirm the victim's id accessor on `Pawn` — `victim.id`; check `shared/sim/pawn.gd`.)

- [ ] **Step 6: Tap shots and hits in `fire.gd`.** At the shot site (`fire.gd:127`, `srv._stats.shots += 1`), the shooter id is the projectile owner:

```gdscript
	if srv._stats_reporter != null:
		srv._stats_reporter.buffer.record_shot(int(pr["owner"]), StatsReporter.weapon_key(int(pr["weapon_id"])))
```

At the hit site (`fire.gd:298`, `srv._stats.hits += 1`):

```gdscript
	if srv._stats_reporter != null:
		srv._stats_reporter.buffer.record_hit(int(pr["owner"]), StatsReporter.weapon_key(int(pr["weapon_id"])), best_head)
```

(Match the exact local names at those lines — the owner is `pr["owner"]`, weapon `pr["weapon_id"]`, headshot `best_head` per the investigation.)

- [ ] **Step 7: Flush events once per second.** In `_log_telemetry()` (`:2438`), before the window reset (`~:2472`):

```gdscript
	if _stats_reporter != null:
		_stats_reporter.flush_events()
```

- [ ] **Step 8: Final match report at match-over.** In `_track_and_broadcast_match_state()` inside the `if _conquest.match_over and not _match_over_broadcast:` block (`:887–895`), after the existing `print("[match] OVER ...")`:

```gdscript
		if _stats_reporter != null:
			_stats_reporter.end_match(_conquest.winner, int(_conquest.elapsed),
				_stats_match_started_at, Time.get_datetime_string_from_system(true) + "Z")
```

- [ ] **Step 9: Run the full test suite** to ensure no regressions in existing server tests:

Run: `godot --headless --path . --import && godot --headless --path . -- --test`
Expected: `TESTS: N run, 0 failed` (same failing-count as before your change — i.e. 0).

- [ ] **Step 10: Commit**

```bash
git add server/server_main.gd server/fire.gd
git commit -m "feat(stats): wire StatsReporter into tick loop + combat funnels"
```

---

### Task 9: P1 live gate — data flows from a game2 bot match

This is the **P1 definition-of-done**. It exercises the real HTTP path (unit tests can't) and the NDJSON fallback. Run against the P1-A backend.

- [ ] **Step 1: Bring the backend up** (locally or on game2):

```bash
cd backend && export INGEST_TOKEN=dev-secret && docker compose up --build -d
curl -s localhost:8000/healthz   # {"status":"ok"}
```

- [ ] **Step 2: Run a short bot match pointed at the backend.** From the repo root (adjust bot count/time for a quick match):

```bash
godot --headless --path . -- --server --stats-endpoint=http://localhost:8000 \
  --stats-token=dev-secret --bots --bot-count=16 --time-limit=60 --map=<a valid map id>
```
Let it play a full match to match-over (watch for the `[match] OVER` line), then stop.

- [ ] **Step 3: Verify all four layers landed** in Postgres:

```bash
cd backend && docker compose exec -T db psql -U blockfire -d blockfire_stats \
  -c "SELECT count(*) matches, max(complete::int) complete FROM matches;" \
  -c "SELECT count(*) FROM match_players;" \
  -c "SELECT weapon_id, sum(shots) shots, sum(hits) hits, round(sum(hits)::numeric/nullif(sum(shots),0),3) hit_rate FROM match_player_weapons GROUP BY weapon_id;" \
  -c "SELECT type, count(*) FROM events GROUP BY type;"
```
Expected: ≥1 complete match; per-player rows; per-weapon shots/hits with a plausible hit_rate; `kill` events present.

- [ ] **Step 4: Verify the backend-down fallback loses no data.** Repeat Step 2 but stop the backend mid-match (`cd backend && docker compose stop api`), let the match finish, confirm a spool file exists (`ls ~/.local/share/godot/app_userdata/*/stats_spool.ndjson` — path per `user://`), then restart the backend (`docker compose start api`) and trigger one more flush (start another short match, or re-run). Confirm the previously-spooled match appears in Postgres.

- [ ] **Step 5: Capture gate evidence.** Save the psql output + the commands to `docs/gate-evidence/2026-07-11-stats-p1.md` (matching the project's gate-evidence convention).

- [ ] **Step 6: Commit**

```bash
git add docs/gate-evidence/2026-07-11-stats-p1.md
git commit -m "test(stats): P1 live gate evidence (game2 bot match -> Postgres)"
```

---

## Self-review

**Spec coverage (P1-B portion):**
- `StatsReporter` module tapping combat resolution — Tasks 1–8 ✓ (taps `_kill_pawn`, `_apply_pawn_damage`, shots/hits in `fire.gd`, downs, per-second flush, match-over)
- Per-player-per-weapon counters + per-kill events — Tasks 1–4 ✓
- NDJSON fallback + drain-on-recovery — Tasks 5, 6, 9 ✓
- `--stats-endpoint`/`--stats-token` config — Task 7 ✓
- No measurable tick cost — buffer ops are O(1) dict writes; HTTP is async off-tick (verify via `[telemetry]` `tick_mean` in Task 9) ✓
- P1 gate (game2 bot match → Postgres, hit-rate correct, backend-down loses no data) — Task 9 ✓
- **Deferred (noted):** captures/neutralizes/assists per-player (no clean per-player hook yet — left at 0, defaults valid); `weapon_id` becomes the variant `key` once the weapon-variants worktree merges (update `weapon_key` + its test then); `playtime_s` is 0 until a per-player join/leave-time hook is added (P2, alongside profiles).

**Placeholder scan:** the only intentionally-parametric spots are exact line anchors ("~:242") and `<a valid map id>` in the live-run command — these are lookups against the cited functions, not missing logic. Every code block is complete.

**Type consistency:** `StatsBuffer` method names (`record_kill/shot/hit/damage/down/revive`, `take_event_batch`, `set_results`, `build_match_report`) are identical across tasks and the server_main taps; `StatsReporter.weapon_key(int)->String` static, used consistently in `fire.gd` and `server_main.gd`; event/report field names (`actor`,`target`,`weapon_id`,`batch_seq`,`match`) match the P1-A Pydantic schemas exactly (cross-checked against `EventIn`/`MatchReportIn`).

**Cross-plan contract check:** event JSON `{tick,type,actor,target,weapon_id,payload}` ↔ P1-A `EventIn` ✓; batch `{match_id,batch_seq,events}` ↔ `EventBatchIn` ✓; report `{report_version,match:{...},players:[{...,weapons:[...]}]}` ↔ `MatchReportIn` ✓; `player_key` derivation (`steam:<id>`|`name:<name>`) identical in `StatsBuffer._key` and P1-A `identity.player_key` ✓.
```
