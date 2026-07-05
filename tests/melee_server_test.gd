extends TestCase
## M7 playtest fix: melee resolved against PRESENT-time positions with no lag comp, so a moving target
## was never where the attacker saw it and the tiny reach missed — backstabs did no damage. Melee now
## carries the attacker's view tick and rewinds targets like bullets do.

const F := preload("res://tests/server_fixture.gd")

func _setup_backstab(srv) -> Array:
	# Attacker at origin facing +z; victim 1m in front also facing +z -> attacker is behind = backstab.
	var atk: Pawn = F.add_pawn(srv, 1, 0, Vector3.ZERO)
	atk.yaw = 0.0
	F.add_client(srv, 1, 0, true)
	var vic: Pawn = F.add_pawn(srv, 2, 1, Vector3(0, 0, 1.0))
	vic.yaw = 0.0
	srv._sim.tick = 100
	srv._lag.record(100, srv._sim.world)   # record the victim at 1m (in reach)
	vic.pos = Vector3(0, 0, 5.0)            # victim then sprints out of present reach
	srv._sim.tick = 104
	return [atk, vic]

func test_melee_lag_compensates_moving_target() -> void:
	var srv = autofree(F.make_server())
	var pawns := _setup_backstab(srv)
	var vic: Pawn = pawns[1]
	srv._resolve_melee(1, 100)   # view tick 100: rewind victim back to 1m -> backstab instant-kill
	assert_false(vic.alive, "lag-comp melee backstab-kills the target at the view tick")

func test_melee_present_time_misses_moved_target() -> void:
	var srv = autofree(F.make_server())
	var pawns := _setup_backstab(srv)
	var vic: Pawn = pawns[1]
	srv._resolve_melee(1, 0)   # no view tick -> present-time only; victim is 5m away, out of reach
	assert_true(vic.alive, "without lag-comp the melee misses the moved target (proves rewind is load-bearing)")
