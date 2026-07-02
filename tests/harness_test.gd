extends TestCase
## Self-test for the test harness itself, including the batch-7 upgrades (assert_ne/gt/
## contains, setup/teardown hooks, autofree node tracking, per-test timing, and runtime-
## error detection). Background: a SCRIPT ERROR mid-test did NOT fail the test if
## assertions had already run — the suite showed "996/0" while hiding 5 real script errors.

const TC := preload("res://tests/test_case.gd")


func test_harness_runs_and_asserts() -> void:
	assert_true(true, "trivial")
	assert_eq(1 + 1, 2)
	assert_almost_eq(0.1 + 0.2, 0.3)


func _scratch() -> Variant:
	return TestCase.new()


func test_assert_ne() -> void:
	var t = _scratch()
	t.assert_ne(1, 2, "differs")
	assert_eq(t.failures.size(), 0, "ne on different values passes")
	t.assert_ne(1, 1, "same")
	assert_eq(t.failures.size(), 1, "ne on equal values fails")
	assert_eq(t.assertions, 2, "both calls counted as assertions")


func test_assert_gt() -> void:
	var t = _scratch()
	t.assert_gt(2, 1)
	t.assert_gt(2.5, 2.4)
	assert_eq(t.failures.size(), 0, "strictly greater passes")
	t.assert_gt(1, 1)
	t.assert_gt(1, 2)
	assert_eq(t.failures.size(), 2, "equal and less both fail")


func test_assert_contains_string_and_array() -> void:
	var t = _scratch()
	t.assert_contains("hello world", "world")
	t.assert_contains([1, 2, 3], 2)
	assert_eq(t.failures.size(), 0, "substring and array element pass")
	t.assert_contains("hello", "xyz")
	t.assert_contains([1, 2], 9)
	assert_eq(t.failures.size(), 2, "missing substring and element both fail")


func test_autofree_frees_tracked_nodes() -> void:
	var t = _scratch()
	var n = t.autofree(Node.new())
	assert_true(n is Node, "autofree returns the node for inline use")
	assert_true(is_instance_valid(n), "alive during the test")
	t.cleanup_tracked()
	assert_false(is_instance_valid(n), "freed after cleanup")
	# RefCounted args are tolerated (just dropped), and cleanup twice is safe.
	t.autofree(RefCounted.new())
	t.cleanup_tracked()
	t.cleanup_tracked()
	assert_true(true, "cleanup is idempotent and type-tolerant")


class HookFixture extends TestCase:
	var order: Array = []
	func setup() -> void:
		order.append("setup")
	func teardown() -> void:
		order.append("teardown")
	func test_noop() -> void:
		order.append("test")
		assert_true(true)


func test_run_one_calls_setup_then_test_then_teardown() -> void:
	var f := HookFixture.new()
	var res: Dictionary = TC.run_one(f, "test_noop")
	assert_eq(f.order, ["setup", "test", "teardown"], "hooks bracket the test method")
	assert_false(bool(res["failed"]), "clean fixture passes")
	assert_true(float(res["ms"]) >= 0.0, "per-test duration is measured")


class EmptyFixture extends TestCase:
	func test_nothing() -> void:
		pass


func test_run_one_zero_assertions_fails() -> void:
	var res: Dictionary = TC.run_one(EmptyFixture.new(), "test_nothing")
	assert_true(bool(res["failed"]), "a test that asserts nothing fails")
	assert_true(String((res["reasons"] as Array)[0]).contains("no assertions"),
		"reason names the zero-assertion rule")


class ErrStub extends RefCounted:
	var count := 0


class ErrFixture extends TestCase:
	var stub: ErrStub
	var tolerate := false
	func test_boom() -> void:
		if tolerate:
			tolerate_runtime_errors()
		assert_true(true)
		stub.count += 1   # simulates the engine logging a SCRIPT ERROR mid-test


func test_run_one_fails_on_runtime_error_tally() -> void:
	var f := ErrFixture.new()
	f.stub = ErrStub.new()
	var res: Dictionary = TC.run_one(f, "test_boom", f.stub)
	assert_true(bool(res["failed"]), "a script error mid-test fails it even after assertions ran")
	var joined := " ".join((res["reasons"] as Array))
	assert_true(joined.to_lower().contains("runtime"), "reason names the runtime error")


func test_run_one_tolerates_declared_errors() -> void:
	var f := ErrFixture.new()
	f.stub = ErrStub.new()
	f.tolerate = true
	var res: Dictionary = TC.run_one(f, "test_boom", f.stub)
	assert_false(bool(res["failed"]), "tolerate_runtime_errors() opts a test out")


func test_error_tally_counts_errors_not_warnings() -> void:
	tolerate_runtime_errors()   # the push_error below is intentional
	var tally := preload("res://tests/error_tally.gd").new()
	OS.add_logger(tally)
	var before: int = tally.count
	push_warning("harness_test: intentional warning (must not count)")
	assert_eq(int(tally.count), before, "warnings are not errors")
	push_error("harness_test: intentional error (must count)")
	assert_eq(int(tally.count), before + 1, "push_error is tallied")
	OS.remove_logger(tally)
