extends TestCase

func test_deploy_one_per_owner_replaces_and_moves() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	assert_eq(h.nest_count(), 1)
	assert_almost_eq(h.first_nest().pos.z, 5.0, 0.01)
	# redeploy 1m away (within min_sep of the OWN prior nest) must replace + move, not no-op
	h.deploy(Vector3(0, 0, 6), Vector3(0, 0, 1))
	assert_eq(h.nest_count(), 1)
	assert_almost_eq(h.first_nest().pos.z, 6.0, 0.01, "redeploy replaced + moved the owner's nest")

func test_deploy_blocked_near_another_owners_nest() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	# a foreign nest owned by someone else, right where we want to deploy
	var foreign := Emplacement.make(Emplacement.id_for(99), Gadget.KIND_LMG_NEST, 1, Vector3(0, 0, 5), 0.0, h._gadgets.def_of_kind(Gadget.KIND_LMG_NEST))
	foreign.owner_id = 42
	h.emp.nests[foreign.id] = foreign
	h.deploy(Vector3(0, 0, 5.5), Vector3(0, 0, 1))   # 0.5m from the foreign nest -> blocked
	assert_eq(h.nest_count(), 1, "still only the foreign nest; our deploy was separation-blocked")

func test_deploy_requires_nest_gadget_equipped() -> void:
	var h := EmplacementHarness.new()
	var p := h.add_support(Vector3(0, 0, 0))
	h._clients[h._support_id]["loadout"]["gadget"] = Loadout.GADGET_AMMO   # not the nest
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	assert_eq(h.nest_count(), 0)

func test_deploy_facing_from_dir() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(1, 0, 0))   # facing +X -> yaw = atan2(1,0) = PI/2
	assert_almost_eq(h.first_nest().facing_yaw, PI / 2.0, 0.01)

func test_mount_binds_and_clamps_aim() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))   # facing +Z (yaw 0)
	var nid := h.first_nest_id()
	h.move_pawn_to(h.first_nest().seat_world())     # stand on the seat
	h.mount(nid)
	assert_eq(h.pawn().mounted_nest, nid)
	assert_eq(h.first_nest().occupant, h.pawn_id())
	# aim 80 deg right -> turret clamps to +45 after a slave tick
	h.set_pawn_yaw(deg_to_rad(80)); h.tick()
	assert_almost_eq(h.first_nest().turret_yaw, deg_to_rad(45), 0.01)

func test_mount_rejected_out_of_range() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	# pawn far from the seat -> can_mount fails
	h.move_pawn_to(Vector3(0, 0, 0))
	h.mount(h.first_nest_id())
	assert_eq(h.pawn().mounted_nest, 0)
	assert_eq(h.first_nest().occupant, 0)

func test_dismount_releases() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	var nid := h.first_nest_id()
	h.move_pawn_to(h.first_nest().seat_world()); h.mount(nid)
	h.dismount()
	assert_eq(h.pawn().mounted_nest, 0)
	assert_eq(h.first_nest().occupant, 0)

func test_occupant_slaved_to_seat() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	h.move_pawn_to(h.first_nest().seat_world()); h.mount(h.first_nest_id())
	# shove the pawn away, then a slave tick must snap it back to the seat
	h.move_pawn_to(Vector3(50, 0, 50)); h.tick()
	assert_almost_eq(h.pawn().pos.x, h.first_nest().seat_world().x, 0.01)
	assert_almost_eq(h.pawn().pos.z, h.first_nest().seat_world().z, 0.01)

func test_mount_clamps_pitch() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	h.move_pawn_to(h.first_nest().seat_world()); h.mount(h.first_nest_id())
	h.set_pawn_pitch(deg_to_rad(60)); h.tick()   # 60 up -> clamps to +25
	assert_almost_eq(h.first_nest().pitch, deg_to_rad(25), 0.01)

func test_downed_gunner_self_heals_off_nest() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	var nid := h.first_nest_id()
	h.move_pawn_to(h.first_nest().seat_world()); h.mount(nid)
	h.pawn().is_downed = true; h.tick()   # step_occupants self-heals a downed occupant
	assert_eq(h.first_nest().occupant, 0)
	assert_eq(h.pawn().mounted_nest, 0)
