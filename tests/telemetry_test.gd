extends TestCase

func test_mean_and_p99() -> void:
	var t := Telemetry.new()
	for i in range(1, 101):
		t.record_tick_ms(float(i))   # 1..100
	assert_almost_eq(t.mean_tick_ms(), 50.5, 0.01)
	assert_almost_eq(t.p99_tick_ms(), 100.0, 0.001)

func test_bytes_accumulate_and_reset() -> void:
	var t := Telemetry.new()
	t.add_bytes(1, 100)
	t.add_bytes(1, 50)
	t.add_bytes(2, 10)
	assert_eq(int(t.bytes_sent_per_client[1]), 150)
	t.reset_window()
	assert_eq(t.bytes_sent_per_client.size(), 0)
	assert_almost_eq(t.mean_tick_ms(), 0.0)
