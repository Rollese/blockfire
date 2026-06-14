class_name TestCase
extends RefCounted
## Base for all tests. Subclasses define methods named test_*. Asserts append to
## `failures`; a test with no failures and at least one assertion passes.

var failures: Array[String] = []
var assertions: int = 0

func reset() -> void:
	failures = []
	assertions = 0

func fail(msg: String) -> void:
	failures.append(msg)

func assert_true(cond: bool, msg := "") -> void:
	assertions += 1
	if not cond:
		failures.append("assert_true failed: %s" % msg)

func assert_eq(a, b, msg := "") -> void:
	assertions += 1
	if a != b:
		failures.append("assert_eq: %s != %s  %s" % [str(a), str(b), msg])

func assert_almost_eq(a: float, b: float, tol := 0.001, msg := "") -> void:
	assertions += 1
	if absf(a - b) > tol:
		failures.append("assert_almost_eq: %s vs %s (tol %s)  %s" % [str(a), str(b), str(tol), msg])
