class_name CharacterKit
extends Object
## Procedural blocky soldier. Presentation-only. Built at STAND height; the renderer scales the
## root vertically to Stance.body_height each frame. Local +Z is forward (gun mount + aim).
## NOT team-tinted (BattleBit-style): every player wears the same uniform. Friend/foe is shown by
## a separate blue marker the renderer floats above friendlies — never by body colour. The `team`
## arg is kept for call-site compatibility but does not affect appearance.

const STAND_HEIGHT := 1.8   # must track Stance.body_height(STAND)

static func build(_team: int = 0) -> Node3D:
	var root := Node3D.new()
	var mat := ArtPalette.uniform_material()
	var dark := ArtPalette.gun_material()

	var legs := _box("Legs", Vector3(0.5, 0.8, 0.3), Vector3(0.0, 0.4, 0.0), mat)
	root.add_child(legs)
	var torso := _box("Torso", Vector3(0.55, 0.6, 0.35), Vector3(0.0, 1.1, 0.0), mat)
	root.add_child(torso)
	var arm_l := _box("ArmL", Vector3(0.16, 0.55, 0.16), Vector3(-0.36, 1.1, 0.0), mat)
	root.add_child(arm_l)
	var arm_r := _box("ArmR", Vector3(0.16, 0.55, 0.16), Vector3(0.36, 1.1, 0.0), mat)
	root.add_child(arm_r)
	var head := _box("Head", Vector3(0.28, 0.28, 0.28), Vector3(0.0, 1.55, 0.0), mat)
	root.add_child(head)
	var helmet := _box("Helmet", Vector3(0.32, 0.12, 0.32), Vector3(0.0, 1.72, 0.0), dark)
	root.add_child(helmet)
	# Gun mount: short box at +Z, chest height, right side — same convention as the capsule's barrel.
	var gun := _box("GunMount", Vector3(0.08, 0.08, 0.6), Vector3(0.22, 1.15, 0.45), dark)
	root.add_child(gun)
	return root

const _GUNMOUNT_LEN := 0.6     # base GunMount Z length (see build())
const _GUNMOUNT_GRIP_Z := 0.15 # base grip (back) end Z — kept fixed so the muzzle grows forward

## Per-weapon GunMount silhouette: returns {"scale": Vector3, "pos_z": float} for the "GunMount" node so
## a remote's weapon is identifiable from its outline (a core BattleBit readability cue). x/y scale =
## girth, z scale = barrel length; pos_z keeps the grip at the body and extends the muzzle forward.
## Pure (testable). Unknown ids fall back to the AR profile.
static func held_weapon_xform(weapon_id: int) -> Dictionary:
	var profile := {            # weapon_id -> [girth_mult, length_mult]
		0: [1.0, 1.0],          # AR     — baseline rifle
		1: [1.05, 0.62],        # SMG    — short, a touch fatter
		2: [0.85, 1.55],        # DMR    — long, thin marksman barrel
		3: [2.3, 1.4],          # RPG    — fat, long launcher tube
		4: [0.9, 0.34],         # PISTOL — stubby sidearm
	}
	var p: Array = profile.get(weapon_id, profile[0])
	var girth: float = float(p[0])
	var length: float = float(p[1])
	return {
		"scale": Vector3(girth, girth, length),
		"pos_z": _GUNMOUNT_GRIP_Z + 0.5 * _GUNMOUNT_LEN * length,
	}

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi

## Union AABB of all MeshInstance3D children (local space). Headless-safe (geometry only).
static func aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for child in root.get_children():
		if child is MeshInstance3D:
			var box: AABB = (child as MeshInstance3D).mesh.get_aabb()
			box.position += (child as MeshInstance3D).position
			if first:
				out = box; first = false
			else:
				out = out.merge(box)
	return out
