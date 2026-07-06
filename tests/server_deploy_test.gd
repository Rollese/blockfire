extends TestCase
## Deploy placement through the REAL server._handle_deploy_request (was a local mirror of
## "is_valid -> resolve -> alive" — batch 5.2). peer=null keys _peer_to_id; SpyNet absorbs sends.

const F := preload("res://tests/server_fixture.gd")

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1},{"id":"B","pos":[200,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'


func _srv_with_awaiting_pawn(team: int) -> Node:
	var srv = autofree(F.make_server())
	srv._map = MapDef.from_json_string(MAP_JSON)["map"]
	srv._conquest = ConquestState.new(srv._map)
	F.add_client(srv, 1, team, true)
	var p := F.add_pawn(srv, 1, team)
	p.alive = false
	srv._peer_to_id[null] = 1
	return srv


func test_valid_ref_deploys_awaiting_pawn() -> void:
	var srv := _srv_with_awaiting_pawn(0)
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(0))   # ref 0 = HQ
	var p: Pawn = srv._sim.world.get_pawn(1)
	assert_true(p.alive, "valid HQ ref deploys")
	assert_eq(p.health, 100)
	assert_almost_eq(p.pos.x, -900.0, 45.0, "placed at the team-0 base (within its radius)")


func test_invalid_ref_leaves_pawn_awaiting() -> void:
	var srv := _srv_with_awaiting_pawn(1)
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(1))   # point A not owned by team 1
	assert_false((srv._sim.world.get_pawn(1) as Pawn).alive, "invalid ref does not deploy")


func test_deploy_blocked_during_respawn_cooldown() -> void:
	var srv := _srv_with_awaiting_pawn(0)
	srv._clients[1]["deploy_ready_tick"] = srv._sim.tick + 100
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(0))
	assert_false((srv._sim.world.get_pawn(1) as Pawn).alive, "death cooldown gates the deploy screen")
	srv._sim.tick += 100
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(0))
	assert_true((srv._sim.world.get_pawn(1) as Pawn).alive, "deploys once the cooldown elapses")


func test_deploy_blocked_after_match_over() -> void:
	# Playtest bug: with the victory/defeat overlay up, the deploy menu's buttons stayed clickable and
	# the server happily re-spawned the player into a finished match. Deploy must be rejected once the
	# match is over (the client also hides the menu now).
	var srv := _srv_with_awaiting_pawn(0)
	srv._conquest.match_over = true
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(0))   # ref 0 = HQ, normally valid
	assert_false((srv._sim.world.get_pawn(1) as Pawn).alive, "no deploying after the match has ended")


func test_deploy_resets_ledger_and_clears_downed_state() -> void:
	var srv := _srv_with_awaiting_pawn(0)
	srv._clients[1]["dmg_ledger"] = {9: 55}
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(0))
	assert_eq((srv._clients[1]["dmg_ledger"] as Dictionary).size(), 0, "fresh life, fresh recap ledger")


func test_deploy_rearms_full_bleedout_window() -> void:
	# G1 regression: the halving-bleedout down_count carried across lives for manually-deploying humans
	# (only _handle_respawns reset it, not the deploy path). A player who accrued a few downs earlier in
	# the match then bled out almost instantly on the FIRST down of a fresh life — and eventually skipped
	# DBNO entirely (bleedout_window(down_count+1) <= 0). A fresh deploy must re-arm the full 60 s window.
	var srv := _srv_with_awaiting_pawn(0)
	var p: Pawn = srv._sim.world.get_pawn(1)
	p.down_count = 6         # simulate several downs accrued across prior lives this match
	p.bleed_floor = -20
	p.bleed_halted = true
	srv._handle_deploy_request(null, Protocol.encode_deploy_request(0))
	assert_eq(p.down_count, 0, "fresh life re-arms down_count")
	assert_eq(p.bleed_floor, 0, "bleed floor cleared on deploy")
	assert_false(p.bleed_halted, "bleed-halt flag cleared on deploy")
	# The next down of this fresh life gets the full initial window, not a heavily-halved one.
	assert_eq(Revive.bleedout_window(p.down_count + 1), Revive.INITIAL_BLEEDOUT_TICKS,
		"first down of the fresh life has the full 60 s bleedout window")
