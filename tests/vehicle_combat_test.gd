extends TestCase

func _def() -> Dictionary:
	return VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)

func test_blast_falloff_reduces_hp() -> void:
	var v := Vehicle.make(Vehicle.id_for(0), 0, _def(), 1, Vector3.ZERO)
	# RPG centre hit: falloff at distance 0 == full dmg
	var dmg := Grenade.falloff_damage(Vector3.ZERO, v.pos, 500, 6.0)
	v.hp -= dmg
	assert_eq(v.hp, 100)   # 600 hull - 500 centre hit

func test_two_rockets_destroy_full_hull() -> void:
	var v := Vehicle.make(Vehicle.id_for(0), 0, _def(), 1, Vector3.ZERO)
	v.hp -= Grenade.falloff_damage(Vector3.ZERO, v.pos, 500, 6.0)
	v.hp -= Grenade.falloff_damage(Vector3.ZERO, v.pos, 500, 6.0)
	assert_true(v.hp <= 0)

func test_apply_vehicle_damage_marks_destroyed_and_clears_seats() -> void:
	var v := Vehicle.make(Vehicle.id_for(0), 0, _def(), 1, Vector3.ZERO)
	v.seats[0] = 7; v.seats[4] = 9
	var occupants: Array = v.occupant_ids()
	assert_eq(occupants.size(), 2)
	v.mark_destroyed(100)   # tick 100
	assert_false(v.alive)
	assert_eq(v.respawn_tick, 100 + v.respawn_ticks)
	for s in v.seats: assert_eq(int(s), 0)   # seats cleared
