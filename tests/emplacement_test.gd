extends TestCase

func _make() -> Emplacement:
	# facing +Z (yaw 0), 90-deg total arc, 500 hp, belt 150
	return Emplacement.make(Emplacement.id_for(0), 7, 1, Vector3(10, 0, 20), 0.0,
		{"hp": 500, "half_arc_deg": 45, "pitch_lo_deg": 20, "pitch_hi_deg": 25, "belt": 150})

func test_traverse_clamps_within_arc() -> void:
	assert_almost_eq(Emplacement.clamp_yaw(deg_to_rad(30), 0.0, deg_to_rad(45)), deg_to_rad(30), 0.001)
	assert_almost_eq(Emplacement.clamp_yaw(deg_to_rad(80), 0.0, deg_to_rad(45)), deg_to_rad(45), 0.001)
	assert_almost_eq(Emplacement.clamp_yaw(deg_to_rad(-80), 0.0, deg_to_rad(45)), deg_to_rad(-45), 0.001)

func test_traverse_clamp_is_wrap_aware() -> void:
	# facing near +PI; an aim just across the -PI seam must clamp relative to facing, not jump 2PI
	var facing := PI - 0.1
	var out := Emplacement.clamp_yaw(-PI + 0.2, facing, deg_to_rad(45))
	assert_true(absf(Emplacement.ang_diff(out, facing)) <= deg_to_rad(45) + 0.001)
	# result must be normalized into (-PI, PI] so it never overflows i16 yaw packing
	assert_true(out <= PI + 0.0001 and out >= -PI - 0.0001, "clamp_yaw result normalized")

func test_pitch_clamps_asymmetric() -> void:
	assert_almost_eq(Emplacement.clamp_pitch(deg_to_rad(40), deg_to_rad(20), deg_to_rad(25)), deg_to_rad(25), 0.001)
	assert_almost_eq(Emplacement.clamp_pitch(deg_to_rad(-40), deg_to_rad(20), deg_to_rad(25)), deg_to_rad(-20), 0.001)

func test_can_mount_gates() -> void:
	var e := _make()
	var p := Pawn.new(); p.team = 1; p.alive = true; p.is_downed = false; p.mounted_nest = 0
	assert_true(Emplacement.can_mount(e, p, 1.0, 1.6))
	assert_false(Emplacement.can_mount(e, p, 3.0, 1.6), "out of range")
	p.team = 0
	assert_false(Emplacement.can_mount(e, p, 1.0, 1.6), "enemy team (v1 friendly only)")
	p.team = 1; e.occupant = 5
	assert_false(Emplacement.can_mount(e, p, 1.0, 1.6), "already manned")

func test_heat_step_overheats_then_cools() -> void:
	var s := Emplacement.heat_step(89, 0, 100, true, 90, 90)
	assert_true(int(s["overheated_until"]) > 100, "overheats at cap")
	assert_true(Emplacement.overheated(int(s["overheated_until"]), 120))
	assert_false(Emplacement.overheated(int(s["overheated_until"]), 300))
	# still-locked: another firing step while locked keeps heat 0 and the lockout unchanged
	var locked := Emplacement.heat_step(0, int(s["overheated_until"]), 120, true, 90, 90)
	assert_eq(int(locked["heat"]), 0)
	assert_eq(int(locked["overheated_until"]), int(s["overheated_until"]))
	var d := Emplacement.heat_step(50, 0, 500, false, 90, 90)
	assert_eq(int(d["heat"]), 49)

func test_mark_destroyed_clears_occupant() -> void:
	var e := _make(); e.occupant = 5; e.hit(600, 100)
	assert_false(e.alive)
	assert_eq(e.occupant, 0)

func test_seat_and_muzzle_offset_by_facing() -> void:
	var e := _make()
	var m := e.muzzle()
	assert_gt(m.z, e.pos.z)   # facing +Z -> muzzle forward in +Z
	assert_true(e.seat_world().z < e.pos.z, "seat is behind the pivot for +Z facing")

func test_zero_arc_locks_traverse() -> void:
	assert_almost_eq(Emplacement.clamp_yaw(deg_to_rad(30), 0.2, 0.0), 0.2, 0.001)
