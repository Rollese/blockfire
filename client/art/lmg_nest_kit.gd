class_name LmgNestKit
extends Object
## Procedural CURVED SANDBAG emplacement for the deployable LMG nest (M19 P4, G3 round-2).
## Presentation-only (AGENTS.md §7). Local +Z forward, matching the codebase yaw convention
## forward=(sin,0,cos); the renderer sets the root's rotation.y to the nest's facing_yaw.
##
## The gunner mans it PRONE, pinned by the server to seat_world() = pos - forward*SEAT_BACK(0.6) at
## ground, so in THIS local frame their eye sits at ~(0, 0.45, -0.6) looking +Z (prone eye height,
## Stance.eye_height). They shoot their OWN weapon — there is NO mounted turret. So the parapet is a
## quarter/half-circle ring of stacked sandbags wrapping the front + partial sides, tall enough for
## head cover, with an open horizontal EMBRASURE at eye level so the gunner sees + shoots out across
## the ±45° yaw traverse and up to the pitch-up limit.

const GUNNER_LOCAL := Vector3(0.0, 0.0, -0.6)   # gunner ground position in this frame (= -forward*SEAT_BACK)
const RADIUS := 1.2                              # arc radius from the gunner to the sandbag centres
const ARC_DEG := 67.5                            # parapet wraps ±ARC_DEG around +Z (front + partial sides)
const ARC_STEP_DEG := 22.5                       # angular spacing of the stacked blocks along the arc
const BLOCK_W := 0.62                            # tangential width of each block (overlaps its neighbour)
const BLOCK_D := 0.42                            # radial depth of each block

# Vertical courses. The SLIT band (bottom-course top .. cap1 bottom) is left open across the firing
# sector so the prone gunner (eye ~0.45) can see + fire out horizontally and up to +25° pitch, which
# reaches y≈1.01 at the arc — kept below the cap. Solid below for lower-body cover, capped above for
# head cover. Top course reaches ~1.9 m.
const BOTTOM_Y := 0.12   ; const BOTTOM_H := 0.24   # [0.00, 0.24]
const CAP1_Y := 1.31     ; const CAP1_H := 0.42     # [1.10, 1.52]
const CAP2_Y := 1.71     ; const CAP2_H := 0.42     # [1.50, 1.92]
const POST_Y := 0.67     ; const POST_H := 0.86     # [0.24, 1.10] — side end-posts only (outside the arc)

## A curved sandbag parapet resting with its feet at y=0, local +Z forward. No turret. Every block is
## named "Sand…" so the renderer's _apply_nest_damage walks + HP-darkens the whole body.
static func build(_team: int) -> Node3D:
	var root := Node3D.new()
	root.name = "LmgNest"
	var sand := _sandbag_material()

	var half := deg_to_rad(ARC_DEG)
	var step := deg_to_rad(ARC_STEP_DEG)
	var idx := 0
	var theta := -half
	while theta <= half + 0.0001:
		# Full-arc solid courses: below the slit (lower-body cover) and two capping courses (head cover).
		root.add_child(_arc_block("SandBase%d" % idx, theta, BOTTOM_Y, Vector3(BLOCK_W, BOTTOM_H, BLOCK_D), sand))
		root.add_child(_arc_block("SandCapA%d" % idx, theta, CAP1_Y, Vector3(BLOCK_W, CAP1_H, BLOCK_D), sand))
		root.add_child(_arc_block("SandCapB%d" % idx, theta, CAP2_Y, Vector3(BLOCK_W, CAP2_H, BLOCK_D), sand))
		idx += 1
		theta += step
	# Slit-band end-posts close the SIDES without intruding on the ±45° firing arc (posts sit at ±67.5°).
	root.add_child(_arc_block("SandPostL", -half, POST_Y, Vector3(BLOCK_W, POST_H, BLOCK_D), sand))
	root.add_child(_arc_block("SandPostR", half, POST_Y, Vector3(BLOCK_W, POST_H, BLOCK_D), sand))
	return root

## Place a sandbag box at yaw `theta` around the gunner: centre on the arc (radius RADIUS from the
## gunner) at height `y`, yaw-rotated by `theta` so its face follows the tangent.
static func _arc_block(bag_name: String, theta: float, y: float, size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var fwd := Vector3(sin(theta), 0.0, cos(theta))
	var pos := GUNNER_LOCAL + fwd * RADIUS
	pos.y = y
	var mi := MeshInstance3D.new()
	mi.name = bag_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.rotation = Vector3(0.0, theta, 0.0)
	mi.material_override = mat
	return mi

## Sandy, NEAREST-filtered, world-triplanar sandbag material (matches the building/structure pixel
## look). The renderer's _apply_nest_damage rewrites albedo_color for HP darkening; the texture stays.
static func _sandbag_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ArtPalette.STRUCT_SAND
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.albedo_texture = BuildingTextures.tex("sandbag")
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST   # game-wide pixel look
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3.ONE   # ~1 sandbag tile per metre in world space (hides box UV seams)
	return mat
