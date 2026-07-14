extends TestCase
## Pure geometry for the two nest-destruction vectors (emplacement_server.gd:156 deferral):
## Emplacement.nearest_meleeable (sledgehammer frontal-reach pick) and Emplacement.ray_hits_nest
## (small-arms bullet-chip ray-vs-parapet). Side-effect-free — the server applies the damage.

func _nest(id: int, pos: Vector3, facing: float = 0.0, alive: bool = true, team: int = 1) -> Emplacement:
	var e := Emplacement.make(id, 7, team, pos, facing, {"hp": 500, "belt": 150})
	e.alive = alive
	return e

# ---- nearest_meleeable -------------------------------------------------------

func test_melee_picks_a_nest_in_frontal_reach() -> void:
	var nests := {101: _nest(101, Vector3(0, 0, 5))}
	# attacker 2 m in front, facing +Z (yaw 0)
	assert_eq(Emplacement.nearest_meleeable(Vector3(0, 0, 3), 0.0, nests), 101)

func test_melee_ignores_a_nest_behind_the_attacker() -> void:
	var nests := {101: _nest(101, Vector3(0, 0, 5))}
	# facing -Z (yaw PI): the nest is behind -> no hit
	assert_eq(Emplacement.nearest_meleeable(Vector3(0, 0, 3), PI, nests), 0)

func test_melee_ignores_a_nest_beyond_reach() -> void:
	var nests := {101: _nest(101, Vector3(0, 0, 5))}
	# 5 m away > MELEE_RANGE (2.2)
	assert_eq(Emplacement.nearest_meleeable(Vector3(0, 0, 0), 0.0, nests), 0)

func test_melee_skips_a_dead_nest() -> void:
	var nests := {101: _nest(101, Vector3(0, 0, 5), 0.0, false)}
	assert_eq(Emplacement.nearest_meleeable(Vector3(0, 0, 3), 0.0, nests), 0)

func test_melee_is_team_agnostic() -> void:
	# a friendly nest (team 1) is still meleeable — the sledge tears down ANY nest
	var nests := {101: _nest(101, Vector3(0, 0, 5), 0.0, true, 1)}
	assert_eq(Emplacement.nearest_meleeable(Vector3(0, 0, 3), 0.0, nests), 101)

func test_melee_picks_the_nearest_of_several() -> void:
	var nests := {
		101: _nest(101, Vector3(0, 0, 5)),   # 2 m
		102: _nest(102, Vector3(0, 0, 4)),   # 1 m (nearer)
	}
	assert_eq(Emplacement.nearest_meleeable(Vector3(0, 0, 3), 0.0, nests), 102)

# ---- ray_hits_nest -----------------------------------------------------------

func test_bullet_enters_the_parapet_front_face() -> void:
	var e := _nest(101, Vector3.ZERO)   # facing +Z; box front slab at z=-0.4
	var t := Emplacement.ray_hits_nest(Vector3(0, 1, -5), Vector3(0, 0, 1), 10.0, e)
	assert_almost_eq(t, 4.6, 0.001)     # -5 -> -0.4 = 4.6

func test_bullet_misses_wide_of_the_parapet() -> void:
	var e := _nest(101, Vector3.ZERO)
	# x = 5 is outside the +/-1.1 width
	assert_almost_eq(Emplacement.ray_hits_nest(Vector3(5, 1, -5), Vector3(0, 0, 1), 10.0, e), -1.0, 0.001)

func test_bullet_over_the_top_misses() -> void:
	var e := _nest(101, Vector3.ZERO)
	# y = 3 is above the 1.92 m parapet top
	assert_almost_eq(Emplacement.ray_hits_nest(Vector3(0, 3, -5), Vector3(0, 0, 1), 10.0, e), -1.0, 0.001)

func test_bullet_segment_too_short_does_not_reach() -> void:
	var e := _nest(101, Vector3.ZERO)
	# entry is at 4.6 but the segment is only 2 m
	assert_almost_eq(Emplacement.ray_hits_nest(Vector3(0, 1, -5), Vector3(0, 0, 1), 2.0, e), -1.0, 0.001)

func test_ray_test_respects_nest_facing() -> void:
	# nest rotated to face +X: an east-bound ray must still enter the (now rotated) front face
	var e := _nest(101, Vector3.ZERO, PI * 0.5)
	var t := Emplacement.ray_hits_nest(Vector3(-5, 1, 0), Vector3(1, 0, 0), 10.0, e)
	assert_almost_eq(t, 4.6, 0.001)

func test_dead_nest_is_never_hit() -> void:
	var e := _nest(101, Vector3.ZERO, 0.0, false)
	assert_almost_eq(Emplacement.ray_hits_nest(Vector3(0, 1, -5), Vector3(0, 0, 1), 10.0, e), -1.0, 0.001)
