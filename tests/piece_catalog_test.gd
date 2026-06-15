extends TestCase

const VALID := '{"pieces":[{"id":"sandbag","height":"half","health":150,"blocks":"both"},{"id":"wall","height":"full","health":350,"blocks":"both"}]}'

func test_loads_valid_catalog() -> void:
	var r := PieceCatalog.from_json_string(VALID)
	assert_true(r["ok"], r["error"])
	var c: PieceCatalog = r["catalog"]
	assert_eq(c.size(), 2)
	assert_eq(c.is_half(0), true)    # sandbag
	assert_eq(c.is_half(1), false)   # wall
	assert_eq(c.health_of(1), 350)
	assert_eq(c.name_of(0), "sandbag")

func test_rejects_empty_pieces() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[]}')["ok"], false)

func test_rejects_bad_height() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"tall","health":10,"blocks":"both"}]}')["ok"], false)

func test_rejects_bad_health() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"full","health":0,"blocks":"both"}]}')["ok"], false)

func test_rejects_duplicate_id() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"full","health":10,"blocks":"both"},{"id":"x","height":"half","health":10,"blocks":"both"}]}')["ok"], false)
