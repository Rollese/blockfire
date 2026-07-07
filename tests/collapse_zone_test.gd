extends TestCase
## CollapseZone: the deterministic kill volume a collapsing building crushes (players/vehicles/gear).
## CELL_SIZE is 2.4 m; a cell at grid (x,y,z) spans world x∈[x*2.4, x*2.4+2.4] etc.

# A 2x2 footprint, two courses tall: cells (5,0,5)(6,0,5)(5,0,6)(6,0,6) + (5,1,5).
# Footprint world XZ ∈ [12,16.8]x[12,16.8]; top course y=1 -> top at 4.8 m.
func _cells() -> Array:
	return [Vector3i(5,0,5), Vector3i(6,0,5), Vector3i(5,0,6), Vector3i(6,0,6), Vector3i(5,1,5)]

# Component-wise Vector3 compare (2.4 m cells don't land on exact binary floats -> tolerant).
func _assert_vec(a: Vector3, b: Vector3, msg := "") -> void:
	assert_almost_eq(a.x, b.x, 0.01, msg + " (x)")
	assert_almost_eq(a.y, b.y, 0.01, msg + " (y)")
	assert_almost_eq(a.z, b.z, 0.01, msg + " (z)")

func test_bounds_span_footprint_and_height() -> void:
	var b := CollapseZone.bounds(_cells(), 0.0)
	_assert_vec(b["min"], Vector3(12, 0, 12), "min corner at footprint SW ground")
	_assert_vec(b["max"], Vector3(16.8, 4.8, 16.8), "max corner at footprint NE, top of the y=1 course")

func test_margin_expands_horizontally_only() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	_assert_vec(b["min"], Vector3(10.5, 0, 10.5), "XZ grow by margin; Y unchanged")
	_assert_vec(b["max"], Vector3(18.3, 4.8, 18.3), "XZ grow by margin; Y unchanged")

func test_pawn_inside_footprint_is_crushed() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_true(CollapseZone.contains(b, Vector3(14.4, 0, 14.4)), "dead centre, on the ground")

func test_pawn_on_roof_is_crushed() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_true(CollapseZone.contains(b, Vector3(14.4, 4.7, 14.4)), "standing on the roof (below the top) is crushed")

func test_pawn_in_margin_band_is_crushed() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_true(CollapseZone.contains(b, Vector3(17.5, 0, 14.4)), "just outside the wall but 'very close' (within margin)")

func test_pawn_beyond_margin_survives() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_false(CollapseZone.contains(b, Vector3(19.5, 0, 14.4)), "past the margin band -> safe")

func test_pawn_far_away_survives() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_false(CollapseZone.contains(b, Vector3(40, 0, 40)), "across the map -> safe")

func test_pawn_high_above_survives() -> void:
	var b := CollapseZone.bounds(_cells(), 1.5)
	assert_false(CollapseZone.contains(b, Vector3(14.4, 10, 14.4)), "flying/on a taller neighbour's roof above the top -> safe")

func test_expand_grows_xz_keeps_y_and_reaches_original_edge() -> void:
	# The lethality fix caches the ORIGINAL (marginless) footprint, then expands at collapse time. A
	# pawn at the original wall edge must be crushed even if only a shrunken remnant survives the fall.
	var original := CollapseZone.bounds(_cells(), 0.0)   # footprint of the intact building
	var zone := CollapseZone.expand(original, 1.5)
	_assert_vec(zone["min"], Vector3(10.5, 0, 10.5), "XZ grew by margin")
	_assert_vec(zone["max"], Vector3(18.3, 4.8, 18.3), "XZ grew by margin; Y untouched")
	assert_true(CollapseZone.contains(zone, Vector3(16.8, 0, 14.4)), "on the far wall edge of the intact footprint -> crushed")
	assert_true(CollapseZone.expand({}, 1.5).is_empty(), "expanding an empty footprint stays empty")

func test_empty_building_crushes_nothing() -> void:
	var b := CollapseZone.bounds([], 1.5)
	assert_true(b.is_empty(), "no cells -> no zone")
	assert_false(CollapseZone.contains(b, Vector3(14.4, 0, 14.4)), "empty zone contains nobody")
