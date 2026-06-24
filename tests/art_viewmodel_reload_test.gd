extends TestCase
## Reload viewmodel anim (M7): cants the gun inward/down to work the mag, returns to rest at the ends.

func test_reload_rests_at_both_ends() -> void:
	var a := ViewmodelAnim.sample(ViewmodelAnim.RELOAD, 0.0)
	assert_true((a["pos"] as Vector3).length() < 0.01, "starts at rest")
	# t>=1 is the no-op guard; 0.999 is the tail of the ramp-down envelope.
	var b := ViewmodelAnim.sample(ViewmodelAnim.RELOAD, 0.999)
	assert_true((b["pos"] as Vector3).length() < 0.02, "returns toward rest at the end")

func test_reload_cants_the_gun_inward_mid() -> void:
	var m := ViewmodelAnim.sample(ViewmodelAnim.RELOAD, 0.5)
	assert_true((m["pos"] as Vector3).y < 0.0, "gun lowers during the reload")
	assert_true((m["rot"] as Vector3).z < 0.0, "gun rolls inward to show the magwell")

func test_reload_out_of_range_is_rest() -> void:
	var z := ViewmodelAnim.sample(ViewmodelAnim.RELOAD, 1.5)
	assert_eq(z["pos"], Vector3.ZERO, "finished anim is a no-op")
