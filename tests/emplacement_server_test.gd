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
