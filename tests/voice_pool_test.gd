extends TestCase

const HIGH := 2
const MED := 1
const LOW := 0
const CRIT := 3

func test_allocates_into_free_slots() -> void:
	var pool := VoicePool.new(2)
	var a := pool.request(MED, 0.8)
	var b := pool.request(MED, 0.8)
	assert_true(a["slot"] >= 0, "first allocation gets a slot")
	assert_true(b["slot"] >= 0 and b["slot"] != a["slot"], "second gets a different slot")
	assert_eq(a["evicted"], -1, "no eviction when free slots exist")

func test_full_pool_steals_lowest_priority() -> void:
	var pool := VoicePool.new(1)
	var low := pool.request(LOW, 0.9)
	var high := pool.request(HIGH, 0.2)
	assert_eq(high["slot"], low["slot"], "high steals the low-priority slot")
	assert_eq(high["evicted"], low["slot"], "returns the evicted slot id so director stops it")

func test_equal_priority_steals_only_if_louder() -> void:
	var pool := VoicePool.new(1)
	var loud := pool.request(MED, 0.9)
	var quiet_req := pool.request(MED, 0.3)
	assert_eq(quiet_req["slot"], -1, "equal priority + quieter = dropped")
	var louder := pool.request(MED, 0.99)
	assert_eq(louder["slot"], loud["slot"], "equal priority + louder = steals")

func test_weaker_request_is_dropped_when_full() -> void:
	var pool := VoicePool.new(1)
	pool.request(HIGH, 0.9)
	var weak := pool.request(LOW, 0.9)
	assert_eq(weak["slot"], -1, "lower priority can't steal a higher one")
	assert_eq(weak["evicted"], -1, "dropped request evicts nothing")

func test_release_frees_a_slot() -> void:
	var pool := VoicePool.new(1)
	var a := pool.request(HIGH, 0.9)
	pool.release(a["slot"])
	var b := pool.request(LOW, 0.1)
	assert_eq(b["slot"], a["slot"], "released slot is reusable by anyone")

func test_critical_steals_a_looping_engine_voice() -> void:
	var pool := VoicePool.new(1)
	var engine := pool.request(MED, 0.5)   # looping engine holds a slot
	var boom := pool.request(CRIT, 0.1)
	assert_eq(boom["slot"], engine["slot"], "critical explosion steals the engine loop")

func test_survivors_are_top_n_by_priority_then_gain() -> void:
	var pool := VoicePool.new(2)
	pool.request(LOW, 0.9)    # slot 0
	pool.request(MED, 0.4)    # slot 1
	var hi := pool.request(HIGH, 0.1)  # steals the LOW (weakest by priority)
	assert_true(hi["slot"] >= 0, "high allocated")
	assert_true(pool.active_priorities().has(MED), "MED survived")
	assert_true(pool.active_priorities().has(HIGH), "HIGH survived")
	assert_false(pool.active_priorities().has(LOW), "LOW was evicted as weakest")
