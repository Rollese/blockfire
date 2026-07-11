extends TestCase
## Regressions for the 2026-07-04 global review server-hardening batch: duplicate-HELLO guard (S1),
## downed grenade throws (S3), human grenade-type clamp (S7), bag-throw range (S5), and
## disconnect gadget cleanup (S9). All through the REAL server handlers via server_fixture.

const F := preload("res://tests/server_fixture.gd")

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'


func test_duplicate_hello_does_not_mint_second_client() -> void:
	# S1: a repeated HELLO on an already-welcomed peer minted a fresh id/pawn/team/squad slot every
	# time (slot-exhaustion DoS; only the newest id was cleaned on disconnect). It must be idempotent:
	# same single client, WELCOME re-sent with the SAME id.
	var srv = autofree(F.make_server())
	srv._map = MapDef.from_json_string(MAP_JSON)["map"]
	srv._conquest = ConquestState.new(srv._map)
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")           # hello path may hand out rockets
	srv._attachments = Attachment.load_file("res://data/attachments.json")  # weapon_def build
	var hello := Protocol.encode_hello("Dup", false)
	srv._handle_hello(null, hello)
	assert_eq(srv._clients.size(), 1, "first HELLO creates the client")
	var first_id: int = srv._peer_to_id[null]
	var pawns_before: int = srv._sim.world.pawns.size()
	srv._handle_hello(null, hello)
	srv._handle_hello(null, hello)
	assert_eq(srv._clients.size(), 1, "repeated HELLO mints no extra clients")
	assert_eq(srv._sim.world.pawns.size(), pawns_before, "repeated HELLO spawns no extra pawns")
	assert_eq(int(srv._peer_to_id[null]), first_id, "peer keeps its original id")
	var welcomes: Array = (srv._net as F.SpyNet).bytes_of(Protocol.Msg.WELCOME)
	assert_eq(welcomes.size(), 3, "every HELLO is answered with a WELCOME (reliable-retry friendly)")
	for w in welcomes:
		assert_eq(int(Protocol.decode_welcome(w)["id"]), first_id, "re-sent WELCOME carries the same id")


func _client_with_pawn(srv, id: int, human: bool) -> Pawn:
	var c: Dictionary = F.add_client(srv, id, 0, human)
	c["last_grenade_tick"] = -100000
	c["grenades"] = 3   # M19: finite per-life throwable pool — seed so real handler's pool gate passes
	srv._peer_to_id[null] = id
	return F.add_pawn(srv, id, 0)


func test_downed_pawn_cannot_throw_grenade() -> void:
	# S3: the handler gated on `not p.alive` only — downed pawns keep alive==true, so a DBNO
	# (damage-immune!) pawn could frag the enemy standing over it. Same is_downed gate as fire/melee.
	var srv = autofree(F.make_server())
	var p := _client_with_pawn(srv, 1, false)
	p.is_downed = true
	srv._handle_grenade_throw(null, Protocol.encode_grenade_throw(Vector3.FORWARD, Grenade.FRAG))
	assert_eq(srv._grenades.size(), 0, "downed pawn's throw is rejected")
	p.is_downed = false
	srv._handle_grenade_throw(null, Protocol.encode_grenade_throw(Vector3.FORWARD, Grenade.FRAG))
	assert_eq(srv._grenades.size(), 1, "the same pawn up again throws fine")


func test_human_grenade_type_clamped_to_advertised_loadout() -> void:
	# S7: type was only clamped to the FRAG..IMPACT range, so a modified client could throw IMPACT
	# (contact fuse — strictly better than frag) or FLASHBANG it never owned. Humans own what
	# SELF_STATE advertises: frag + smoke. Bots (auto_deploy) keep the full exerciser range.
	var srv = autofree(F.make_server())
	_client_with_pawn(srv, 1, true)
	srv._handle_grenade_throw(null, Protocol.encode_grenade_throw(Vector3.FORWARD, Grenade.IMPACT))
	assert_eq(srv._grenades.size(), 1)
	assert_eq(int(srv._grenades[0]["type"]), Grenade.FRAG, "human IMPACT throw downgraded to frag")

	var srv2 = autofree(F.make_server())
	_client_with_pawn(srv2, 2, false)
	srv2._handle_grenade_throw(null, Protocol.encode_grenade_throw(Vector3.FORWARD, Grenade.IMPACT))
	assert_eq(srv2._grenades.size(), 1)
	assert_eq(int(srv2._grenades[0]["type"]), Grenade.IMPACT, "bot exercisers keep impact grenades")


func test_bag_throw_range_gated() -> void:
	# S5: _throw_bag had no validation on the client-supplied position (its siblings _place_c4 and
	# _place_mine both range-check) — infinite-range remote logistics onto any objective.
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	var c: Dictionary = F.add_client(srv, 1, 0, true)
	c["class"] = Loadout.MEDIC
	var p := F.add_pawn(srv, 1, 0)
	srv._throw_bag(1, p, p.pos + Vector3(200.0, 0.0, 0.0))
	assert_eq(srv._bags.size(), 0, "bag at 200 m rejected")
	srv._throw_bag(1, p, p.pos + Vector3(3.0, 0.0, 0.0))
	assert_eq(srv._bags.size(), 1, "bag within reach accepted")


func test_disconnect_clears_owned_c4_and_mines() -> void:
	# S9: disconnect never erased _c4[id] / the leaver's mines — orphaned C4 could never be
	# detonated again and rode the GADGET_LIST heartbeat for the rest of the match.
	var srv = autofree(F.make_server())
	F.add_client(srv, 1, 0, true)
	F.add_pawn(srv, 1, 0)
	srv._peer_to_id[null] = 1
	srv._c4[1] = [{"pos": Vector3.ZERO, "cell": Vector3i.ZERO}]
	srv._mines = [{"owner": 1, "team": 0, "pos": Vector3.ZERO, "facing": Vector3.FORWARD, "armed_after_tick": 0},
		{"owner": 2, "team": 1, "pos": Vector3.ONE, "facing": Vector3.FORWARD, "armed_after_tick": 0}]
	srv._on_peer_disconnected(null)
	assert_false(srv._c4.has(1), "leaver's C4 dropped")
	assert_eq(srv._mines.size(), 1, "only the leaver's mines dropped")
	assert_eq(int(srv._mines[0]["owner"]), 2, "other players' mines survive")
