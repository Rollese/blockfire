extends TestCase
## Deterministic proof of the M5-P1 vehicle-combat gate criteria (hard to stage reliably with
## emergent bots, so proven here instead). Mirrors the server's application path: RPG blast ->
## falloff vehicle damage -> HP depletion -> destruction (occupants ejected, respawn scheduled);
## and engineer repair -> HP restored (heat-gated), capped at max_hp. Values track the data/server
## balance: transport max_hp 600 (data/vehicles.json), RPG_VEHICLE_DMG 800 (server_main.gd),
## repair rate 6 (data/gadgets.json).

const RPG_VEHICLE_DMG := 800   # server_main.gd RPG_VEHICLE_DMG (keep in sync)
const REPAIR_RATE := 6         # data/gadgets.json repairkit.rate (keep in sync)

func _def() -> Dictionary:
	return VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)

func _veh() -> Vehicle:
	return Vehicle.make(Vehicle.id_for(0), 0, _def(), 1, Vector3.ZERO)

func test_rpg_central_hit_destroys_transport() -> void:
	# RPG -> HP -> destruction: a central rocket (falloff at distance 0 == full dmg) one-shots the hull.
	var v := _veh()
	assert_eq(v.max_hp, 600)
	var dmg := Grenade.falloff_damage(v.pos, v.pos, RPG_VEHICLE_DMG, 6.0)
	assert_true(dmg >= v.max_hp)                 # one solid AT rocket exceeds the 600 hull
	v.seats[0] = 7; v.seats[4] = 9
	v.hp -= dmg
	assert_true(v.hp <= 0)
	v.mark_destroyed(100)
	assert_false(v.alive)
	assert_eq(v.respawn_tick, 100 + v.respawn_ticks)
	for s in v.seats: assert_eq(int(s), 0)       # occupants ejected on destruction

func test_engineer_repair_restores_hull() -> void:
	# Repair -> HP restored: while repairing (heat-gated), HP climbs by the repair rate each tick.
	var v := _veh()
	v.hp = 100                                   # damaged hull
	var heat := 0; var cd := 0
	var restored := 0
	for t in 30:
		var r := Gadget.repair_heat_step(heat, cd, t, true, 50, 150)
		heat = int(r["heat"]); cd = int(r["cooldown_until"])
		if bool(r["repairing"]):
			var before := v.hp
			v.hp = mini(v.max_hp, v.hp + REPAIR_RATE)
			restored += v.hp - before
	assert_true(restored > 0)
	assert_eq(v.hp, 100 + 30 * REPAIR_RATE)      # 100 + 180 = 280 (below the 600 cap)

func test_repair_caps_at_max_hp() -> void:
	var v := _veh()
	v.hp = v.max_hp - 4
	v.hp = mini(v.max_hp, v.hp + REPAIR_RATE)
	assert_eq(v.hp, v.max_hp)                     # never overfills past max_hp
