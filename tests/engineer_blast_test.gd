extends TestCase

const ServerFixture := preload("res://tests/server_fixture.gd")

# A victim just OUTSIDE the base pawn_radius but INSIDE the Engineer-scaled (×1.2) radius takes blast
# damage only when the owner is an Engineer. Exercises the real _blast_at.
func _server_with_owner(cls: int) -> Node:
	var srv = ServerFixture.make_server()
	var owner := ServerFixture.add_client(srv, 1, 0, false)
	owner["class"] = cls
	ServerFixture.add_pawn(srv, 1, 0, Vector3.ZERO)   # the thrower/placer (team 0)
	return srv

func test_engineer_blast_reaches_farther() -> void:
	# base pawn_radius 8.0; enemy at 9.0 m (outside base, inside 8.0*1.2 = 9.6).
	var srv = _server_with_owner(Loadout.ENGINEER)
	var victim := ServerFixture.add_pawn(srv, 2, 1, Vector3(9.0, 0.0, 0.0))
	ServerFixture.add_client(srv, 2, 1, false)
	var hits: int = srv._blast_at(Vector3.ZERO, 1, 0, 100, 8.0, 0, 0.0)
	assert_eq(hits, 1, "Engineer's 20%-larger blast reaches an enemy at 9 m")
	assert_true(victim.health < 100, "victim took falloff damage")

func test_non_engineer_blast_does_not_reach() -> void:
	var srv = _server_with_owner(Loadout.ASSAULT)
	var victim := ServerFixture.add_pawn(srv, 2, 1, Vector3(9.0, 0.0, 0.0))
	ServerFixture.add_client(srv, 2, 1, false)
	var hits: int = srv._blast_at(Vector3.ZERO, 1, 0, 100, 8.0, 0, 0.0)
	assert_eq(hits, 0, "Assault's un-scaled blast stops short of 9 m")
	assert_eq(victim.health, 100, "victim unharmed")

func test_unknown_owner_uses_baseline() -> void:
	var srv = ServerFixture.make_server()
	var victim := ServerFixture.add_pawn(srv, 2, 1, Vector3(9.0, 0.0, 0.0))
	ServerFixture.add_client(srv, 2, 1, false)
	var hits: int = srv._blast_at(Vector3.ZERO, 999, 0, 100, 8.0, 0, 0.0)
	assert_eq(hits, 0, "no-record owner falls back to baseline radius")
