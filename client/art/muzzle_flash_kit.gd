class_name MuzzleFlashKit
extends Object
## Procedural muzzle-flash effect. Presentation-only (AGENTS.md §7). A small emissive, unshaded,
## alpha-blended plate spawned at the muzzle for a few frames when a shot is fired (local or remote).
## The renderer pools these and drives the fade via alpha_for(). Mirrors the tracer material style.

const COLOR := Color(1.0, 0.85, 0.5)   # warm muzzle-flash tint
const SIZE := 0.4                      # plate width/height, metres
const THICK := 0.08                    # thin along its facing axis (a plate, not a cube)
const TTL := 0.045                     # seconds visible — a brief flash

static func build() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "MuzzleFlash"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(SIZE, SIZE, THICK)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOR
	mat.emission_enabled = true
	mat.emission = COLOR
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
