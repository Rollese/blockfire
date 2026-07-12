class_name LmgNestKit
extends Object
## Procedural blocky LMG nest (M19 P4). Presentation-only (AGENTS.md §7). Local +Z forward, matching
## the codebase yaw convention forward=(sin,0,cos), so the renderer can set the root's rotation.y to
## the nest's facing_yaw. A child Node3D named "Barrel" (pivot at the server muzzle height 1.1 m) holds
## the mounted gun pointing +Z at local yaw 0; the renderer rotates it toward the gunner's turret aim.

const MUZZLE_UP := 1.1   # matches Emplacement.MUZZLE_UP — gun pivot sits ~waist/chest high

## Team-tinted sandbag/tripod base + a "Barrel" child holding a gun-metal MG. The root sits with its
## feet at y=0 so it rests on the ground directly at the nest position.
static func build(team: int) -> Node3D:
	var root := Node3D.new()
	root.name = "LmgNest"
	var sand := ArtPalette.team_material(team)   # team-tinted sandbag berm (also carries the damage tint)
	var dark := ArtPalette.gun_material()

	# Low sandbag berm around the firing side (+Z front): a waist-high front wall + two short returns,
	# so the nest reads as cover the gunner hunkers behind.
	root.add_child(_box("SandFront", Vector3(1.6, 0.5, 0.4), Vector3(0.0, 0.25, 0.7), sand))
	root.add_child(_box("SandL", Vector3(0.4, 0.5, 0.8), Vector3(-0.8, 0.25, 0.35), sand))
	root.add_child(_box("SandR", Vector3(0.4, 0.5, 0.8), Vector3(0.8, 0.25, 0.35), sand))
	# Tripod/mount post carrying the gun pivot up to muzzle height.
	root.add_child(_box("Mount", Vector3(0.2, MUZZLE_UP, 0.2), Vector3(0.0, MUZZLE_UP * 0.5, 0.0), dark))

	# Barrel pivot at muzzle height. Contains the receiver + long barrel pointing +Z (local yaw 0);
	# the renderer sets Barrel.rotation.y so the gun traverses toward the gunner's aim.
	var barrel := Node3D.new()
	barrel.name = "Barrel"
	barrel.position = Vector3(0.0, MUZZLE_UP, 0.0)
	barrel.add_child(_box("Receiver", Vector3(0.16, 0.16, 0.5), Vector3(0.0, 0.0, 0.1), dark))
	barrel.add_child(_box("Gun", Vector3(0.08, 0.08, 0.7), Vector3(0.0, 0.02, 0.55), dark))
	barrel.add_child(_box("Stock", Vector3(0.1, 0.14, 0.3), Vector3(0.0, -0.02, -0.22), dark))
	root.add_child(barrel)
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
