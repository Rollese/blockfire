extends TestCase
## M12 client build-placement: the pure build-tool state machine + aim/placement geometry.

func _cat() -> PieceCatalog:
	return PieceCatalog.load_file("res://pieces/pieces.json")

func _sandbag() -> int: return _cat().index_of("sandbag")
func _fob() -> int: return _cat().index_of("fob")

func test_cycle_wraps_over_buildable_fortifications() -> void:
	var bc := BuildController.new(_cat())
	var seen := {}
	for _i in 8:   # cycle well past the list length to prove it wraps
		seen[bc.current_type(false)] = true
		bc.cycle(1, false)
	# Non-leader cycle = sandbag/wall/heavy_barricade (3 fortifications), never the FOB.
	assert_eq(seen.size(), 3, "non-leader cycles exactly the 3 buildable fortifications")
	assert_false(seen.has(_fob()), "FOB never offered to a non-leader")

func test_leader_cycle_includes_fob() -> void:
	var bc := BuildController.new(_cat())
	var seen := {}
	for _i in 8:
		seen[bc.current_type(true)] = true
		bc.cycle(1, true)
	assert_true(seen.has(_fob()), "leader can cycle to the FOB")
	assert_eq(seen.size(), 4, "leader cycle = 3 fortifications + FOB")

func test_current_is_fob_only_for_leader_on_fob_entry() -> void:
	var bc := BuildController.new(_cat())
	# advance to the FOB entry (last in the leader cycle)
	while bc.current_type(true) != _fob():
		bc.cycle(1, true)
	assert_true(bc.current_is_fob(true), "on the FOB entry as leader -> is_fob")
	assert_false(bc.current_is_fob(false), "same index as non-leader never resolves to the FOB")

func test_rotate_wraps_yaw_steps() -> void:
	var bc := BuildController.new(_cat())
	assert_eq(bc.yaw, 0, "starts unrotated")
	for _i in BuildGrid.YAW_STEPS:
		bc.rotate()
	assert_eq(bc.yaw, 0, "rotating YAW_STEPS times returns to 0")
	bc.rotate()
	assert_eq(bc.yaw, 1, "one more step advances by one")

func test_aimed_cell_projects_down_ray_to_ground() -> void:
	var bc := BuildController.new(_cat())
	# Eye 1.7 m up, looking forward+down; the ground hit should land ahead on the y==0 plane.
	var eye := Vector3(0, 1.7, 0)
	var fwd := Vector3(0, -0.5, 1).normalized()
	var cell := bc.aimed_cell(eye, fwd)
	assert_eq(cell.y, 0, "ground placement is at cell layer 0")
	assert_true(cell.z >= 1, "hit lands ahead of the eye in +Z")
	var hit := BuildGrid.world_of(cell)
	assert_true(hit.length() <= BuildController.BUILD_REACH + BuildGrid.CELL_SIZE, "within build reach")

func test_aimed_cell_clamps_reach_when_level() -> void:
	var bc := BuildController.new(_cat())
	# Looking level (no downward component): place at reach ahead, snapped to the ground layer.
	var cell := bc.aimed_cell(Vector3(0, 1.7, 0), Vector3(0, 0, 1))
	assert_eq(cell.y, 0, "still ground layer")
	assert_true(cell.z >= 1, "placed ahead, not at the eye")

func test_placement_valid_rejects_occupied_cell() -> void:
	var bc := BuildController.new(_cat())
	var cell := Vector3i(2, 0, 3)
	var structs := {7: {"cell": cell, "under_construction": 0}}
	assert_false(bc.placement_valid(cell, structs), "cannot place on an occupied cell")
	assert_true(bc.placement_valid(Vector3i(2, 0, 4), structs), "an empty in-bounds cell is valid")

func test_action_at_shovel_over_site_place_on_empty() -> void:
	var bc := BuildController.new(_cat())
	var site_cell := Vector3i(5, 0, 5)
	var structs := {9: {"cell": site_cell, "under_construction": 1}}
	assert_eq(bc.action_at(site_cell, structs), BuildController.SHOVEL, "aiming at a site -> shovel")
	assert_eq(bc.action_at(Vector3i(6, 0, 5), structs), BuildController.PLACE, "empty valid cell -> place")
	# A completed structure occupies its cell -> neither place nor shovel.
	var built := {9: {"cell": site_cell, "under_construction": 0}}
	assert_eq(bc.action_at(site_cell, built), BuildController.NONE, "completed piece blocks placement")
