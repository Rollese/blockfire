class_name TestCase
extends RefCounted
## Base for all tests. Subclasses define methods named test_*. Asserts append to
## `failures`; a test with no failures passes.

var failures: Array[String] = []

func reset() -> void:
	failures = []

func fail(msg: String) -> void:
	failures.append(msg)

func assert_true(cond: bool, msg := "") -> void:
	if not cond:
		failures.append("assert_true failed: %s" % msg)

func assert_eq(a, b, msg := "") -> void:
	if a != b:
		failures.append("assert_eq: %s != %s  %s" % [str(a), str(b), msg])

func assert_almost_eq(a: float, b: float, tol := 0.001, msg := "") -> void:
	if absf(a - b) > tol:
		failures.append("assert_almost_eq: %s vs %s (tol %s)  %s" % [str(a), str(b), str(tol), msg])
