extends TestCase
## M19 P2b Task 4: Engineer REPAIR gadget repairs STRUCTURES the engineer aims at (not just
## vehicles), gated on the engineer's SELECTED gadget being GADGET_REPAIR. Reuses the real
## ServerSupport.step_repairs() + StructureStore.repair_chunks() via server_fixture.gd — not a
## mirror of the server logic.

const F := preload("res://tests/server_fixture.gd")


func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons.json loads")


func teardown() -> void:
	Weapon.reset_registry()


## A ServerMain with the real gadget catalog loaded (repairkit def resolves).
func _srv() -> Node:
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	assert_true(srv._gadgets != null, "gadgets.json loads")
	return srv


## A wall cell directly ahead of a pawn standing at z=-0.5 facing +z (cell (0,0,0)), mirroring
## breach_test.gd / grenade_gate_test.gd's _place_front_wall.
func _place_front_wall(srv) -> int:
	var bwall: int = srv._catalog.index_of("bwall")
	srv._store.place(1, bwall, Vector3i(0, 0, 0), 0, -1, 1)
	return 1


func _popcount(m: int) -> int:
	var c := 0
	for i in 64:
		if (m & (1 << i)) != 0:
			c += 1
	return c


func test_engineer_with_repair_gadget_heals_structure() -> void:
	var srv := _srv()
	var c := F.add_client(srv, 1, 0, false)
	c["class"] = Loadout.ENGINEER
	c["loadout"]["gadget"] = Loadout.GADGET_REPAIR
	var p := F.add_pawn(srv, 1, 0, Vector3(0, 0, -0.5))
	p.yaw = 0.0
	var wid := _place_front_wall(srv)
	# Sanity: the pawn's aim ray reaches the (still-intact) front wall before we carve anything.
	var dir := Combat._forward(p.yaw, p.pitch)
	var m: Dictionary = srv._store.march(p.eye_position(), dir, 4.0)
	assert_true(bool(m["hit"]), "aim ray hits the front wall")
	# Punch a hole OFFSET from the exact aim point (not through it — a cleared chunk at the ray's
	# own contact point would make march() pass through the hole instead of registering a hit, so
	# the repair loop below could never find the structure to heal). The offset (1.05 m) clears the
	# repair-range check (repair_chunks radius = repairkit range*0.35 = 1.4 m) while staying outside
	# the aimed chunk's own footprint (repair carve radius 0.6 m + max per-chunk jitter 0.22 m).
	var impact: Vector3 = p.eye_position() + dir * float(m["dist"]) + Vector3(1.05, 0, 0)
	srv._store.damage_chunks(wid, PieceCatalog.SRC_EXPLOSIVE, impact, 0.6)
	var mask_before: int = srv._store.get_record(wid)["chunks"]
	assert_true(_popcount(mask_before) < 64, "carve actually holed the wall")
	srv._support.repairing[1] = true
	for _i in 30:
		srv._sim.tick += 1
		srv._support.step_repairs()
	var mask_after: int = srv._store.get_record(wid)["chunks"]
	assert_true(_popcount(mask_after) > _popcount(mask_before),
		"engineer with REPAIR selected heals chunks on the aimed structure")


func test_engineer_without_repair_gadget_does_nothing() -> void:
	var srv := _srv()
	var c := F.add_client(srv, 1, 0, false)
	c["class"] = Loadout.ENGINEER
	c["loadout"]["gadget"] = Loadout.GADGET_C4
	var p := F.add_pawn(srv, 1, 0, Vector3(0, 0, -0.5))
	p.yaw = 0.0
	var wid := _place_front_wall(srv)
	var dir := Combat._forward(p.yaw, p.pitch)
	var m: Dictionary = srv._store.march(p.eye_position(), dir, 4.0)
	assert_true(bool(m["hit"]), "aim ray hits the front wall")
	# Punch a hole OFFSET from the exact aim point (not through it — a cleared chunk at the ray's
	# own contact point would make march() pass through the hole instead of registering a hit, so
	# aimed_damaged_structure would return {} and "heal nothing" regardless of the gadget gate,
	# proving nothing). Mirrors the offset carve in the positive test above.
	var impact: Vector3 = p.eye_position() + dir * float(m["dist"]) + Vector3(1.05, 0, 0)
	srv._store.damage_chunks(wid, PieceCatalog.SRC_EXPLOSIVE, impact, 0.6)
	var mask_before: int = srv._store.get_record(wid)["chunks"]
	assert_true(_popcount(mask_before) < 64, "carve actually holed the wall")
	srv._support.repairing[1] = true
	for _i in 30:
		srv._sim.tick += 1
		srv._support.step_repairs()
	var mask_after: int = srv._store.get_record(wid)["chunks"]
	assert_eq(mask_after, mask_before, "non-REPAIR gadget selected -> aimed structure is not healed")
