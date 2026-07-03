# M8-P3 — Server Config File + Map Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `data/server_config.json` match settings (CLI overrides file; file absent → today's defaults) and a persistent multi-match loop that advances a map-rotation list between matches instead of exiting.

**Architecture:** A pure `server/config.gd` (`ServerConfig`) does file load + validation + CLI-precedence resolve (unit-testable, no I/O in resolve). `server_main.gd` splits `_ready()` into boot-scoped init (catalogs, NetHost — once) and `_start_match()` (map/conquest/store/vehicles + every match-scoped container — re-runnable). At match end + drain: rotation active → disconnect all peers, advance the rotation index, `_start_match()` again; otherwise `quit(0)` exactly as today (all existing gates unaffected). No wire change (WELCOME already carries the map name; the client already adopts it — reconnecting clients land on the new map).

**Tech Stack:** GDScript (Godot 4.6 headless), repo test harness (`tests/*_test.gd` + `tests/server_fixture.gd`), `ci/*.sh` smoke pattern.

**Spec:** `docs/specs/m8-hardening-ops.md` §P3. This plan also authors the required-but-missing `docs/specs/server-ops.md`.

**Branch:** `m8-p3-config-rotation` (never implement on master).

**Ratified scope decisions (from spec + code facts — do not relitigate):**
- **`tick_rate` is NOT configurable.** `SimLoop.DT` is a compile-time const (`1.0/30.0`); a runtime tick rate is a sim-wide change with no current need (YAGNI). Document in `server-ops.md`.
- **Rotation mode** = config file provides a non-empty `maps` list AND no `--map` CLI override. `--map` pins a single match + exit-on-end (today's gate semantics). No config file → today's behavior in every respect.
- **Rotation disconnects peers** at match end (after the existing 60-tick drain, in which the final MATCH_STATE with `over=true` was already reliably broadcast). Clients reconnect and adopt the new map via WELCOME. Client auto-reconnect UI is an M7 polish follow-up, out of scope here.
- **Do NOT commit `data/server_config.json`** (a committed rotation config would make every gate script hang — they wait for server exit). Commit `data/server_config.example.json` + docs.
- `max_players` is config-file-only (no CLI flag exists today); `port`/`tickets`/`time-limit`/`map`/`degrade-*-ms` keep their CLI flags, which win over the file.

**GDScript gotchas for every implementer (from docs/HANDOVER.md):** run `godot --headless --path . --import` once after adding any `class_name` script; never pipe godot through `tail`/`head` (redirect to a file); `var x := dict["k"]` is a Variant-inference error — annotate explicitly; tests extend global `TestCase`, zero-assertion tests FAIL, runtime SCRIPT ERROR mid-test FAILS; use `autofree(node)` for Nodes; `git add -A` for `.uid` sidecars.

**Run tests:** `godot --headless --path . -- --test --filter=<substr> > /tmp/t.log 2>&1; tail -20 /tmp/t.log` (full suite: no filter; expect 1042+ run / 0 failed at start).

---

### Task 1: `ServerConfig` — pure load + resolve (config file, precedence, rotation list)

**Files:**
- Create: `server/config.gd`
- Test: `tests/server_config_test.gd`

- [ ] **Step 1: Write the failing tests**

```gdscript
extends TestCase
## M8-P3: server config file — load contract, validation, CLI>file>default precedence,
## rotation-mode resolution. docs/specs/server-ops.md.

const CFG_PATH := "/tmp/bf_server_config_test.json"

func _write(text: String) -> void:
	var f := FileAccess.open(CFG_PATH, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func teardown() -> void:
	DirAccess.remove_absolute(CFG_PATH)

func test_load_missing_file_is_ok_empty() -> void:
	# Absent file is NOT an error (back-compat default path); empty config.
	var r: Dictionary = ServerConfig.load_file("/tmp/bf_no_such_config.json")
	assert_true(r["ok"])
	assert_eq(r["config"], {})

func test_load_malformed_json_errors() -> void:
	_write("{not json")
	var r: Dictionary = ServerConfig.load_file(CFG_PATH)
	assert_false(r["ok"])
	assert_true(String(r["error"]).length() > 0)

func test_load_non_dict_root_errors() -> void:
	_write("[1,2]")
	assert_false(ServerConfig.load_file(CFG_PATH)["ok"])

func test_load_drops_unknown_and_mistyped_keys() -> void:
	_write('{"port": 28000, "bogus": 1, "maps": "town", "tickets": "many"}')
	var r: Dictionary = ServerConfig.load_file(CFG_PATH)
	assert_true(r["ok"])
	var c: Dictionary = r["config"]
	assert_eq(int(c["port"]), 28000)
	assert_false(c.has("bogus"))    # unknown key dropped (warned)
	assert_false(c.has("maps"))     # wrong type (string, not array) dropped
	assert_false(c.has("tickets"))  # wrong type dropped

func test_load_drops_non_string_map_entries() -> void:
	_write('{"maps": ["conquest_town", 7, "conquest_dev_arena"]}')
	var r: Dictionary = ServerConfig.load_file(CFG_PATH)
	assert_eq(r["config"]["maps"], ["conquest_town", "conquest_dev_arena"])

func test_resolve_defaults_when_everything_absent() -> void:
	var e: Dictionary = ServerConfig.resolve({}, {})
	assert_eq(int(e["port"]), 27015)
	assert_eq(int(e["max_players"]), 128)
	assert_eq(int(e["tickets"]), -1)
	assert_eq(float(e["time_limit"]), -1.0)
	assert_eq(e["maps"], [])
	assert_false(e["rotate"])
	assert_eq(float(e["degrade_high_ms"]), -1.0)
	assert_eq(float(e["degrade_low_ms"]), -1.0)

func test_resolve_file_values_apply() -> void:
	var file := {"port": 28000.0, "max_players": 64.0, "tickets": 200.0,
		"time_limit": 300.0, "degrade_high_ms": 28.0, "degrade_low_ms": 24.0}
	var e: Dictionary = ServerConfig.resolve(file, {})
	assert_eq(int(e["port"]), 28000)
	assert_eq(int(e["max_players"]), 64)
	assert_eq(int(e["tickets"]), 200)
	assert_eq(float(e["time_limit"]), 300.0)
	assert_eq(float(e["degrade_high_ms"]), 28.0)
	assert_eq(float(e["degrade_low_ms"]), 24.0)

func test_resolve_cli_beats_file() -> void:
	var file := {"port": 28000.0, "tickets": 200.0, "time_limit": 300.0}
	var cli := {"port": "28500", "tickets": "50", "time-limit": "60"}
	var e: Dictionary = ServerConfig.resolve(file, cli)
	assert_eq(int(e["port"]), 28500)
	assert_eq(int(e["tickets"]), 50)
	assert_eq(float(e["time_limit"]), 60.0)

func test_resolve_file_maps_enable_rotation() -> void:
	var e: Dictionary = ServerConfig.resolve({"maps": ["conquest_town", "conquest_dev_arena"]}, {})
	assert_eq(e["maps"], ["conquest_town", "conquest_dev_arena"])
	assert_true(e["rotate"])

func test_resolve_cli_map_pins_single_match_no_rotation() -> void:
	# --map override = today's gate semantics: one match on that map, exit on end.
	var e: Dictionary = ServerConfig.resolve({"maps": ["conquest_town", "conquest_dev_arena"]}, {"map": "conquest_proving_grounds"})
	assert_eq(e["maps"], ["conquest_proving_grounds"])
	assert_false(e["rotate"])

func test_resolve_single_entry_rotation_loops_same_map() -> void:
	assert_true(ServerConfig.resolve({"maps": ["conquest_town"]}, {})["rotate"])

func test_next_map_index_advances_and_wraps() -> void:
	assert_eq(ServerConfig.next_map_index(0, 3), 1)
	assert_eq(ServerConfig.next_map_index(2, 3), 0)
	assert_eq(ServerConfig.next_map_index(0, 1), 0)
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=server_config > /tmp/t.log 2>&1; tail -5 /tmp/t.log`
Expected: FAIL (ServerConfig not defined / parse error listed by the harness).

- [ ] **Step 3: Implement `server/config.gd`**

```gdscript
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
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return {"ok": false, "config": {}, "error": "malformed JSON in %s" % path}
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
```

- [ ] **Step 4: Register the class_name, then run the tests**

Run: `godot --headless --path . --import > /tmp/import.log 2>&1` then `godot --headless --path . -- --test --filter=server_config > /tmp/t.log 2>&1; tail -5 /tmp/t.log`
Expected: all server_config tests PASS, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A server/config.gd tests/server_config_test.gd
git commit -m "feat(server): ServerConfig — config-file load/validate + CLI-precedence resolve (M8-P3)"
```

---

### Task 2: `NetHost.disconnect_all()`

**Files:**
- Modify: `shared/net/net_host.gd` (after `peers()`, before `close()`)
- Test: `tests/net_disconnect_all_test.gd`

- [ ] **Step 1: Write the failing test** (real loopback ENet — cheap and deterministic locally)

```gdscript
extends TestCase
## M8-P3: NetHost.disconnect_all — server-initiated disconnect of every peer
## (map-rotation boundary). Loopback ENet on an uncommon port.

const PORT := 28471

func test_disconnect_all_disconnects_connected_peer() -> void:
	var server := NetHost.new()
	autofree(server)
	assert_eq(server.start_server(PORT, 4), OK)
	var client := NetHost.new()
	autofree(client)
	var peer := client.start_client("127.0.0.1", PORT)
	assert_true(peer != null)
	# Pump both hosts until the server sees the peer (bounded).
	for i in range(200):
		server.poll(); client.poll()
		if server.peers().size() == 1: break
		OS.delay_msec(5)
	assert_eq(server.peers().size(), 1)
	var got_disconnect := false
	client.peer_disconnected.connect(func(_p): got_disconnect = true)
	server.disconnect_all()
	for i in range(200):
		server.poll(); client.poll()
		if got_disconnect: break
		OS.delay_msec(5)
	assert_true(got_disconnect)

func test_disconnect_all_on_idle_host_is_safe() -> void:
	var host := NetHost.new()
	autofree(host)
	host.disconnect_all()   # no _host yet — must not error
	assert_true(true)
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=net_disconnect_all > /tmp/t.log 2>&1; tail -5 /tmp/t.log`
Expected: FAIL (`disconnect_all` not found).

- [ ] **Step 3: Implement**

```gdscript
## Politely disconnect every connected peer (flushes queued reliable sends first).
## Used at the map-rotation match boundary (M8-P3).
func disconnect_all() -> void:
	for peer in peers():
		peer.peer_disconnect_later()
```

- [ ] **Step 4: Run tests**

Run: `godot --headless --path . -- --test --filter=net_disconnect_all > /tmp/t.log 2>&1; tail -5 /tmp/t.log`
Expected: 2 PASS, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A shared/net/net_host.gd tests/net_disconnect_all_test.gd
git commit -m "feat(net): NetHost.disconnect_all for the map-rotation match boundary (M8-P3)"
```

---

### Task 3: Extract `_start_match()` from `_ready()` (pure refactor, no behavior change)

**Files:**
- Modify: `server/server_main.gd:158-225` (`_ready`)

`_ready()` currently interleaves match-scoped setup (map, conquest, store + prebuilt + building stamping, vehicle spawns) with boot-scoped setup (catalogs, NetHost). Split it so the match-scoped half is re-runnable. **No new fields, no new behavior in this task** — the suite must stay green with zero test edits.

- [ ] **Step 1: Restructure**

New `_ready()` (order: catalogs → net → match; a failed catalog still quits(1) as before):

```gdscript
func _ready() -> void:
	_catalog = PieceCatalog.load_file(PIECES_PATH)
	if _catalog == null:
		push_error("[server] failed to load pieces %s" % PIECES_PATH); get_tree().quit(1); return
	_gadgets = Gadget.load_file(GADGETS_PATH)
	if _gadgets == null:
		push_error("[server] failed to load gadgets %s" % GADGETS_PATH); get_tree().quit(1); return
	_attachments = Attachment.load_file(ATTACHMENTS_PATH)
	if _attachments == null:
		push_error("[server] failed to load attachments %s" % ATTACHMENTS_PATH); get_tree().quit(1); return
	_vehicles_cat = VehicleCatalog.load_file(VEHICLES_PATH)
	if _vehicles_cat == null:
		push_error("[server] failed to load vehicles %s" % VEHICLES_PATH); get_tree().quit(1); return
	if not _start_match():
		get_tree().quit(1); return
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)]); get_tree().quit(1); return
	print("[server] listening on %d, tick=%dHz, max=%d map=%s" % [_port, TICK_RATE, MAX_PLAYERS, _map.name])
	# (keep the existing SIGTERM NOTE comment block here unchanged)
```

New `_start_match() -> bool` — the moved block, verbatim except `quit(1)` becomes `return false` (the callers decide process fate) and `_sim.structures/_sim.ladders/_sim.platforms` wiring stays with it:

```gdscript
## Load the map and build all match-scoped state. Called at boot and again at each
## map-rotation boundary (M8-P3). Returns false when the map fails to load.
func _start_match() -> bool:
	_map = MapDef.load_file(_map_path)
	if _map == null:
		push_error("[server] failed to load map %s" % _map_path); return false
	_conquest = ConquestState.new(_map)
	if _start_tickets > 0:
		_conquest.tickets = [float(_start_tickets), float(_start_tickets)]
	if _time_limit > 0.0:
		_conquest.time_limit = _time_limit
	_prev_owners = _owner_snapshot()
	_store = StructureStore.new(_catalog)
	_sim.structures = _store
	_sim.ladders = _map.ladders
	_sim.platforms = _map.platforms
	# ... (prebuilt placement loop — moved verbatim from _ready) ...
	# ... (M11 building-prefab stamping loop — moved verbatim from _ready) ...
	_spawn_map_vehicles()
	return true
```

(Move the `_next_struct_id`-consuming loops exactly as they are; `_next_building_id` is a local already.)

- [ ] **Step 2: Import + full suite + boot smoke**

Run: `godot --headless --path . --import > /tmp/import.log 2>&1 && godot --headless --path . -- --test > /tmp/t.log 2>&1; tail -3 /tmp/t.log`
Expected: same count as master (≥1042 run), 0 failed.
Then boot: `timeout 5 godot --headless --path . -- --server --port=28123 > /tmp/boot.log 2>&1; grep "listening" /tmp/boot.log`
Expected: `[server] listening on 28123, tick=30Hz, max=128 map=Proving Grounds` (name per map file), no SCRIPT ERROR in log.

- [ ] **Step 3: Commit**

```bash
git add -A server/server_main.gd
git commit -m "refactor(server): extract match-scoped setup into _start_match() (M8-P3 prep, no behavior change)"
```

---

### Task 4: Wire `ServerConfig` into `configure()` (+ `max_players`)

**Files:**
- Modify: `server/server_main.gd:141-156` (`configure`), `:14` (`MAX_PLAYERS` use at `start_server`), `:765` (join cap check)
- Create: `data/server_config.example.json`
- Test: `tests/server_configure_test.gd`

- [ ] **Step 1: Write the failing test** (fixture-level: real `configure()` with a temp config file)

```gdscript
extends TestCase
## M8-P3: server configure() resolves config file + CLI with CLI precedence.

const F := preload("res://tests/server_fixture.gd")
const CFG := "/tmp/bf_configure_test.json"

func _write(text: String) -> void:
	var f := FileAccess.open(CFG, FileAccess.WRITE)
	f.store_string(text); f.close()

func teardown() -> void:
	DirAccess.remove_absolute(CFG)

func test_config_file_applies_when_no_cli() -> void:
	_write('{"port": 28200, "max_players": 32, "tickets": 150, "time_limit": 240, "maps": ["conquest_dev_arena", "conquest_town"]}')
	var srv = F.make_server()
	autofree(srv)
	srv.configure({"config": CFG})
	assert_eq(srv._port, 28200)
	assert_eq(srv._max_players, 32)
	assert_eq(srv._start_tickets, 150)
	assert_eq(srv._time_limit, 240.0)
	assert_eq(srv._maps, ["conquest_dev_arena", "conquest_town"])
	assert_true(srv._rotate)
	assert_eq(srv._map_path, "res://maps/conquest_dev_arena.json")

func test_cli_overrides_config_file() -> void:
	_write('{"port": 28200, "tickets": 150, "maps": ["conquest_town"]}')
	var srv = F.make_server()
	autofree(srv)
	srv.configure({"config": CFG, "port": "28300", "tickets": "60", "map": "conquest_dev_arena"})
	assert_eq(srv._port, 28300)
	assert_eq(srv._start_tickets, 60)
	assert_false(srv._rotate)                                    # --map pins single-match mode
	assert_eq(srv._map_path, "res://maps/conquest_dev_arena.json")

func test_no_config_file_keeps_defaults() -> void:
	var srv = F.make_server()
	autofree(srv)
	srv.configure({"config": "/tmp/bf_absent_config.json"})
	assert_eq(srv._port, 27015)
	assert_eq(srv._max_players, 128)
	assert_false(srv._rotate)
	assert_eq(srv._map_path, "res://maps/conquest_proving_grounds.json")

func test_degrade_band_from_config_file() -> void:
	_write('{"degrade_high_ms": 28.0, "degrade_low_ms": 24.0}')
	var srv = F.make_server()
	autofree(srv)
	srv.configure({"config": CFG})
	assert_eq(srv._degrade_high_ms, 28.0)
	assert_eq(srv._degrade_low_ms, 24.0)
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=server_configure > /tmp/t.log 2>&1; tail -5 /tmp/t.log`
Expected: FAIL (`_max_players` / `_maps` / `_rotate` don't exist).

- [ ] **Step 3: Implement**

New fields next to `_map_path` (`server_main.gd:90`):

```gdscript
var _max_players := MAX_PLAYERS
var _maps: Array = []        # rotation list (map basenames); empty = single-match default map
var _map_index := 0
var _rotate := false         # persistent multi-match loop active (config maps, no --map override)
```

Replace the body of `configure()` (keep the inverted-degrade-band guard at the end, adjusted to only warn when a band was actually set):

New field: `var _boot_failed := false` (bootstrap calls `configure()` BEFORE `add_child`, so `get_tree()` is null there — the quit must happen in `_ready()`, first line: `if _boot_failed: get_tree().quit(1); return`).

```gdscript
func configure(args: Dictionary) -> void:
	var loaded := ServerConfig.load_file(String(args.get("config", ServerConfig.DEFAULT_PATH)))
	if not loaded["ok"]:
		# An operator-authored config that doesn't parse must fail loud, not silently
		# fall back to defaults mid-LAN-party. get_tree() is null here (configure runs
		# pre-add_child) — flag it and _ready() exits.
		push_error("[server] %s" % loaded["error"])
		_boot_failed = true
		return
	var eff := ServerConfig.resolve(loaded["config"], args)
	_port = eff["port"]
	_max_players = eff["max_players"]
	_start_tickets = eff["tickets"]
	_time_limit = eff["time_limit"]
	_maps = eff["maps"]
	_rotate = eff["rotate"]
	if not _maps.is_empty():
		_map_path = "res://maps/%s.json" % String(_maps[0])
	_human_rpg = args.has("human-rpg")
	if eff["degrade_high_ms"] > 0.0: _degrade_high_ms = eff["degrade_high_ms"]
	if eff["degrade_low_ms"] > 0.0: _degrade_low_ms = eff["degrade_low_ms"]
	if _degrade_low_ms >= _degrade_high_ms:
		push_warning("[server] degrade band low (%.1f) must be < high (%.1f); using defaults %0.1f/%0.1f"
			% [_degrade_low_ms, _degrade_high_ms, Degrade.LOW_MS, Degrade.HIGH_MS])
		_degrade_high_ms = Degrade.HIGH_MS
		_degrade_low_ms = Degrade.LOW_MS
	if _rotate:
		print("[server] map rotation active: %s" % [", ".join(_maps)])
```

In `_ready()`: `start_server(_port, _max_players)`; in the join-cap check at `:765` replace `MAX_PLAYERS` with `_max_players`; update the `listening` print to `max=%d" % _max_players`.

`data/server_config.example.json` (committed; the real `data/server_config.json` stays uncommitted — see plan header):

```json
{
  "port": 27015,
  "max_players": 128,
  "tickets": 300,
  "time_limit": 1800,
  "maps": ["conquest_town", "conquest_proving_grounds", "conquest_arena_buildings"],
  "degrade_high_ms": 30.0,
  "degrade_low_ms": 26.0
}
```

Add `data/server_config.json` to `.gitignore` (defensive: an operator's local rotation config must never land in a commit/image and hang the gates).

- [ ] **Step 4: Run tests + full suite**

Run: `godot --headless --path . -- --test > /tmp/t.log 2>&1; tail -3 /tmp/t.log`
Expected: new tests PASS, full suite 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A server/server_main.gd tests/server_configure_test.gd data/server_config.example.json .gitignore
git commit -m "feat(server): config-file support in configure() — CLI>file>default, max_players, rotation list (M8-P3)"
```

---

### Task 5: The rotation loop — `_rotate_match()` + full match-state reset

**Files:**
- Modify: `server/server_main.gd` (`_physics_process:317-318` exit branch; new `_rotate_match()` + `_reset_match_state()` next to `_start_match()`)
- Test: `tests/server_rotation_test.gd`

This is the blast-radius task. Every match-scoped field in `server_main.gd:81-139` must reset. Boot-scoped (NOT reset): `_net`, `_port`, `_max_players`, `_start_tickets`, `_time_limit`, `_human_rpg`, catalogs (`_catalog`, `_gadgets`, `_attachments`, `_vehicles_cat`), degrade band overrides (`_degrade_high_ms/_low_ms`), `_tele` (rolling process telemetry), `_maps`/`_map_index`/`_rotate`.

- [ ] **Step 1: Write the failing test**

```gdscript
extends TestCase
## M8-P3: map rotation — at match end + drain the server resets ALL match state and
## starts the next map in the rotation instead of exiting. Uses the real server
## (fixture, SpyNet — no ENet) and real _start_match/_rotate_match.

const F := preload("res://tests/server_fixture.gd")

func _rotating_server():
	var srv = F.make_server()
	srv._maps = ["conquest_dev_arena", "conquest_proving_grounds"]
	srv._map_index = 0
	srv._rotate = true
	srv._map_path = "res://maps/conquest_dev_arena.json"
	# Boot-scoped catalogs _start_match needs beyond the fixture's piece catalog:
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	srv._attachments = Attachment.load_file("res://data/attachments.json")
	srv._vehicles_cat = VehicleCatalog.load_file("res://data/vehicles.json")
	assert_true(srv._start_match())
	return srv

func test_rotate_advances_map_and_resets_state() -> void:
	var srv = _rotating_server()
	autofree(srv)
	var pieces_before: int = srv._store.count()
	# Dirty every category of match state a real match touches.
	F.add_client(srv, 7, 0)
	F.add_pawn(srv, 7, 0, Vector3(1, 0, 1))
	srv._team_counts[0] = 1
	srv._grenades.append({"owner": 7})
	srv._smoke_zones.append({"pos": Vector3.ZERO, "radius": 6.0, "expire_tick": 999})
	srv._stats.kills = 5
	srv._degrade_level = 2
	srv._match_over_broadcast = true
	srv._match_end_tick = 100
	srv._sim.tick = 500

	srv._rotate_match()

	assert_eq(srv._map_index, 1)
	assert_eq(srv._map_path, "res://maps/conquest_proving_grounds.json")
	assert_eq(srv._map.name, "Proving Grounds")            # next map actually loaded
	assert_eq(srv._clients.size(), 0)
	assert_eq(srv._sim.world.pawns.size(), 0)
	assert_eq(srv._sim.tick, 0)
	assert_eq(srv._grenades.size(), 0)
	assert_eq(srv._smoke_zones.size(), 0)
	assert_eq(srv._stats.kills, 0)                          # fresh ServerStats
	assert_eq(srv._degrade_level, 0)
	assert_false(srv._match_over_broadcast)
	assert_eq(srv._match_end_tick, -1)
	assert_eq(srv._team_counts, {0: 0, 1: 0})
	assert_true(srv._store.count() > 0)                     # new map's structures stamped
	assert_true(srv._store.count() != pieces_before or srv._maps[0] == srv._maps[1])
	assert_false(srv._conquest.match_over)                  # fresh conquest

func test_rotate_wraps_to_first_map() -> void:
	var srv = _rotating_server()
	autofree(srv)
	srv._map_index = 1
	srv._map_path = "res://maps/conquest_proving_grounds.json"
	assert_true(srv._start_match())
	srv._rotate_match()
	assert_eq(srv._map_index, 0)
	assert_eq(srv._map_path, "res://maps/conquest_dev_arena.json")

func test_vehicles_respawn_fresh_on_rotation() -> void:
	var srv = _rotating_server()
	autofree(srv)
	var v_before: int = srv._sim.world.vehicles.size()
	srv._rotate_match()
	# Fresh vehicle set for the new map (dev_arena/proving_grounds both define spawns).
	assert_true(srv._sim.world.vehicles.size() > 0 or v_before == 0)
	for vid in srv._sim.world.vehicles:
		var v: Vehicle = srv._sim.world.vehicles[vid]
		assert_true(v.hp > 0)
```

(If `StructureStore` has no `count()`, check the store API first — use whatever piece-count accessor exists, e.g. `pieces().size()` or the dict field the fixture tests already read. Do not add a new store method just for the test if an accessor exists.)

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=server_rotation > /tmp/t.log 2>&1; tail -5 /tmp/t.log`
Expected: FAIL (`_rotate_match` not found).

- [ ] **Step 3: Implement**

Replace the exit branch at `_physics_process` (currently `server_main.gd:317-318`):

```gdscript
	if _match_over_broadcast and _sim.tick >= _match_end_tick + MATCH_END_DRAIN_TICKS:
		if _rotate:
			_rotate_match()
		else:
			print("[server] match complete, exiting"); get_tree().quit(0)
```

New functions (next to `_start_match`):

```gdscript
## Match boundary in rotation mode: disconnect everyone, wipe every piece of
## match-scoped state, load the next map, keep listening. Boot-scoped state
## (net host, catalogs, config, rolling telemetry) survives.
func _rotate_match() -> void:
	_map_index = ServerConfig.next_map_index(_map_index, _maps.size())
	_map_path = "res://maps/%s.json" % String(_maps[_map_index])
	print("[server] match complete — rotating to %s" % String(_maps[_map_index]))
	if _net != null:
		_net.disconnect_all()
	_reset_match_state()
	if not _start_match():
		# A rotation entry pointing at a missing/broken map is an operator config error;
		# a dead persistent server is worse than a loud exit.
		push_error("[server] rotation failed to load %s — exiting" % _map_path)
		get_tree().quit(1)

## Wipe all match-scoped state. Complements _start_match(), which rebuilds
## map/conquest/store/vehicles. Keep this list in sync with the var block at the
## top of the file: every match-scoped var either resets HERE or is rebuilt in
## _start_match().
func _reset_match_state() -> void:
	_sim = SimLoop.new()
	_grid.clear()
	_lag.clear()
	_squads = SquadManager.new()
	_stats = ServerStats.new()
	_fire = ServerFire.new(self)
	_support = ServerSupport.new(self)
	_build = ServerBuild.new(self)
	_gadget_rl = ReliableList.new()
	_support_rl = ReliableList.new()
	_downed_rl = ReliableList.new()
	_fob_rl = ReliableList.new()
	_clients.clear()
	_peer_to_id.clear()
	_human_ids.clear()
	_team_counts = {0: 0, 1: 0}
	_positions.clear()
	_prev_climb_vault.clear()
	_transport_origin.clear()
	_pending_removes.clear()
	_dmg_touched.clear()
	_buildings_to_cascade.clear()
	_grenades.clear()
	_rockets.clear()
	_mines.clear()
	_bags.clear()
	_c4.clear()
	_smoke_zones.clear()
	_prev_owners = []
	_match_over_broadcast = false
	_match_end_tick = -1
	_roster_tick = 0
	_next_struct_id = 1
	_next_id = 1
	_degrade_level = 0
	_snapshot_stride = SNAPSHOT_STRIDE
	_max_enemy_snapshot = MAX_ENEMY_SNAPSHOT
	_phase_ticks = 0
	for k in _phase_us:
		_phase_us[k] = 0
```

**Implementer verification step (mandatory):** after writing `_reset_match_state`, re-read the full var block `server_main.gd:81-139` (it may have drifted from this plan) and confirm every `var` is either (a) reset here, (b) rebuilt in `_start_match`, or (c) listed as boot-scoped in this task's header. Also grep the extracted modules for match-scoped state that lives OUTSIDE server_main: `grep -n "^var" server/fire.gd server/support.gd server/build.gd server/stats.gd server/reliable_list.gd` — re-instantiating them (above) covers it, but confirm none of them cache `srv._sim` or `srv._store` references at construction time (if one does, re-instantiation order matters: reset `_sim`/`_store` FIRST, then re-new the modules — note `_start_match` assigns `_store` after `_reset_match_state` runs, so any module that grabs `srv._store` in `_init` would hold a stale reference; in that case re-new that module at the END of `_start_match` instead).

- [ ] **Step 4: Run tests + full suite**

Run: `godot --headless --path . -- --test > /tmp/t.log 2>&1; tail -3 /tmp/t.log`
Expected: rotation tests PASS, full suite 0 failed.

- [ ] **Step 5: Commit**

```bash
git add -A server/server_main.gd tests/server_rotation_test.gd
git commit -m "feat(server): map rotation — persistent multi-match loop with full state reset (M8-P3)"
```

---

### Task 6: Integration smoke — `ci/m8_p3_rotation_test.sh`

**Files:**
- Create: `ci/m8_p3_rotation_test.sh` (chmod +x)

Botless: time-limit expiry ends a zero-player match (`conquest.gd:97`), so two tiny matches prove the loop end-to-end without a fleet.

- [ ] **Step 1: Write the script** (match the house style of `ci/m5.5_p1_test.sh` — polling, no fixed sleeps, log-scrape asserts)

```bash
#!/usr/bin/env bash
# M8-P3 rotation smoke: server with a 2-map rotation config + 8s time limit plays
# match 1 (dev_arena), rotates, plays match 2 (proving_grounds), rotates again —
# and never exits. Botless: time-limit expiry ends a 0-player match.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=${PORT:-28151}
LOG=/tmp/m8p3-rotation-$$.log
CFG=/tmp/m8p3-rotation-cfg-$$.json

cat > "$CFG" <<'EOF'
{"maps": ["conquest_dev_arena", "conquest_proving_grounds"], "time_limit": 8, "tickets": 500}
EOF

cleanup() { kill "$SRV_PID" 2>/dev/null || true; rm -f "$CFG"; }
trap cleanup EXIT

"$GODOT" --headless --path . -- --server --port="$PORT" --config="$CFG" > "$LOG" 2>&1 &
SRV_PID=$!

# Wait (bounded) for two completed matches + two rotation lines.
for i in $(seq 1 90); do
  overs=$(grep -c "\[match\] OVER" "$LOG" 2>/dev/null || true)
  rots=$(grep -c "rotating to" "$LOG" 2>/dev/null || true)
  if [ "${overs:-0}" -ge 2 ] && [ "${rots:-0}" -ge 2 ]; then break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "FAIL: server exited early (rotation should keep it alive)"; tail -30 "$LOG"; exit 1
  fi
  sleep 1
done

fail() { echo "FAIL: $1"; tail -40 "$LOG"; exit 1; }
[ "$(grep -c '\[match\] OVER' "$LOG")" -ge 2 ] || fail "expected >=2 match completions"
grep -q "rotating to conquest_proving_grounds" "$LOG" || fail "missing rotation to map 2"
grep -q "rotating to conquest_dev_arena" "$LOG" || fail "missing wrap-around rotation to map 1"
grep -q "map rotation active" "$LOG" || fail "missing rotation-active boot line"
kill -0 "$SRV_PID" 2>/dev/null || fail "server not alive after two rotations"
if grep -q "SCRIPT ERROR" "$LOG"; then fail "script errors in server log"; fi

echo "M8-P3 ROTATION SMOKE: PASS (matches=$(grep -c '\[match\] OVER' "$LOG"), rotations=$(grep -c 'rotating to' "$LOG"))"
```

- [ ] **Step 2: Run it**

Run: `bash ci/m8_p3_rotation_test.sh`
Expected: `M8-P3 ROTATION SMOKE: PASS (matches=2, rotations=2)` (or higher counts) in well under 90s.

- [ ] **Step 3: Commit**

```bash
chmod +x ci/m8_p3_rotation_test.sh
git add -A ci/m8_p3_rotation_test.sh
git commit -m "test(ci): M8-P3 rotation smoke — two-map botless rotation loop"
```

---

### Task 7: Docs — `specs/server-ops.md`, milestone/board updates, runbook

**Files:**
- Create: `docs/specs/server-ops.md`
- Modify: `docs/specs/m8-hardening-ops.md` (P3 status line), `docs/milestones/M8-hardening-ops.md` (status header + P3 note), `docs/TASKS.md` (M8 row), `docs/runbooks/running-a-stress-test.md` (config-file section), `docs/HANDOVER.md` (status pointer sentence for M8)

- [ ] **Step 1: Author `docs/specs/server-ops.md`**

Content requirements (write it fully, ~1 page):
- **Config file**: path `data/server_config.json` (optional; `--config=<path>` overrides the path — absolute paths allowed). Full key table: `port` (int, default 27015), `max_players` (int, 128), `tickets` (int, map default), `time_limit` (seconds, map default), `maps` (array of map basenames from `maps/*.json`; non-empty ⇒ rotation mode), `degrade_high_ms`/`degrade_low_ms` (floats, defaults from `server/degrade.gd`). Precedence: **CLI > file > built-in default**. Malformed file = loud exit(1); absent file = defaults. Unknown/mistyped keys warn + drop.
- **Explicitly out of scope + why**: `tick_rate` (SimLoop.DT is a compile-time sim constant — a runtime tick rate is a sim-wide change with no need); hot reload (boot-only by spec); SIGTERM graceful shutdown (recorded infeasible in pure GDScript 2026-07-01 — see m8-hardening-ops.md §P3).
- **Map rotation semantics**: rotation active iff config `maps` non-empty and no `--map` CLI override. Match end → existing 60-tick drain (final MATCH_STATE `over=true` already delivered reliably) → `disconnect_all` → full match-state reset (`_reset_match_state` + `_start_match`) → next map (wrap-around). No config/`--map` given → single match + exit(0) (all gate scripts depend on this). Clients reconnect; WELCOME carries the new map name and the rendered client adopts it (`client_main._handle_welcome`). Client auto-reconnect UX = M7 follow-up.
- **Evidence**: link the rotation smoke + gate evidence file (Task 8 fills in the verdict).

- [ ] **Step 2: Update the status docs**

- `docs/specs/m8-hardening-ops.md` §P3 bullet: mark config+rotation done, pointing at `server-ops.md`.
- `docs/milestones/M8-hardening-ops.md`: status header → P3 complete except deferred SIGTERM; add a dated P3-completion note with test/evidence pointers (suite count, smoke PASS line, stress verdict from Task 8).
- `docs/TASKS.md` M8 row: reflect P3 done (config+rotation), milestone closing state.
- `docs/runbooks/running-a-stress-test.md`: short "Persistent server + map rotation" section — example config JSON, `--config` flag, the warning that a rotation config makes the server never exit (don't set one on a gate host).
- `docs/HANDOVER.md`: adjust the one M8 sentence in "Status".

- [ ] **Step 3: Commit**

```bash
git add -A docs/
git commit -m "docs(m8-p3): server-ops spec (config + rotation), milestone/board/runbook updates"
```

---

### Task 8: Verification + gate + merge

- [ ] **Step 1: Full suite**

Run: `godot --headless --path . --import > /tmp/import.log 2>&1 && godot --headless --path . -- --test > /tmp/t.log 2>&1; tail -3 /tmp/t.log`
Expected: ≥1042+new run / **0 failed**, 0 script errors.

- [ ] **Step 2: Rotation smoke**

Run: `bash ci/m8_p3_rotation_test.sh` → PASS line.

- [ ] **Step 3: Back-compat boot smoke (no config file)**

Run: `timeout 20 godot --headless --path . -- --server --port=28160 --tickets=1 --time-limit=5 > /tmp/bc.log 2>&1; grep -c "match complete, exiting" /tmp/bc.log`
Expected: `1` — without a config file the server still exits at match end (gate semantics preserved). Also `grep -c "SCRIPT ERROR" /tmp/bc.log` → `0`.

- [ ] **Step 4: 128-bot stress no-regression** (this dev session runs ON game2 — run directly, no ssh)

Run: `cd docker && SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./stress.sh`
Expected: `STRESS GATE: PASS`, peak tick < 33.3ms, winner valid, 0 script errors. `stress.sh` writes the committable verdict to `docs/gate-evidence/` — commit it.

- [ ] **Step 5: Fill evidence into docs (Task 7 placeholders), commit**

```bash
git add -A docs/gate-evidence/ docs/
git commit -m "test(gate): M8-P3 config+rotation — suite green, rotation smoke PASS, 128-bot stress no-regression PASS"
```

- [ ] **Step 6: Merge via finishing-a-development-branch**

Merge `m8-p3-config-rotation` → master (no push unless owner asks — per standing instruction, push once major goals complete).
