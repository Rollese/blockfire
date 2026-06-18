extends TestCase

func _f(n: int) -> PackedByteArray:
	return PackedByteArray([n])

func test_in_order_pops_in_order() -> void:
	var j := VoiceJitter.new(2)
	assert_true(j.insert(0, _f(0)))
	assert_true(j.insert(1, _f(1)))
	assert_eq(j.pop()["seq"], 0)
	assert_eq(j.pop()["seq"], 1)

func test_reorders_in_window() -> void:
	var j := VoiceJitter.new(3)
	j.insert(2, _f(2)); j.insert(0, _f(0)); j.insert(1, _f(1))
	assert_eq(j.pop()["seq"], 0)
	assert_eq(j.pop()["seq"], 1)
	assert_eq(j.pop()["seq"], 2)

func test_drops_late_and_duplicate() -> void:
	var j := VoiceJitter.new(2)
	j.insert(5, _f(5)); assert_eq(j.pop()["seq"], 5)
	assert_false(j.insert(4, _f(4)), "older than last popped → dropped")
	assert_false(j.insert(5, _f(5)), "duplicate of popped → dropped")

func test_empty_pop_returns_empty_dict() -> void:
	assert_eq(VoiceJitter.new(2).pop(), {})

func test_overflow_drops_oldest() -> void:
	var j := VoiceJitter.new(2)   # capacity depth+1 = 3
	j.insert(0, _f(0)); j.insert(1, _f(1)); j.insert(2, _f(2)); j.insert(3, _f(3))
	assert_eq(j.pop()["seq"], 1, "oldest (0) was evicted on overflow")
