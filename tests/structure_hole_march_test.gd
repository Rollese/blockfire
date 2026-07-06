extends TestCase
## M11 Gate-B — HOLE-AWARE MARCH. A carved chunked piece blocks a shot only where chunks are still
## intact; a cleared chunk is a see-through hole the ray passes through. One bit-test at the ray hit.
## Geometry: a grid-8 wall in cell (0,0,0) spans x:[0,2] y:[0,2] z:[0,2]; yaw 0 -> face is the X-Y
## plane (U = X width, V = Y height), thickness = Z. Rays travel +Z through the FACE.

const CAT := '{"pieces":[{"id":"cwall","height":"full","health":350,"chunk_grid":8}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_intact_wall_blocks_the_shot() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	var r := s.march(Vector3(1.0, 1.0, -3.0), Vector3(0, 0, 1), 50.0)
	assert_eq(r["hit"], true, "a pristine chunked wall blocks like before")
	assert_eq(int(r["id"]), 1)
	assert_almost_eq(float(r["dist"]), 3.0, 0.05, "enters the z=0 face")

func test_shot_passes_through_a_carved_hole() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	# Carve a ~0.6 m hole at the face centre where the ray crosses (1,1,0).
	var hit := s.march(Vector3(1.0, 1.0, -3.0), Vector3(0, 0, 1), 50.0)
	s.damage_chunks(int(hit["id"]), PieceCatalog.SRC_EXPLOSIVE, Vector3(1.0, 1.0, 0.0), 0.6)
	var after := s.march(Vector3(1.0, 1.0, -3.0), Vector3(0, 0, 1), 50.0)
	assert_eq(after["hit"], false, "the shot now passes through the hole it made")

func test_intact_chunk_of_a_carved_wall_still_blocks() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	# Same central hole, but shoot through an OUTER chunk (1.7,1.7) that the hole didn't reach.
	s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, Vector3(1.0, 1.0, 0.0), 0.6)
	var r := s.march(Vector3(1.7, 1.7, -3.0), Vector3(0, 0, 1), 50.0)
	assert_eq(r["hit"], true, "an intact corner of a holed wall still stops the bullet")

func test_grenade_bounce_march_also_passes_through_the_hole() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, Vector3(1.0, 1.0, 0.0), 0.6)
	# march_normal delegates to march, so a grenade flies through the hole instead of bouncing.
	assert_eq(s.march_normal(Vector3(1.0, 1.0, -3.0), Vector3(0, 0, 1), 50.0).get("hit", false), false,
		"a grenade flies through the hole, no bounce")
