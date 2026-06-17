class_name VehicleKit
extends Object
## Procedural blocky vehicles. Presentation-only. Sized to data/vehicles.json. Local +Z forward.

static func build(_vehicle_name: String, team: int) -> Node3D:
	# Only 'transport' exists today; all names fall back to it until more are added to vehicles.json.
	var root := Node3D.new()
	var body := ArtPalette.team_material(team)
	var dark := ArtPalette.gun_material()

	root.add_child(_box("Hull", Vector3(2.2, 1.0, 4.0), Vector3(0, 1.0, 0.0), body))
	root.add_child(_box("Cabin", Vector3(1.8, 0.7, 1.6), Vector3(0, 1.7, 0.4), body))
	root.add_child(_box("Turret", Vector3(0.5, 0.5, 1.2), Vector3(0, 2.2, -0.2), dark))
	var wx := 1.05
	var wz := 1.3
	root.add_child(_wheel("WheelFL", Vector3(-wx, 0.45, wz), dark))
	root.add_child(_wheel("WheelFR", Vector3(wx, 0.45, wz), dark))
	root.add_child(_wheel("WheelBL", Vector3(-wx, 0.45, -wz), dark))
	root.add_child(_wheel("WheelBR", Vector3(wx, 0.45, -wz), dark))
	return root

static func _wheel(name: String, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.45
	cyl.height = 0.35
	mi.mesh = cyl
	mi.rotation = Vector3(0, 0, PI * 0.5)   # lay the cylinder on its side (axle along X)
	mi.position = pos
	mi.material_override = mat
	return mi

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi
