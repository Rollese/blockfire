extends TestCase
## M19 P2b Task 5: Medic SMOKE_WALL gadget server sim — a larger, longer-lasting *placed* smoke
## cloud on a cooldown, reusing the existing smoke-zone system (_smoke_zones / SMOKE_DEPLOYED).
## Real server paths via server_fixture.gd, not mirrors.

const F := preload("res://tests/server_fixture.gd")


func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons.json loads")


func teardown() -> void:
	Weapon.reset_registry()


## A ServerMain with the real gadget catalog loaded (smokewall def resolves).
func _srv() -> Node:
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	assert_true(srv._gadgets != null, "gadgets.json loads")
	return srv


func _medic_client(srv, id: int) -> Dictionary:
	var c := F.add_client(srv, id, 0, false)
	c["class"] = Loadout.MEDIC
	c["loadout"]["class"] = Loadout.MEDIC
	c["loadout"]["gadget"] = Loadout.GADGET_SMOKE_WALL
	c["smokewall_ready_tick"] = 0
	return c


func test_smoke_wall_places_zone_and_broadcasts() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	var p := F.add_pawn(srv, 1, 0, Vector3(1, 0, 0))
	var pos := Vector3(2, 0, 0)   # within place_range (2.5) of the pawn
	var before: int = srv._smoke_zones.size()
	srv._place_smoke_wall(1, p, pos)
	assert_eq(srv._smoke_zones.size(), before + 1, "one smoke zone added")
	var zone: Dictionary = srv._smoke_zones[srv._smoke_zones.size() - 1]
	assert_true(float(zone["radius"]) > 6.0, "wall radius is bigger than a grenade's (6.0)")
	assert_true(srv._net.bytes_of(Protocol.Msg.SMOKE_DEPLOYED).size() >= 1, "SMOKE_DEPLOYED broadcast")


func test_smoke_wall_gated_on_gadget() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	c["loadout"]["gadget"] = Loadout.GADGET_HEAL
	var p := F.add_pawn(srv, 1, 0, Vector3(1, 0, 0))
	var before: int = srv._smoke_zones.size()
	srv._place_smoke_wall(1, p, Vector3(2, 0, 0))
	assert_eq(srv._smoke_zones.size(), before, "no zone — wrong gadget equipped")
	assert_eq(srv._net.bytes_of(Protocol.Msg.SMOKE_DEPLOYED).size(), 0, "no broadcast — wrong gadget equipped")


func test_smoke_wall_cooldown() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	var p := F.add_pawn(srv, 1, 0, Vector3(1, 0, 0))
	var pos := Vector3(2, 0, 0)
	var before: int = srv._smoke_zones.size()
	srv._place_smoke_wall(1, p, pos)
	assert_eq(srv._smoke_zones.size(), before + 1, "first placement succeeds")
	srv._place_smoke_wall(1, p, pos)
	assert_eq(srv._smoke_zones.size(), before + 1, "second immediate placement blocked by cooldown")
	var cooldown := int(srv._gadgets.def_of_kind(Gadget.KIND_SMOKE_WALL)["cooldown_ticks"])
	srv._sim.tick += cooldown
	srv._place_smoke_wall(1, p, pos)
	assert_eq(srv._smoke_zones.size(), before + 2, "placement succeeds again once cooldown has elapsed")


func test_smoke_wall_out_of_range() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	var p := F.add_pawn(srv, 1, 0, Vector3(0, 0, 0))
	var before: int = srv._smoke_zones.size()
	srv._place_smoke_wall(1, p, Vector3(50, 0, 0))   # far beyond place_range (2.5)
	assert_eq(srv._smoke_zones.size(), before, "no zone — pawn out of place_range")
	assert_eq(srv._net.bytes_of(Protocol.Msg.SMOKE_DEPLOYED).size(), 0, "no broadcast — out of range")
