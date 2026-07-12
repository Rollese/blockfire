extends TestCase

const Signer := preload("res://server/stats/stats_signer.gd")

func test_golden_vector_matches_python() -> void:
	var body := '{"match_id":"m-golden","batch_seq":0,"events":[]}'.to_utf8_buffer()
	var sig := Signer.sign("game2-dev-1", "test-secret", 1752307200, body)
	assert_eq(sig, "a25a99340ae1d0bb369662ea87f2a536d19588292d856a35ec2f3395e1169585",
		"GDScript HMAC must match the Python verifier golden vector")

func test_headers_assembled() -> void:
	var h := Signer.headers("game2-dev-1", 1752307200, "deadbeef")
	assert_eq(h.size(), 3, "three signing headers")
	assert_eq(h[0], "X-BF-Key-Id: game2-dev-1")
	assert_eq(h[1], "X-BF-Timestamp: 1752307200")
	assert_eq(h[2], "X-BF-Signature: deadbeef")

func test_empty_secret_returns_empty() -> void:
	var sig := Signer.sign("k", "", 1, "x".to_utf8_buffer())
	assert_eq(sig, "", "empty secret yields no signature")
