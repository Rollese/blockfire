extends TestCase
## A deployed grapple ladder (in SimLoop.deployed_ladders) is captured + climbed by ANY pawn via
## the same Ladder path as static map ladders, and climbing fully suppresses fire.

func _sim_with_deployed() -> SimLoop:
	var sim := SimLoop.new()
	sim.deployed_ladders = [{"bottom": Vector3(5, 0, 5), "top": Vector3(5, 6, 5),
		"radius": Grapple.LADDER_RADIUS}]
	return sim

func test_capture_ladder_sees_deployed() -> void:
	var sim := _sim_with_deployed()
	var l := sim.capture_ladder(Vector3(5.2, 1.0, 5.0))
	assert_false(l.is_empty(), "deployed ladder captured at the line")

func test_capture_ladder_prefers_static_then_deployed() -> void:
	var sim := _sim_with_deployed()
	sim.ladders = [{"bottom": Vector3(0, 0, 0), "top": Vector3(0, 4, 0), "radius": 0.6}]
	assert_false(sim.capture_ladder(Vector3(0.1, 1.0, 0.0)).is_empty(), "static still works")
	assert_false(sim.capture_ladder(Vector3(5.1, 1.0, 5.0)).is_empty(), "deployed still works")
	# overlap: a static and a deployed ladder share x,z -> static must win
	sim.ladders = [{"bottom": Vector3(9, 0, 9), "top": Vector3(9, 4, 9), "radius": 0.6}]
	sim.deployed_ladders = [{"bottom": Vector3(9, 0, 9), "top": Vector3(9, 8, 9), "radius": Grapple.LADDER_RADIUS}]
	var got := sim.capture_ladder(Vector3(9.1, 1.0, 9.0))
	assert_false(got.is_empty(), "captured at the overlap")
	assert_true(abs(float(got["top"].y) - 4.0) < 0.01, "static ladder (top=4) wins over deployed (top=8)")

func test_climb_engages_and_rises_on_deployed() -> void:
	# Mirror tests/sim_loop_test.gd::test_engages_ladder_and_climbs, but the ladder lives ONLY in
	# deployed_ladders — so the climb must engage via capture_ladder()'s deployed fallback.
	var sim := _sim_with_deployed()
	var p := Pawn.new(1)
	p.pos = Vector3(5, 0, 5)
	sim.world.pawns[1] = p
	for i in 20:
		sim.step({1: {"move_y": 1.0}})   # up-intent each tick
	assert_true(p.pos.y > 1.0, "rose up the deployed ladder")
