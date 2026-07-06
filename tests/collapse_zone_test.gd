extends TestCase
## CollapseZone: the deterministic kill volume a collapsing building crushes (players/vehicles/gear).
## CELL_SIZE is 2 m; a cell at grid (x,y,z) spans world x∈[x*2, x*2+2] etc.

# A 2x2 footprint, two courses tall: cells (5,0,5)(6,0,5)(5,0,6)(6,0,6) + (5,1,5).
# Footprint world XZ ∈ [10,14]x[10,14]; top course y=1 -> top at 4 m.
func _cells() -> Array:
	return [Vector3i(5,0,5), Vector3i(6,0,5), Vector3i(5,0,6), Vector3i(6,0,6), Vector3i(5,1,5)]

func test_bounds_span_footprint_and_height() -> void:
	var b := CollapseZone.bounds(_cells(), 0.0)
	assert_eq(b["min"], Vector3(10, 0, 10), "min corner at footprint SW ground")
	assert_eq(b["max"], Vector3(14, 4, 14), "max corner at footprint NE, top of the y=1 course")

func test_margin_expands_horizontally_only() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_eq(b["min"], Vector3(8.5, 0, 8.5), "XZ grow by margin; Y unchanged")
	assert_eq(b["max"], Vector3(15.5, 4, 15.5), "XZ grow by margin; Y unchanged")

func test_pawn_inside_footprint_is_crushed() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_true(CollapseZone.contains(b, Vector3(12, 0, 12)), "dead centre, on the ground")

func test_pawn_on_roof_is_crushed() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_true(CollapseZone.contains(b, Vector3(12, 3.9, 12)), "standing on the roof (below the top) is crushed")

func test_pawn_in_margin_band_is_crushed() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_true(CollapseZone.contains(b, Vector3(15, 0, 12)), "just outside the wall but 'very close' (within margin)")

func test_pawn_beyond_margin_survives() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_false(CollapseZone.contains(b, Vector3(16.5, 0, 12)), "past the margin band -> safe")

func test_pawn_far_away_survives() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_false(CollapseZone.contains(b, Vector3(40, 0, 40)), "across the map -> safe")

func test_pawn_high_above_survives() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_false(CollapseZone.contains(b, Vector3(12, 10, 12)), "flying/on a taller neighbour's roof above the top -> safe")

func test_empty_building_crushes_nothing() -> void:
	var b := CollapseZone.bounds([], 1.5)
	assert_true(b.is_empty(), "no cells -> no zone")
	assert_false(CollapseZone.contains(b, Vector3(12, 0, 12)), "empty zone contains nobody")
