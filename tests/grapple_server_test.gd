extends TestCase
## ServerDeployedLadders: deploy resolves+spends charge+evicts prior (cross-life by owner id);
## rejects at 0 charges; cut arm+radius; lifecycle cleanup (owner/building).

const F := preload("res://tests/server_fixture.gd")
const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":0}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons load")

func teardown() -> void:
	Weapon.reset_registry()

func _srv() -> Node:
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	srv._map = MapDef.from_json_string(MAP_JSON)["map"]
	srv._conquest = ConquestState.new(srv._map)
	return srv

func _assault(srv, id: int) -> Array:
	var c := F.add_client(srv, id, 0, false)
	c["class"] = Loadout.ASSAULT
	c["loadout"]["class"] = Loadout.ASSAULT
	c["loadout"]["gadget"] = Loadout.GADGET_GRAPPLE
	var p := F.add_pawn(srv, id, 0)
	srv._apply_loadout_to_client(c, p)
	p.pos = Vector3.ZERO
	return [c, p]

func test_deploy_spends_charge_and_creates_ladder() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	var g := ServerDeployedLadders.new(srv)
	g.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)   # test-only: (owner,p,hit_point,building_id,ground_y)
	assert_eq(g.volumes.size(), 1, "ladder deployed")
	assert_eq(int(c["grapple_charges"]), 0, "charge spent")

func test_deploy_rejected_at_zero_charges() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 0
	var g := ServerDeployedLadders.new(srv)
	g.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)
	assert_eq(g.volumes.size(), 0, "no charge -> no ladder")

func test_redeploy_evicts_prior_across_lives() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	var g := ServerDeployedLadders.new(srv)
	g.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)
	c["grapple_charges"] = 1   # simulate fresh-life / restock
	g.deploy_at(1, p, Vector3(0, 5, 20), 0, 0.0)
	assert_eq(g.volumes.size(), 1, "one ladder per owner across lives")
	assert_true(abs(float(g.volumes[0]["top"].z) - 20.0) < 0.2, "the NEW ladder replaced the old")

func test_cut_before_arm_ignored_after_arm_removes() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	var g := ServerDeployedLadders.new(srv)
	srv._sim.tick = 0
	g.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)
	var lid := int(g.volumes[0]["id"])
	var cutter := F.add_pawn(srv, 2, 1); cutter.pos = Vector3(0, 0, 8)   # at the line
	srv._sim.tick = Grapple.CUT_ARM_TICKS - 5
	g.step_arm(srv._sim.tick)
	g.cut(2, lid, cutter)
	assert_eq(g.volumes.size(), 1, "not cuttable before arm")
	srv._sim.tick = Grapple.CUT_ARM_TICKS + 5
	g.step_arm(srv._sim.tick)
	g.cut(2, lid, cutter)
	assert_eq(g.volumes.size(), 0, "cut after arm from in-radius removes it")

func test_remove_owner_and_building() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	var g := ServerDeployedLadders.new(srv)
	g.deploy_at(1, p, Vector3(0, 5, 8), 77, 0.0)   # building_id 77
	g.remove_building(77)
	assert_eq(g.volumes.size(), 0, "collapse of anchor building drops the ladder")

func test_remove_owner_drops_ladder() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	var g := ServerDeployedLadders.new(srv)
	g.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)
	assert_eq(g.volumes.size(), 1, "deployed")
	g.remove_owner(1)
	assert_eq(g.volumes.size(), 0, "disconnect/owner cleanup drops the ladder")

func test_cut_out_of_radius_after_arm_ignored() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	var g := ServerDeployedLadders.new(srv)
	srv._sim.tick = 0
	g.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)
	var lid := int(g.volumes[0]["id"])
	var cutter := F.add_pawn(srv, 2, 1); cutter.pos = Vector3(50, 0, 50)   # far beyond CUT_RADIUS
	srv._sim.tick = Grapple.CUT_ARM_TICKS + 5
	g.step_arm(srv._sim.tick)
	g.cut(2, lid, cutter)
	assert_eq(g.volumes.size(), 1, "armed but too far -> not cuttable")

func test_deploy_gate_gadget_mismatch() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["loadout"]["gadget"] = Loadout.GADGET_C4   # not the grapple
	c["grapple_charges"] = 1
	var g := ServerDeployedLadders.new(srv)
	g.deploy(1, p, p.eye_position(), Vector3(0, 0, 1))
	assert_eq(g.volumes.size(), 0, "wrong gadget -> no ladder")
	assert_eq(int(c["grapple_charges"]), 1, "wrong gadget -> charge NOT spent")

func test_deploy_gate_downed_pawn() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	p.is_downed = true
	var g := ServerDeployedLadders.new(srv)
	g.deploy(1, p, p.eye_position(), Vector3(0, 0, 1))
	assert_eq(g.volumes.size(), 0, "downed -> no ladder")
	assert_eq(int(c["grapple_charges"]), 1, "downed -> charge unchanged")

## Task 7: the real _handle_cut_ladder dispatch — peer -> id -> pawn -> ServerDeployedLadders.cut,
## with the wire round-trip through Protocol.encode/decode_cut_ladder.
func test_handle_cut_ladder_cuts_armed_rope_in_radius() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	srv._sim.tick = 0
	srv._grapples.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)
	var lid := int(srv._grapples.volumes[0]["id"])
	# Enemy cutter with a real client + pawn at the rope line so the handler resolves it.
	var cutter_peer = c["peer"]   # null placeholder shared by fixture; distinct key not needed here
	var cutter_c := F.add_client(srv, 2, 1, false)
	var cutter := F.add_pawn(srv, 2, 1); cutter.pos = Vector3(0, 0, 8)
	srv._peer_to_id[cutter_peer] = 2
	srv._sim.tick = Grapple.CUT_ARM_TICKS + 5
	srv._grapples.step_arm(srv._sim.tick)
	srv._handle_cut_ladder(cutter_peer, Protocol.encode_cut_ladder(lid))
	assert_eq(srv._grapples.volumes.size(), 0, "handler cut the armed rope from an in-radius requester")

func test_disconnect_sweep_drops_rope_and_nest() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]; var p = cp[1]
	c["grapple_charges"] = 1
	srv._grapples = ServerDeployedLadders.new(srv)
	srv._sim.deployed_ladders = srv._grapples.volumes
	srv._grapples.deploy_at(1, p, Vector3(0, 5, 8), 0, 0.0)
	assert_eq(srv._grapples.volumes.size(), 1, "rope up")
	# Drive the REAL _on_peer_disconnected body: register the fixture's (null) peer -> id 1 first.
	srv._peer_to_id[c["peer"]] = 1
	srv._on_peer_disconnected(c["peer"])
	assert_eq(srv._grapples.volumes.size(), 0, "rope cleaned on disconnect")

func test_give_ammo_refills_grapple_charge() -> void:
	var srv := _srv()
	var cp := _assault(srv, 1); var c = cp[0]
	c["grapple_charges"] = 0
	srv._sim.tick = 0
	srv._support.give_ammo(1, 1)   # period=1 -> fires this tick
	assert_eq(int(c["grapple_charges"]), Grapple.CHARGES, "support restocked the grapple charge")
