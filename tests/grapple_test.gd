extends TestCase
## Pure Grapple rules: vertical-anchor resolution (range + min-height) and cut eligibility.

func test_valid_anchor_resolves_vertical_line() -> void:
	# origin at ground, hit a wall lip 6 m up and 10 m ahead; ground below the anchor is y=0.
	var r := Grapple.resolve(Vector3(0, 1.6, 0), Vector3(10, 6, 0), 0.0, true)
	assert_true(bool(r["ok"]), "in-range, tall-enough hit resolves")
	assert_eq(float(r["x"]), 10.0, "ladder x = anchor x")
	assert_eq(float(r["z"]), 0.0, "ladder z = anchor z")
	assert_eq(float(r["bottom_y"]), 0.0, "bottom = ground_y")
	assert_eq(float(r["top_y"]), 6.0, "top = hit y")

func test_no_surface_rejected() -> void:
	var r := Grapple.resolve(Vector3(0, 1.6, 0), Vector3.ZERO, 0.0, false)
	assert_false(bool(r["ok"]), "no hit -> reject")

func test_out_of_range_rejected() -> void:
	var far := Vector3(0, 6, 0) + Vector3(0, 0, Grapple.MAX_RANGE + 5.0)
	var r := Grapple.resolve(Vector3.ZERO, far, 0.0, true)
	assert_false(bool(r["ok"]), "beyond MAX_RANGE -> reject")

func test_too_short_rejected() -> void:
	# hit only 1 m above ground (< MIN_HEIGHT) -> no stubby ground ropes
	var r := Grapple.resolve(Vector3(0, 1.6, 0), Vector3(5, 1.0, 0), 0.0, true)
	assert_false(bool(r["ok"]), "below MIN_HEIGHT -> reject")

func test_can_cut_arm_and_radius() -> void:
	assert_false(Grapple.can_cut(Grapple.CUT_ARM_TICKS - 1, 1.0), "not armed yet")
	assert_false(Grapple.can_cut(Grapple.CUT_ARM_TICKS + 10, Grapple.CUT_RADIUS + 0.5), "out of radius")
	assert_true(Grapple.can_cut(Grapple.CUT_ARM_TICKS, Grapple.CUT_RADIUS), "armed + in radius")

func test_charges_is_one() -> void:
	assert_eq(Grapple.CHARGES, 1, "single-use per life")

func test_exactly_at_max_range_accepted() -> void:
	# hit exactly MAX_RANGE away, tall enough -> accepted (range check is strict '>')
	var r := Grapple.resolve(Vector3.ZERO, Vector3(0, Grapple.MAX_RANGE, 0), 0.0, true)
	assert_true(bool(r["ok"]), "exactly at MAX_RANGE still resolves")

func test_exactly_at_min_height_accepted() -> void:
	# top-minus-ground exactly MIN_HEIGHT -> accepted (height check is strict '<')
	var r := Grapple.resolve(Vector3(0, 1.6, 0), Vector3(3, Grapple.MIN_HEIGHT, 0), 0.0, true)
	assert_true(bool(r["ok"]), "exactly at MIN_HEIGHT still resolves")
