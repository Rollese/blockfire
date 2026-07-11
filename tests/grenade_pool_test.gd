extends TestCase

const _SF := preload("res://tests/server_fixture.gd")

func _spawned(cls: int) -> Array:   # [srv, client, pawn]
	var srv = _SF.make_server()
	var c := _SF.add_client(srv, 1, 0, false)
	c["loadout"] = Loadout.default_loadout(cls)
	c["class"] = cls
	var p := _SF.add_pawn(srv, 1, 0, Vector3.ZERO)
	srv._apply_loadout_to_client(c, p)
	c["last_grenade_tick"] = -100000   # off cooldown
	return [srv, c, p]

func test_pool_size_by_class() -> void:
	assert_eq(int(_spawned(Loadout.ASSAULT)[1]["grenades"]), 3, "non-support gets 3")
	assert_eq(int(_spawned(Loadout.SUPPORT)[1]["grenades"]), 5, "support gets 5")

func test_throw_decrements_pool() -> void:
	var s = _spawned(Loadout.ASSAULT)
	var srv = s[0]; var c = s[1]
	var before := int(c["grenades"])
	var bytes := Protocol.encode_grenade_throw(Vector3(1,0,0), Grenade.FRAG, 1.0)
	srv._peer_to_id[null] = 1
	srv._handle_grenade_throw(null, bytes)
	assert_eq(int(c["grenades"]), before - 1, "one throw spends one grenade")
	assert_eq(srv._grenades.size(), 1, "grenade was actually spawned")

func test_empty_pool_rejects_throw() -> void:
	var s = _spawned(Loadout.ASSAULT)
	var srv = s[0]; var c = s[1]
	c["grenades"] = 0
	var bytes := Protocol.encode_grenade_throw(Vector3(1,0,0), Grenade.FRAG, 1.0)
	srv._peer_to_id[null] = 1
	srv._handle_grenade_throw(null, bytes)
	assert_eq(srv._grenades.size(), 0, "empty pool throws nothing")

func test_throwables_report_caps_by_pool() -> void:
	var s = _spawned(Loadout.ASSAULT)
	var srv = s[0]; var c = s[1]
	c["grenades"] = 0
	for entry in srv._throwables_for(c):
		if int(entry["kind"]) == Grenade.FRAG or int(entry["kind"]) == Grenade.SMOKE:
			assert_eq(int(entry["count"]), 0, "empty pool reports 0 ready even off cooldown")
