extends TestCase

func test_transport_has_hull_four_wheels_and_turret() -> void:
	var v := VehicleKit.build("transport", 0)
	assert_true(v.has_node("Hull"), "has a hull")
	assert_true(v.has_node("Turret"), "has a turret")
	var wheels := 0
	for c in v.get_children():
		if String(c.name).begins_with("Wheel"):
			wheels += 1
	assert_eq(wheels, 4, "four wheels")

func test_turret_sits_at_turret_offset_height() -> void:
	var v := VehicleKit.build("transport", 1)
	var turret := v.get_node("Turret") as Node3D
	assert_almost_eq(turret.position.y, 2.2, 0.1, "turret at vehicles.json turret_offset y")

func test_hull_is_team_tinted() -> void:
	var hull := VehicleKit.build("transport", 1).get_node("Hull") as MeshInstance3D
	assert_eq((hull.material_override as StandardMaterial3D).albedo_color, Color(1.0, 0.3, 0.2),
		"team 1 hull is red")

func test_unknown_vehicle_falls_back_to_transport() -> void:
	assert_true(VehicleKit.build("mystery", 0).has_node("Hull"), "unknown name renders as transport")
