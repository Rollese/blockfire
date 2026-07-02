extends TestCase
## Kill scoring through the REAL server._kill_pawn (was a local mirror of the credit/debit
## rules — batch 5.2 converted it to the production path via ServerFixture).

const F := preload("res://tests/server_fixture.gd")


func test_kill_credits_killer_and_debits_victim() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 7)
	F.add_client(srv, 9, 1)
	var victim := F.add_pawn(srv, 9, 1)
	srv._kill_pawn(9, victim, 7, Weapon.AR, false, Revive.Source.BULLET)
	assert_eq(srv._clients[7]["kills"], 1)
	assert_eq(srv._clients[7]["score"], srv.KILL_SCORE, "score bonus = the server constant, not a test copy")
	assert_eq(srv._clients[9]["deaths"], 1)
	assert_eq(srv._clients[9]["kills"], 0)


func test_self_kill_debits_but_never_credits() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 7)
	var victim := F.add_pawn(srv, 7)
	srv._kill_pawn(7, victim, 7, Weapon.AR, false, Revive.Source.BLAST)
	assert_eq(srv._clients[7]["deaths"], 1)
	assert_eq(srv._clients[7]["kills"], 0, "suicide is not a kill")
	assert_eq(srv._clients[7]["score"], 0)


func test_kill_by_departed_client_still_counts_the_death() -> void:
	# killer disconnected between firing and the projectile landing — no credit, no crash.
	var srv = autofree(F.make_server())
	F.add_client(srv, 9, 1)
	var victim := F.add_pawn(srv, 9, 1)
	srv._kill_pawn(9, victim, 42, Weapon.AR, false, Revive.Source.BULLET)
	assert_eq(srv._clients[9]["deaths"], 1)
	assert_false(victim.alive)
