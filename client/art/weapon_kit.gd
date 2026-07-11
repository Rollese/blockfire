class_name WeaponKit
extends Object
## Procedural blocky weapons keyed by the Weapon enum. Presentation-only. Barrel runs along +Z
## (muzzle forward), matching the entity/viewmodel forward convention.

# Per-weapon: receiver length, barrel length, has_stock, is_launcher.
const _SPEC := {
	Weapon.AR:  {"receiver": 0.30, "barrel": 0.35, "stock": true,  "launcher": false},
	Weapon.SMG: {"receiver": 0.22, "barrel": 0.18, "stock": false, "launcher": false},
	Weapon.DMR: {"receiver": 0.34, "barrel": 0.55, "stock": true,  "launcher": false},
	Weapon.RPG: {"receiver": 0.40, "barrel": 0.50, "stock": false, "launcher": true},
}

static func build(weapon_id: int) -> Node3D:
	var spec: Dictionary = _SPEC.get(Weapon.archetype_of(weapon_id), _SPEC[Weapon.AR])
	var root := Node3D.new()
	var metal := ArtPalette.gun_material()
	var receiver_len: float = spec["receiver"]
	var barrel_len: float = spec["barrel"]
	var caliber := 0.10 if bool(spec["launcher"]) else 0.05

	root.add_child(_box("Receiver", Vector3(0.07, 0.12, receiver_len), Vector3(0, 0, 0), metal))
	root.add_child(_box("Barrel", Vector3(caliber, caliber, barrel_len),
		Vector3(0, 0.02, receiver_len * 0.5 + barrel_len * 0.5), metal))
	root.add_child(_box("Mag", Vector3(0.05, 0.18, 0.10), Vector3(0, -0.14, -0.02), metal))
	if bool(spec["stock"]):
		root.add_child(_box("Stock", Vector3(0.06, 0.10, 0.20),
			Vector3(0, -0.02, -receiver_len * 0.5 - 0.10), metal))
	if bool(spec["launcher"]):
		var cone := MeshInstance3D.new()
		cone.name = "Warhead"
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = 0.12
		cm.height = 0.22
		cone.mesh = cm
		cone.rotation = Vector3(PI * 0.5, 0, 0)   # point the cone along +Z
		cone.position = Vector3(0, 0.02, receiver_len * 0.5 + barrel_len + 0.11)
		cone.material_override = ArtPalette.team_material(99)  # neutral grey warhead
		root.add_child(cone)
	return root

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi

static func aabb(root: Node3D) -> AABB:
	return CharacterKit.aabb(root)   # reuse the union-AABB helper
