extends TestCase
## M11 Gate-B feel: a whole-building collapse leaves a rubble FIELD scaled to the building's footprint
## (was a single fixed ~3 m mound regardless of size). Locks the two contract points: a single-cell
## footprint collapses to exactly one mound (old behaviour), and a large footprint tiles many.

func _rubble_children(wr: WorldRenderer) -> int:
	# _place_rubble_field add_child()s one Node3D per mound onto the renderer; count them.
	return wr.get_child_count()

func test_single_cell_footprint_is_one_mound() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	var before := _rubble_children(wr)
	wr._place_rubble_field(Vector3.ZERO, 1.0, 1.0, 3.0)
	assert_eq(_rubble_children(wr) - before, 1, "a single-cell building collapses to one centred mound")

func test_large_footprint_tiles_many_mounds() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	var before := _rubble_children(wr)
	wr._place_rubble_field(Vector3.ZERO, 8.0, 8.0, 9.0)
	var n := _rubble_children(wr) - before
	assert_true(n > 4, "a large footprint leaves a broad rubble field, not one pebble (%d mounds)" % n)
	assert_true(n <= 64, "mound count is bounded (8x8 cap) so a huge building can't blow the node budget")

func test_field_is_deterministic() -> void:
	# No RNG — the same footprint must place the same number of mounds every run (replay-safe).
	var a: WorldRenderer = autofree(WorldRenderer.new())
	var b: WorldRenderer = autofree(WorldRenderer.new())
	a._place_rubble_field(Vector3(5, 0, -5), 6.0, 4.0, 7.0)
	b._place_rubble_field(Vector3(5, 0, -5), 6.0, 4.0, 7.0)
	assert_eq(a.get_child_count(), b.get_child_count(), "rubble field is deterministic")
