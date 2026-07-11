extends TestCase
## M19 loadout applied by the REAL server paths (not mirrors): SET_LOADOUT store-and-apply,
## RPG-gadget rocket pool granted at deploy, and per-connection persistence across redeploy.
## Exercises srv._handle_set_loadout / srv._handle_deploy_request directly; SpyNet absorbs sends.

const F := preload("res://tests/server_fixture.gd")

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1},{"id":"B","pos":[200,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

var _attach: Attachment


func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons.json loads")
	_attach = Attachment.load_file("res://data/attachments.json")
	assert_true(_attach != null, "attachments.json loads")


func teardown() -> void:
	Weapon.reset_registry()


## A ServerMain with map/conquest and a single awaiting (dead) team-0 human pawn, ready to deploy.
## _gadgets is loaded so the RPG-gadget rocket-pool branch in the deploy path resolves.
func _srv_with_awaiting_pawn() -> Node:
	var srv = autofree(F.make_server())
	srv._map = MapDef.from_json_string(MAP_JSON)["map"]
	srv._conquest = ConquestState.new(srv._map)
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	assert_true(srv._gadgets != null, "gadgets.json loads")
	srv._attachments = _attach
	F.add_client(srv, 1, 0, true)
	var p := F.add_pawn(srv, 1, 0)
	p.alive = false
	srv._peer_to_id[null] = 1
	return srv


func _deploy(srv) -> void:
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(0))   # ref 0 = HQ


func test_deploy_with_rpg_gadget_grants_rockets() -> void:
	var srv := _srv_with_awaiting_pawn()
	srv._clients[1]["loadout"] = Loadout.sanitize({"class": Loadout.ENGINEER, "gadget": Loadout.GADGET_RPG}, _attach)
	_deploy(srv)
	assert_true((srv._sim.world.get_pawn(1) as Pawn).alive, "engineer deploys")
	assert_gt(int(srv._clients[1]["rockets"]), 0, "RPG gadget grants a rocket pool at deploy")


func test_deploy_with_c4_gadget_grants_no_rockets() -> void:
	var srv := _srv_with_awaiting_pawn()
	srv._clients[1]["loadout"] = Loadout.sanitize({"class": Loadout.ENGINEER, "gadget": Loadout.GADGET_C4}, _attach)
	_deploy(srv)
	assert_true((srv._sim.world.get_pawn(1) as Pawn).alive, "engineer deploys")
	assert_eq(int(srv._clients[1]["rockets"]), 0, "no RPG gadget -> no rockets")


func test_loadout_persists_across_redeploy() -> void:
	var srv := _srv_with_awaiting_pawn()
	srv._clients[1]["loadout"] = Loadout.sanitize({"class": Loadout.ENGINEER, "gadget": Loadout.GADGET_RPG}, _attach)
	_deploy(srv)
	assert_gt(int(srv._clients[1]["rockets"]), 0, "first deploy grants rockets")
	# Simulate death, clear the respawn cooldown the deploy path checks, and redeploy WITHOUT re-sending.
	(srv._sim.world.get_pawn(1) as Pawn).alive = false
	srv._clients[1]["deploy_ready_tick"] = 0
	srv._clients[1]["rockets"] = 0   # prove the second grant comes from the stored loadout, not a stale value
	_deploy(srv)
	assert_true((srv._sim.world.get_pawn(1) as Pawn).alive, "redeploys")
	assert_gt(int(srv._clients[1]["rockets"]), 0, "stored loadout re-applies rockets on redeploy")


func test_set_loadout_stores_resanitized_config() -> void:
	var srv := _srv_with_awaiting_pawn()
	var lmg_v := int(Weapon.variants_of(Weapon.LMG)[0])
	var cfg := {"class": Loadout.SUPPORT, "primary": lmg_v, "secondary": Weapon.PISTOL,
		"gadget": Loadout.GADGET_AMMO, "armor": Armor.HEAVY, "grenade": Grenade.SMOKE,
		"attachments": {"optic": "reddot", "barrel": "standard", "underbarrel": "none_ub"}}
	srv._handle_set_loadout(null, Protocol.encode_set_loadout(cfg))
	var stored: Dictionary = srv._clients[1]["loadout"]
	assert_eq(stored, Loadout.sanitize(cfg, _attach), "server re-sanitizes to the same result the client would")
	assert_eq(int(stored["class"]), Loadout.SUPPORT)
	assert_eq(int(stored["armor"]), Armor.HEAVY)


func test_set_loadout_does_not_mutate_live_pawn() -> void:
	var srv = autofree(F.make_server())
	srv._attachments = _attach
	F.add_client(srv, 1, 0, true)
	F.add_pawn(srv, 1, 0)   # alive=true
	srv._peer_to_id[null] = 1
	var weapon_before = srv._clients[1]["weapon"]
	var class_before := int(srv._clients[1]["class"])
	var lmg_v := int(Weapon.variants_of(Weapon.LMG)[0])
	srv._handle_set_loadout(null, Protocol.encode_set_loadout(
		{"class": Loadout.SUPPORT, "primary": lmg_v, "gadget": Loadout.GADGET_AMMO}))
	assert_eq(srv._clients[1]["weapon"], weapon_before, "live pawn weapon unchanged (applies next spawn)")
	assert_eq(int(srv._clients[1]["class"]), class_before, "live pawn class unchanged")
	assert_eq(int(srv._clients[1]["loadout"]["class"]), Loadout.SUPPORT, "intent stored in loadout")


func test_set_loadout_rejects_garbage() -> void:
	var srv := _srv_with_awaiting_pawn()
	# Hostile cfg: bad class, RPG base id as primary, an unbuilt gadget, out-of-range armor/grenade.
	srv._handle_set_loadout(null, Protocol.encode_set_loadout(
		{"class": 99, "primary": Weapon.RPG, "gadget": Loadout.GADGET_RIOT_SHIELD, "armor": 99, "grenade": 99}))
	var stored: Dictionary = srv._clients[1]["loadout"]
	assert_contains([Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT], int(stored["class"]))
	assert_true(Weapon.is_variant(int(stored["primary"])), "sanitized primary is a real variant, never the RPG base id")
	assert_contains(Loadout.IMPLEMENTED_GADGETS, int(stored["gadget"]))
	assert_contains([Armor.LIGHT, Armor.MEDIUM, Armor.HEAVY], int(stored["armor"]))
	assert_contains([Grenade.FRAG, Grenade.SMOKE, Grenade.FLASHBANG, Grenade.IMPACT], int(stored["grenade"]))
