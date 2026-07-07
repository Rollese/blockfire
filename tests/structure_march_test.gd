extends TestCase

const CAT := '{"pieces":[{"id":"sandbag","height":"half","health":150,"blocks":"both"},{"id":"wall","height":"full","health":350,"blocks":"both"}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_march_hits_wall_ahead() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)   # wall AABB x:[4.8,7.2] y:[0,2.4] z:[0,2.4]
	var r := s.march(Vector3(0.0, 1.0, 1.0), Vector3(1, 0, 0), 50.0)
	assert_eq(r["hit"], true)
	assert_eq(r["id"], 1)
	assert_almost_eq(r["dist"], 4.8, 0.6)    # enters the box at x=4.8

func test_march_misses_empty_path() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)
	var r := s.march(Vector3(0.0, 1.0, 1.0), Vector3(0, 0, 1), 50.0)   # parallel, away
	assert_eq(r["hit"], false)

func test_half_piece_blocks_low_ray_only() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(2, 0, 0), 0, 7)   # sandbag AABB y:[0,1]
	# low ray at y=0.5 hits
	assert_eq(s.march(Vector3(0.0, 0.5, 1.0), Vector3(1, 0, 0), 50.0)["hit"], true)
	# high ray at y=1.5 passes over
	assert_eq(s.march(Vector3(0.0, 1.5, 1.0), Vector3(1, 0, 0), 50.0)["hit"], false)

func test_march_returns_nearest_of_two() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(5, 0, 0), 0, 7)   # far
	s.place(2, 1, Vector3i(2, 0, 0), 0, 7)   # near (x=4)
	var r := s.march(Vector3(0.0, 1.0, 1.0), Vector3(1, 0, 0), 50.0)
	assert_eq(r["id"], 2)

func test_march_respects_max_dist() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)   # at x=4
	assert_eq(s.march(Vector3(0.0, 1.0, 1.0), Vector3(1, 0, 0), 3.0)["hit"], false)

func test_resolve_movement_blocks_and_slides() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(1, 0, 0), 0, 7)   # blocks ground cell (1,0,0): x in [2,4), z in [0,2)
	# moving straight into the blocked cell from (1,0,1) toward (3,0,1): X blocked, slide stays put on X
	var out := s.resolve_movement(Vector3(1.0, 0.0, 1.0), Vector3(3.0, 0.0, 1.0))
	assert_eq(BuildGrid.cell_of(Vector3(out.x, 0.0, out.z)) == Vector3i(1, 0, 0), false)

func test_resolve_movement_passes_through_free_space() -> void:
	var s := _store()
	var out := s.resolve_movement(Vector3(0.0, 0.0, 0.0), Vector3(10.0, 0.0, 10.0))
	assert_eq(out, Vector3(10.0, 0.0, 10.0))

func test_march_hits_corner_clipped_cell() -> void:
	# Regression: 0.5 m point-sampling could step OVER a cell the ray crossed for only a
	# short corner clip — occasional through-the-corner bullets on every cover check
	# (fire, rockets, flash LOS, sledge). This diagonal enters cell (1,0,1) on its x=2.4 face
	# (a corner-clipped crossing the DDA must still catch).
	var s := _store()
	s.place(1, 1, Vector3i(1, 0, 1), 0, 7)   # wall AABB x:[2.4,4.8] y:[0,2.4] z:[2.4,4.8]
	var r := s.march(Vector3(0.0, 1.0, 1.9), Vector3(1, 0, 1).normalized(), 10.0)
	assert_eq(r["hit"], true, "corner-clipped wall must stop the bullet")
	assert_almost_eq(float(r["dist"]), 3.394, 0.01, "entry on the x=2.4 face")

func test_march_zero_direction_is_safe() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)
	assert_eq(s.march(Vector3(0.0, 1.0, 1.0), Vector3.ZERO, 10.0)["hit"], false, "degenerate dir: no hit, no hang")

func test_march_normal_front_face() -> void:
	# Grenade-bounce primitive: a ray into the -x face of a wall returns a normal pointing back
	# at the shooter (-x) and the contact point on that face.
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)   # wall AABB x:[4.8,7.2] y:[0,2.4] z:[0,2.4]
	var r := s.march_normal(Vector3(0.0, 1.0, 1.0), Vector3(1, 0, 0), 50.0)
	assert_eq(r["hit"], true)
	assert_eq(r["normal"], Vector3(-1, 0, 0), "hit the -x face; normal faces the shooter")
	assert_almost_eq((r["point"] as Vector3).x, 4.8, 0.05, "contact on the x=4.8 plane")

func test_march_normal_side_face() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)   # wall AABB x:[4,6] z:[0,2]
	var r := s.march_normal(Vector3(5.0, 1.0, 6.0), Vector3(0, 0, -1), 50.0)   # into the +z face
	assert_eq(r["hit"], true)
	assert_eq(r["normal"], Vector3(0, 0, 1), "hit the +z face; normal faces +z")

func test_march_normal_reflection_flips_incoming_velocity() -> void:
	# The bounce reflects v about n (v' = v - 2(v·n)n): a +x throw into a -x face flips x, keeps z.
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)
	var n: Vector3 = s.march_normal(Vector3(0.0, 1.0, 1.0), Vector3(1, 0, 0), 50.0)["normal"]
	var v := Vector3(8.0, -1.0, 2.0)
	var reflected: Vector3 = v - 2.0 * v.dot(n) * n
	assert_true(reflected.x < 0.0, "x component reverses off the wall")
	assert_almost_eq(reflected.z, 2.0, 0.001, "tangential z is unchanged")

func test_march_normal_miss_returns_no_hit() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, 0), 0, 7)
	assert_eq(s.march_normal(Vector3(0.0, 1.0, 1.0), Vector3(0, 0, 1), 50.0).get("hit", false), false)
