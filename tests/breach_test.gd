extends TestCase
## M19 P2b Task 3: Assault BREACH gadget server sim — an active placed charge that, after a short
## arm timer, carves a walkable hole in the structure the player aimed at. Mirrors the _place_mine
## place-loop and reuses the real _damage_structure carve path (SRC_EXPLOSIVE), struct-only (no
## pawn damage). Real server paths via server_fixture.gd, not mirrors.

const F := preload("res://tests/server_fixture.gd")


func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons.json loads")


func teardown() -> void:
	Weapon.reset_registry()


## A ServerMain with the real gadget catalog loaded (breach def resolves).
func _srv() -> Node:
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	assert_true(srv._gadgets != null, "gadgets.json loads")
	return srv


## A wall cell directly ahead of a pawn standing at z=-0.5 facing +z (cell (0,0,0)), mirroring
## grenade_gate_test.gd's _place_front_wall.
func _place_front_wall(srv) -> int:
	var bwall: int = srv._catalog.index_of("bwall")
	srv._store.place(1, bwall, Vector3i(0, 0, 0), 0, -1, 1)
	return 1


func test_breach_gate_wrong_gadget() -> void:
	var srv := _srv()
	var c := F.add_client(srv, 1, 0, false)
	c["loadout"]["gadget"] = Loadout.GADGET_C4
	var p := F.add_pawn(srv, 1, 0, Vector3(0, 0, -0.5))
	p.yaw = 0.0
	_place_front_wall(srv)
	srv._place_breach(1, p, Vector3(0, 0, 1.0), Vector3(0, 0, 1))
	assert_eq(srv._breaches.size(), 0, "wrong gadget -> no breach placed")


func test_breach_places_and_carves_after_fuse() -> void:
	var srv := _srv()
	var c := F.add_client(srv, 1, 0, false)
	c["loadout"]["gadget"] = Loadout.GADGET_BREACH
	var p := F.add_pawn(srv, 1, 0, Vector3(0, 0, -0.5))
	p.yaw = 0.0
	var wid := _place_front_wall(srv)
	var mask_before: int = srv._store.get_record(wid)["chunks"]
	srv._place_breach(1, p, Vector3(0, 0, 1.0), Vector3(0, 0, 1))
	assert_eq(srv._breaches.size(), 1, "charge placed against the aimed structure")
	var detonated := false
	for _i in 50:
		srv._sim.tick += 1
		srv._step_breaches()
		if srv._breaches.is_empty():
			detonated = true
			break
	assert_true(detonated, "charge detonated once its arm timer elapsed")
	assert_eq(srv._breaches.size(), 0, "spent charge removed from the pool")
	var rec: Dictionary = srv._store.get_record(wid)
	assert_true(rec.is_empty() or int(rec["chunks"]) != mask_before,
		"structure carved (chunk mask changed or piece destroyed) by the breach blast")


func test_breach_max_active_one() -> void:
	var srv := _srv()
	var c := F.add_client(srv, 1, 0, false)
	c["loadout"]["gadget"] = Loadout.GADGET_BREACH
	var p := F.add_pawn(srv, 1, 0, Vector3(0, 0, -0.5))
	p.yaw = 0.0
	_place_front_wall(srv)
	srv._place_breach(1, p, Vector3(0, 0, 1.0), Vector3(0, 0, 1))
	srv._place_breach(1, p, Vector3(0, 0, 1.0), Vector3(0, 0, 1))
	assert_eq(srv._breaches.size(), 1, "max_active=1 blocks a second charge")
