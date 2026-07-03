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
