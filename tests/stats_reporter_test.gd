extends TestCase

const Reporter := preload("res://server/stats/stats_reporter.gd")

func test_weapon_key_maps_enum_to_lowercase_label() -> void:
	# Weapon.AR == 0; get_def(0)["name"] == "AR"
	assert_eq(Reporter.weapon_key(0), "ar", "AR enum -> 'ar'")

func test_weapon_key_unknown_falls_back() -> void:
	assert_eq(Reporter.weapon_key(9999), "ar", "unknown id -> Weapon fallback name")

func test_no_signing_headers_when_unconfigured() -> void:
	var r = Reporter.new()
	autofree(r)
	r.configure("http://x", "tok", "user://t_unsigned.ndjson")
	var h := r._build_headers('{"a":1}')
	assert_eq(h.size(), 2, "only Authorization + Content-Type when no signing key")

func test_signing_headers_present_when_configured() -> void:
	var r = Reporter.new()
	autofree(r)
	r.configure("http://x", "tok", "user://t_signed.ndjson", "game2-dev-1", "test-secret")
	var h := r._build_headers('{"a":1}')
	assert_eq(h.size(), 5, "Authorization + Content-Type + 3 signing headers")
	assert_true(h[2].begins_with("X-BF-Key-Id: game2-dev-1"), "key id header")
	assert_true(h[3].begins_with("X-BF-Timestamp: "), "timestamp header")
	assert_true(h[4].begins_with("X-BF-Signature: "), "signature header")
