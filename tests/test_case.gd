class_name TestCase
extends RefCounted
## Base for all tests. Subclasses define methods named test_*. Asserts append to
## `failures`; a test with no failures and at least one assertion passes.
## Optional per-test hooks: setup() runs before each test, teardown() after (always,
## even when the test failed). autofree(node) hands a Node to the harness to free after
## the test. A runtime SCRIPT ERROR during a test fails it (see run_one); a test that
## deliberately exercises an error path opts out with tolerate_runtime_errors().

var failures: Array[String] = []
var assertions: int = 0
var _tracked: Array = []
var _tolerate_errors := false

func reset() -> void:
	failures = []
	assertions = 0
	_tracked = []
	_tolerate_errors = false

## Per-test hooks — override in subclasses when needed.
func setup() -> void:
	pass

func teardown() -> void:
	pass

## Register a Node to be freed after the test. Returns it so tests can write
## `var srv := autofree(ServerMain.new())`. Non-Node values are tolerated (just dropped).
func autofree(node):
	_tracked.append(node)
	return node

func cleanup_tracked() -> void:
	for n in _tracked:
		if n is Node and is_instance_valid(n):
			n.free()
	_tracked = []

## Declare that this test intentionally triggers engine errors (push_error / SCRIPT ERROR)
## so the runtime-error check must not fail it.
func tolerate_runtime_errors() -> void:
	_tolerate_errors = true

func fail(msg: String) -> void:
	failures.append(msg)

func assert_true(cond: bool, msg := "") -> void:
	assertions += 1
	if not cond:
		failures.append("assert_true failed: %s" % msg)

func assert_false(cond: bool, msg := "") -> void:
	assertions += 1
	if cond:
		failures.append("assert_false failed: %s" % msg)

func assert_eq(a, b, msg := "") -> void:
	assertions += 1
	if a != b:
		failures.append("assert_eq: %s != %s  %s" % [str(a), str(b), msg])

func assert_ne(a, b, msg := "") -> void:
	assertions += 1
	if a == b:
		failures.append("assert_ne: both are %s  %s" % [str(a), msg])

func assert_gt(a, b, msg := "") -> void:
	assertions += 1
	if not (a > b):
		failures.append("assert_gt: %s <= %s  %s" % [str(a), str(b), msg])

func assert_contains(haystack, needle, msg := "") -> void:
	assertions += 1
	var found := false
	if haystack is String:
		found = (haystack as String).contains(str(needle))
	elif haystack is Array:
		found = (haystack as Array).has(needle)
	else:
		failures.append("assert_contains: unsupported haystack type %s  %s" % [type_string(typeof(haystack)), msg])
		return
	if not found:
		failures.append("assert_contains: %s not in %s  %s" % [str(needle), str(haystack), msg])

func assert_almost_eq(a: float, b: float, tol := 0.001, msg := "") -> void:
	assertions += 1
	if absf(a - b) > tol:
		failures.append("assert_almost_eq: %s vs %s (tol %s)  %s" % [str(a), str(b), str(tol), msg])


## Run one test method with the full lifecycle: reset -> setup -> test -> teardown ->
## cleanup_tracked, then evaluate. `tally` is any object with an int `count` property that
## increases when the engine logs an error (TestErrorTally in production; stubs in tests).
## GDScript runtime errors abort the erroring function but not the caller, so teardown and
## cleanup still run after a mid-test SCRIPT ERROR.
static func run_one(inst: TestCase, method: String, tally = null) -> Dictionary:
	var errs_before: int = tally.count if tally != null else 0
	var t0 := Time.get_ticks_usec()
	inst.reset()
	inst.setup()
	inst.call(method)
	inst.teardown()
	inst.cleanup_tracked()
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var reasons: Array = inst.failures.duplicate()
	if inst.assertions == 0:
		reasons.append("no assertions ran (possible compile error / nonexistent call)")
	if tally != null and not inst._tolerate_errors:
		var errs: int = tally.count - errs_before
		if errs > 0:
			reasons.append("%d runtime SCRIPT ERROR(s) during test — see log above (tolerate_runtime_errors() if intentional)" % errs)
	return {"failed": not reasons.is_empty(), "reasons": reasons, "ms": ms}
