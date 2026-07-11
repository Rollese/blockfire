extends TestCase
## M19 P2b Task 4: Medic Combat Stim server sim — server-owned per-client charges, GA_STIM_USE
## handler, damage-resist + suppression-immunity while stimmed, and refill via ammo resupply.
## Real server paths via server_fixture.gd, not mirrors.

const F := preload("res://tests/server_fixture.gd")


func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons.json loads")


func teardown() -> void:
	Weapon.reset_registry()


## A ServerMain with the real gadget catalog loaded (stim def resolves).
func _srv() -> Node:
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	assert_true(srv._gadgets != null, "gadgets.json loads")
	return srv


func _medic_client(srv, id: int) -> Dictionary:
	var c := F.add_client(srv, id, 0, false)
	c["class"] = Loadout.MEDIC
	c["loadout"]["class"] = Loadout.MEDIC
	c["loadout"]["gadget"] = Loadout.GADGET_STIM
	return c


func test_stim_use_consumes_charge_and_buffs() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	c["stim_charges"] = 3
	var p := F.add_pawn(srv, 1, 0)
	srv._use_stim(1)
	assert_eq(int(c["stim_charges"]), 2, "one charge spent")
	assert_true(p.stim_until_tick > srv._sim.tick, "stim buff window set in the future")


func test_stim_use_gated_on_gadget() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	c["loadout"]["gadget"] = Loadout.GADGET_HEAL
	c["stim_charges"] = 3
	var p := F.add_pawn(srv, 1, 0)
	srv._use_stim(1)
	assert_eq(int(c["stim_charges"]), 3, "no charge spent — wrong gadget equipped")
	assert_eq(p.stim_until_tick, 0, "no buff — wrong gadget equipped")


func test_stim_use_cooldown() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	c["stim_charges"] = 3
	F.add_pawn(srv, 1, 0)
	srv._use_stim(1)
	assert_eq(int(c["stim_charges"]), 2, "first use spends a charge")
	var cooldown_ticks := int(srv._gadgets.def_of_kind(Gadget.KIND_STIM)["use_cooldown_ticks"])
	# Immediate re-use within the cooldown window must be blocked — no charge spent.
	srv._use_stim(1)
	assert_eq(int(c["stim_charges"]), 2, "re-use inside cooldown window is blocked")
	# Advance past the cooldown gate (stim_ready_tick) and try again — should succeed.
	srv._sim.tick = int(c["stim_ready_tick"]) + 1
	assert_true(cooldown_ticks > 0, "sanity: catalog cooldown is nonzero")
	srv._use_stim(1)
	assert_eq(int(c["stim_charges"]), 1, "use succeeds once cooldown has elapsed")


func test_stim_use_blocked_when_empty() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	c["stim_charges"] = 0
	var p := F.add_pawn(srv, 1, 0)
	srv._use_stim(1)
	assert_eq(int(c["stim_charges"]), 0, "still empty")
	assert_eq(p.stim_until_tick, 0, "no buff — pool exhausted")


func test_stim_damage_resist() -> void:
	var srv := _srv()
	_medic_client(srv, 1)
	_medic_client(srv, 2)
	var stimmed := F.add_pawn(srv, 1, 0)
	var plain := F.add_pawn(srv, 2, 0)
	stimmed.stim_until_tick = srv._sim.tick + 100
	srv._apply_pawn_damage(1, stimmed, 40, false, Revive.Source.BULLET, 0, 0)
	srv._apply_pawn_damage(2, plain, 40, false, Revive.Source.BULLET, 0, 0)
	var stimmed_loss := 100 - int(stimmed.health)
	var plain_loss := 100 - int(plain.health)
	assert_true(stimmed_loss < plain_loss, "stimmed victim (%d lost) takes less damage than unstimmed (%d lost)" % [stimmed_loss, plain_loss])


func test_stim_suppression_immunity() -> void:
	var srv := _srv()
	var p := F.add_pawn(srv, 1, 0)
	p.stim_until_tick = srv._sim.tick + 10
	p.suppression = 0.8
	srv._step_suppression_decay()
	assert_eq(p.suppression, 0.0, "stim grants full suppression immunity, not just faster decay")


func test_stim_refill_from_giveammo() -> void:
	var srv := _srv()
	var c := _medic_client(srv, 1)
	c["stim_charges"] = 0
	c["ammo"] = int(Weapon.get_def(c["weapon"])["mag_size"])   # already full — isolates the stim-only refill
	c["reserve"] = srv._spawn_reserve(int(c["weapon"]), int(c["class"]))
	F.add_pawn(srv, 1, 0)
	srv._support.give_ammo(1, 1)   # period=1 -> always fires on tick 0
	var refill := int(srv._gadgets.def_of_kind(Gadget.KIND_STIM)["refill"])
	assert_eq(int(c["stim_charges"]), refill, "resupply tops the Medic's stim pool to the catalog refill")
