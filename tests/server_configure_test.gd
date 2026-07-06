extends TestCase
## M8-P3: server configure() resolves config file + CLI with CLI precedence.

const F := preload("res://tests/server_fixture.gd")
const CFG := "/tmp/bf_configure_test.json"

func _write(text: String) -> void:
	var f := FileAccess.open(CFG, FileAccess.WRITE)
	f.store_string(text)
	f.close()

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
	assert_eq(srv._map_path, "res://maps/conquest_town.json")   # default village map (M15 town terrain)

func test_degrade_band_from_config_file() -> void:
	_write('{"degrade_high_ms": 28.0, "degrade_low_ms": 24.0}')
	var srv = F.make_server()
	autofree(srv)
	srv.configure({"config": CFG})
	assert_eq(srv._degrade_high_ms, 28.0)
	assert_eq(srv._degrade_low_ms, 24.0)
