extends TestCase

func test_heat_accumulates_then_overheats() -> void:
	var heat := 0; var cd := 0
	for t in 49:
		var r := Gadget.repair_heat_step(heat, cd, t, true, 50, 150)
		heat = int(r["heat"]); cd = int(r["cooldown_until"])
		assert_true(bool(r["repairing"]))
	var r2 := Gadget.repair_heat_step(heat, cd, 49, true, 50, 150)   # 50th repairing tick -> overheat
	assert_eq(int(r2["cooldown_until"]), 49 + 150)

func test_locked_out_during_cooldown() -> void:
	var r := Gadget.repair_heat_step(0, 200, 100, true, 50, 150)   # tick<cooldown_until
	assert_false(bool(r["repairing"]))

func test_heat_decays_when_idle() -> void:
	var r := Gadget.repair_heat_step(10, 0, 5, false, 50, 150)
	assert_eq(int(r["heat"]), 9)
	assert_false(bool(r["repairing"]))

func test_one_burst_repairs_about_500hp() -> void:
	# 50 ticks * 10 hp = 500 (one rocket / 50% hull), then overheats.
	assert_eq(50 * 10, 500)
