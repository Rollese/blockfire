extends RefCounted
## Shared minimal ServerMain fixture for tests that exercise REAL server functions.
## Not a *_test.gd file — the runner skips it; tests preload it.
##
## Background (batch 5.2): several test files used to REIMPLEMENT server logic locally
## ("mirrors server _apply_pawn_damage" etc.) and would silently drift from production.
## This fixture makes the real code path as cheap to call as the mirror was to copy:
## a ServerMain built WITHOUT _ready() (no ENet), a SpyNet that records instead of
## sending, and hand-placed pawns/clients.

class SpyNet extends NetHost:
	var sends: Array = []   # [{peer, channel, bytes, flags}]
	func send_to(peer: ENetPacketPeer, channel: int, bytes: PackedByteArray, flags: int) -> void:
		sends.append({"peer": peer, "channel": channel, "bytes": bytes, "flags": flags})
	## All recorded packets of one message type, decoded key: raw bytes.
	func bytes_of(msg: int) -> Array:
		var out: Array = []
		for s in sends:
			if not (s["bytes"] as PackedByteArray).is_empty() and s["bytes"][0] == msg:
				out.append(s["bytes"])
		return out


static func make_server() -> Node:
	var srv = load("res://server/server_main.gd").new()
	srv._catalog = PieceCatalog.load_file("res://pieces/pieces.json")
	srv._store = StructureStore.new(srv._catalog)
	srv._conquest = ConquestState.new()
	srv._net = SpyNet.new()
	return srv


static func add_pawn(srv, id: int, team := 0, pos := Vector3.ZERO) -> Pawn:
	var p: Pawn = srv._sim.world.spawn(id)   # alive=true, health=100
	p.team = team
	p.pos = pos
	return p


## Minimal client record: enough for kill/scoring/deploy paths. peer stays null (SpyNet
## records it regardless); pass human=true to also land in the _human_ids fan-out cache.
static func add_client(srv, id: int, team := 0, human := false) -> Dictionary:
	var c := {"team": team, "auto_deploy": not human, "peer": null, "name": "p%d" % id,
		"squad": 1, "class": Loadout.ASSAULT, "weapon": Weapon.AR,
		"loadout": Loadout.default_loadout(Loadout.ASSAULT),   # M19: spawn/deploy paths read c["loadout"]
		"kills": 0, "deaths": 0, "score": 0, "dmg_ledger": {}}
	srv._clients[id] = c
	if human:
		srv._human_ids.append(id)
	return c
