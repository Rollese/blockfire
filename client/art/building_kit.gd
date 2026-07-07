class_name BuildingKit
extends Object
## Procedural low-poly geometry for M11 building pieces. Presentation-only, no team-tint. Keyed by
## piece id + damage bucket (3 pristine .. 0 heavy), mirroring StructureKit's damage read.

const CELL := 2.0  # BuildGrid.CELL_SIZE
const TEX_WORLD_SCALE := 1.0   # texture tiles per metre (world-triplanar) — shared by walls + hole chunks

# Per-piece palette — distinct tones so a building reads as walls/floors/columns/trim instead of a
# uniform grey blob (playtest feedback 2026-06-18). Tints still modulate by damage bucket in _box().
const COL_WALL := Color(0.72, 0.68, 0.60)    # warm concrete / sandstone wall
const COL_FLOOR := Color(0.46, 0.36, 0.25)   # wood / dirt deck
const COL_STRUCT := Color(0.34, 0.34, 0.38)  # dark structural column
const COL_METAL := Color(0.24, 0.24, 0.26)   # dark metal railing
const COL_TRIM := Color(0.40, 0.30, 0.22)    # brown door/window frame
const COL_STEP_A := Color(0.54, 0.52, 0.49)  # stair step (alternating)
const COL_STEP_B := Color(0.42, 0.40, 0.38)
const COL_BRICK := Color(0.64, 0.34, 0.27)   # brick-red wall
const COL_METALW := Color(0.56, 0.58, 0.62)  # industrial metal wall
const COL_WOODW := Color(0.56, 0.43, 0.29)   # timber wall
const COL_RUBBLE_A := Color(0.55, 0.53, 0.49) # broken concrete (light)
const COL_RUBBLE_B := Color(0.47, 0.45, 0.42) # broken concrete (mid)
const COL_RUBBLE_C := Color(0.60, 0.58, 0.54) # broken concrete (pale)
const COL_FOUND := Color(0.46, 0.45, 0.43)   # concrete foundation slab / floor-skirt under walls

static func build(piece_id: String, bucket: int, floor_skirt: bool = false, yaw_step: int = 0) -> Node3D:
	var root := Node3D.new()
	if floor_skirt:
		# Ground-level perimeter walls/columns and interior prop cells hold a single centred piece but NO
		# floor — the interior `bfloor` decks only cover bare interior cells (one-piece-per-cell), leaving a
		# see-through strip inside every exterior wall + under every prop (playtest 2026-06-20 open item #1).
		# Drop a deck slab in the piece's own cell so the floor reads continuous. Same slab as `bfloor`,
		# posed at the same cell base -> coplanar with the interior decks (adjacent cells, no overlap/z-fight).
		# Perimeter walls overhang the thin wall by ~0.85 m on the exterior side, so they use a CONCRETE
		# foundation tone (reads as a base ledge, not a wooden pallet); interior props use the WOOD deck tone
		# (always surrounded by interior, no overhang) so they match the floor. Full-tint (bucket 3) so a
		# damaged piece doesn't darken the floor below it.
		var is_prop := piece_id.begins_with("prop_")
		var skirt_col := COL_FLOOR if is_prop else COL_FOUND
		var skirt_tex := "wood" if is_prop else "concrete"
		root.add_child(_box("Skirt", Vector3(CELL, 0.32, CELL), Vector3(0, -0.12, 0), 3, skirt_col, skirt_tex))
	match piece_id:
		"bcolumn":
			root.add_child(_box("Col", Vector3(0.5, CELL, 0.5), Vector3(0, CELL * 0.5, 0), bucket, COL_STRUCT))
		"bfloor":
			# Walkable surface = cell base plane (M14). Hang the slab just below it so the pawn's feet
			# rest on the visible top.
			# Slab top sits a hair ABOVE the cell base so a roof slab swallows the wall top below it
			# (was coplanar -> z-fight "walls clipping the roof"). Walkable surface stays ~cell base.
			root.add_child(_box("Floor", Vector3(CELL, 0.32, CELL), Vector3(0, -0.12, 0), bucket, COL_FLOOR, "wood"))
		"brailing":
			root.add_child(_box("Rail", Vector3(CELL, 0.1, 0.1), Vector3(0, CELL * 0.5, 0), bucket, COL_METAL))
		"prop_table":
			root.add_child(_box("TTop", Vector3(1.3, 0.1, 0.8), Vector3(0, 0.72, 0), bucket, COL_WOODW, "wood"))
			for lx in [-0.55, 0.55]:
				for lz in [-0.32, 0.32]:
					root.add_child(_box("TLeg", Vector3(0.08, 0.7, 0.08), Vector3(lx, 0.36, lz), bucket, COL_WOODW, ""))
		"prop_chair":
			root.add_child(_box("CSeat", Vector3(0.45, 0.08, 0.45), Vector3(0, 0.45, 0), bucket, COL_WOODW, ""))
			root.add_child(_box("CBack", Vector3(0.45, 0.5, 0.08), Vector3(0, 0.7, -0.18), bucket, COL_WOODW, ""))
			for lx in [-0.18, 0.18]:
				for lz in [-0.18, 0.18]:
					root.add_child(_box("CLeg", Vector3(0.05, 0.45, 0.05), Vector3(lx, 0.22, lz), bucket, COL_WOODW, ""))
		"prop_shelf":
			root.add_child(_box("Shelf", Vector3(0.9, 1.7, 0.4), Vector3(0, 0.85, 0), bucket, COL_WOODW, "wood"))
		"prop_locker":
			root.add_child(_box("Locker", Vector3(0.5, 1.7, 0.5), Vector3(0, 0.85, 0), bucket, COL_METALW, "metal"))
		"prop_barrel":
			root.add_child(_cyl(0.28, 0.9, Vector3(0, 0.45, 0), bucket, COL_METALW))
		"prop_crate":
			root.add_child(_box("Crate", Vector3(0.9, 0.9, 0.9), Vector3(0, 0.45, 0), bucket, Color(0.45, 0.32, 0.18), "wood"))
		"bwall_window":
			# Kenney-style framed window: a large opening (1.1 x 0.95 m) left by solid sill/header/side
			# fills (these form the CELL-wide carvable slab -> chunk-hole promotion stays seamless), a
			# RECESSED glazing pane + mullions read as a real window, and a proud trim frame + sill ledge
			# give the face depth. Trim/glazing are shallow relief -> they harmlessly drop when the slab carves.
			var op_h := 0.95      # opening height
			var op_cy := 1.325    # opening centre Y (sill at ~0.85, head at ~1.80)
			var op_hw := 0.55     # opening half-width
			root.add_child(_box("Sill", Vector3(CELL, 0.85, 0.3), Vector3(0, 0.425, 0), bucket, COL_WALL))
			root.add_child(_box("Header", Vector3(CELL, 0.20, 0.3), Vector3(0, 1.90, 0), bucket, COL_WALL))
			root.add_child(_box("WSideL", Vector3(CELL * 0.5 - op_hw, op_h, 0.3), Vector3(-(op_hw + (CELL * 0.5 - op_hw) * 0.5), op_cy, 0), bucket, COL_WALL))
			root.add_child(_box("WSideR", Vector3(CELL * 0.5 - op_hw, op_h, 0.3), Vector3(op_hw + (CELL * 0.5 - op_hw) * 0.5, op_cy, 0), bucket, COL_WALL))
			# Recessed glazing + a simple mullion cross (flat, slightly behind the face plane).
			root.add_child(_box("Glaze", Vector3(op_hw * 2.0, op_h, 0.05), Vector3(0, op_cy, -0.06), 3, Color(0.22, 0.27, 0.32), ""))
			root.add_child(_box("MullV", Vector3(0.05, op_h, 0.06), Vector3(0, op_cy, -0.02), bucket, COL_TRIM, ""))
			root.add_child(_box("MullH", Vector3(op_hw * 2.0, 0.05, 0.06), Vector3(0, op_cy, -0.02), bucket, COL_TRIM, ""))
			# Proud trim frame + a sill ledge for depth (face is at z=+0.15).
			root.add_child(_box("TrimT", Vector3(op_hw * 2.0 + 0.14, 0.09, 0.10), Vector3(0, op_cy + op_h * 0.5, 0.16), bucket, COL_TRIM, ""))
			root.add_child(_box("TrimL", Vector3(0.09, op_h + 0.18, 0.10), Vector3(-op_hw - 0.05, op_cy, 0.16), bucket, COL_TRIM, ""))
			root.add_child(_box("TrimR", Vector3(0.09, op_h + 0.18, 0.10), Vector3(op_hw + 0.05, op_cy, 0.16), bucket, COL_TRIM, ""))
			root.add_child(_box("SillLedge", Vector3(op_hw * 2.0 + 0.30, 0.10, 0.16), Vector3(0, op_cy - op_h * 0.5, 0.12), bucket, COL_TRIM, ""))
		"bwall_door":
			# Framed doorway: full-height solid side fills (the carvable slab) leave a ~1 m opening; a
			# RECESSED panelled door slab + a proud trim surround give it depth. The cell above is the header.
			var d_hw := 0.5                      # door opening half-width
			var side_w := CELL * 0.5 - d_hw      # solid fill each side of the opening
			root.add_child(_box("DSideL", Vector3(side_w, CELL, 0.3), Vector3(-(d_hw + side_w * 0.5), CELL * 0.5, 0), bucket, COL_WALL))
			root.add_child(_box("DSideR", Vector3(side_w, CELL, 0.3), Vector3(d_hw + side_w * 0.5, CELL * 0.5, 0), bucket, COL_WALL))
			# Recessed door leaf (dark wood) + two proud panel strips so it reads as a real door.
			root.add_child(_box("DoorLeaf", Vector3(d_hw * 2.0 - 0.08, CELL - 0.1, 0.06), Vector3(0, (CELL - 0.1) * 0.5, -0.05), 3, Color(0.32, 0.22, 0.14), ""))
			root.add_child(_box("DPanelL", Vector3(0.06, CELL - 0.4, 0.03), Vector3(-0.22, CELL * 0.5, -0.01), 3, Color(0.26, 0.18, 0.11), ""))
			root.add_child(_box("DPanelR", Vector3(0.06, CELL - 0.4, 0.03), Vector3(0.22, CELL * 0.5, -0.01), 3, Color(0.26, 0.18, 0.11), ""))
			# Proud trim surround (jambs + lintel) at the face.
			root.add_child(_box("DJambL", Vector3(0.10, CELL, 0.12), Vector3(-d_hw - 0.05, CELL * 0.5, 0.16), bucket, COL_TRIM, ""))
			root.add_child(_box("DJambR", Vector3(0.10, CELL, 0.12), Vector3(d_hw + 0.05, CELL * 0.5, 0.16), bucket, COL_TRIM, ""))
			root.add_child(_box("DLintel", Vector3(d_hw * 2.0 + 0.20, 0.12, 0.12), Vector3(0, CELL - 0.06, 0.16), bucket, COL_TRIM, ""))
		"bstair":
			for s in range(4):
				var h := CELL * (float(s) + 1.0) / 4.0
				var step_col := COL_STEP_A if s % 2 == 0 else COL_STEP_B
				root.add_child(_box("Step%d" % s, Vector3(CELL, CELL * 0.25, CELL / 4.0), Vector3(0, h * 0.5, -CELL * 0.5 + (float(s) + 0.5) * CELL / 4.0), bucket, step_col))
		"bwall_garage":
			# wide bay/garage opening: side posts + header beam, open span (walk/drive through)
			root.add_child(_box("BayL", Vector3(CELL * 0.16, CELL, 0.4), Vector3(-CELL * 0.42, CELL * 0.5, 0), bucket, COL_METALW, "metal"))
			root.add_child(_box("BayR", Vector3(CELL * 0.16, CELL, 0.4), Vector3(CELL * 0.42, CELL * 0.5, 0), bucket, COL_METALW, "metal"))
			root.add_child(_box("BayTop", Vector3(CELL, CELL * 0.2, 0.4), Vector3(0, CELL * 0.9, 0), bucket, COL_METALW, "metal"))
		"bwall_glass":
			# storefront/curtain glass: thin frame + a translucent pane
			root.add_child(_box("GFrameB", Vector3(CELL, CELL * 0.14, 0.3), Vector3(0, CELL * 0.07, 0), bucket, COL_METALW, "metal"))
			root.add_child(_box("GFrameT", Vector3(CELL, CELL * 0.1, 0.3), Vector3(0, CELL * 0.95, 0), bucket, COL_METALW, "metal"))
			root.add_child(_box("GFrameL", Vector3(CELL * 0.1, CELL, 0.3), Vector3(-CELL * 0.45, CELL * 0.5, 0), bucket, COL_METALW, "metal"))
			root.add_child(_box("GFrameR", Vector3(CELL * 0.1, CELL, 0.3), Vector3(CELL * 0.45, CELL * 0.5, 0), bucket, COL_METALW, "metal"))
			root.add_child(_box("GMull", Vector3(0.08, CELL, 0.3), Vector3(0, CELL * 0.5, 0), bucket, COL_METALW, "metal"))
			root.add_child(_glass(Vector3(CELL * 0.84, CELL * 0.78, 0.06), Vector3(0, CELL * 0.5, 0)))
		"bwall_half":
			# low / parapet / fence wall (half height)
			root.add_child(_box("LowWall", Vector3(CELL, CELL * 0.5, 0.3), Vector3(0, CELL * 0.25, 0), bucket, COL_WALL, "concrete"))
		"bwall_brick":
			root.add_child(_box("Brick", Vector3(CELL, CELL, 0.3), Vector3(0, CELL * 0.5, 0), bucket, COL_BRICK, "brick"))
		"bwall_metal":
			root.add_child(_box("MetalW", Vector3(CELL, CELL, 0.3), Vector3(0, CELL * 0.5, 0), bucket, COL_METALW, "metal"))
		"bwall_wood":
			root.add_child(_box("WoodW", Vector3(CELL, CELL, 0.3), Vector3(0, CELL * 0.5, 0), bucket, COL_WOODW, "wood"))
		"bwall_corner":
			# Edge-aligned L: two thin walls on the cell's two EXTERIOR edges, meeting flush at the
			# footprint corner. This matches the straight walls (also shifted to the exterior edge below),
			# so the corner closes on the footprint outline — no centred cross/X, no inset. yaw_step
			# 0/2/4/6 selects which two edges are exterior (SW/SE/NE/NW).
			var t := 0.3
			var edge := CELL * 0.5 - t * 0.5
			var h := CELL * 0.5
			match (yaw_step % BuildGrid.YAW_STEPS) / 2:
				0:   # exterior S + W
					root.add_child(_box("ArmS", Vector3(CELL, CELL, t), Vector3(0, h, -edge), bucket, COL_WALL))
					root.add_child(_box("ArmW", Vector3(t, CELL, CELL), Vector3(-edge, h, 0), bucket, COL_WALL))
				1:   # exterior S + E
					root.add_child(_box("ArmS", Vector3(CELL, CELL, t), Vector3(0, h, -edge), bucket, COL_WALL))
					root.add_child(_box("ArmE", Vector3(t, CELL, CELL), Vector3(edge, h, 0), bucket, COL_WALL))
				2:   # exterior N + E
					root.add_child(_box("ArmN", Vector3(CELL, CELL, t), Vector3(0, h, edge), bucket, COL_WALL))
					root.add_child(_box("ArmE", Vector3(t, CELL, CELL), Vector3(edge, h, 0), bucket, COL_WALL))
				_:   # exterior N + W
					root.add_child(_box("ArmN", Vector3(CELL, CELL, t), Vector3(0, h, edge), bucket, COL_WALL))
					root.add_child(_box("ArmW", Vector3(t, CELL, CELL), Vector3(-edge, h, 0), bucket, COL_WALL))
		"brubble":
			# M11 R5: the low, walkable, INDESTRUCTIBLE remnant a collapsed building leaves — a mound of
			# broken concrete filling the cell up to ~1 m (half height). Cover to crouch behind + a deck to
			# stand on (surface piece). Fixed layout (deterministic). Always full-tint (never damaged).
			root.add_child(_chunk(Vector3(1.6, 0.7, 1.5), Vector3(-0.25, 0.35, -0.2), 0.3, 0.05, COL_RUBBLE_B))
			root.add_child(_chunk(Vector3(1.4, 0.6, 1.6), Vector3(0.3, 0.30, 0.28), -0.4, 0.0, COL_RUBBLE_A))
			root.add_child(_chunk(Vector3(1.1, 0.9, 1.0), Vector3(0.08, 0.55, -0.35), 0.7, 0.06, COL_RUBBLE_C))
			root.add_child(_chunk(Vector3(0.9, 0.6, 1.1), Vector3(-0.35, 0.30, 0.36), 1.0, -0.05, COL_RUBBLE_B))
			root.add_child(_chunk(Vector3(0.8, 0.5, 0.8), Vector3(0.34, 0.5, -0.05), 0.5, 0.0, COL_RUBBLE_A))
		_:
			# bwall and any unknown id -> solid full wall.
			root.add_child(_box("Wall", Vector3(CELL, CELL, 0.3), Vector3(0, CELL * 0.5, 0), bucket, COL_WALL))
	if bucket <= 1:
		# Heavy damage -> a small pile of broken-concrete chunks at the BASE of the piece (rests on the
		# floor/ground). Several light, irregular, tilted blocks read as rubble, not a dark box.
		root.add_child(_chunk(Vector3(0.5, 0.30, 0.46), Vector3(-0.26, 0.13, 0.10), 0.4, 0.12, COL_RUBBLE_A))
		root.add_child(_chunk(Vector3(0.4, 0.24, 0.50), Vector3(0.28, 0.11, -0.16), -0.5, 0.0, COL_RUBBLE_B))
		root.add_child(_chunk(Vector3(0.34, 0.38, 0.30), Vector3(0.06, 0.18, 0.30), 0.9, -0.15, COL_RUBBLE_C))
		root.add_child(_chunk(Vector3(0.28, 0.22, 0.26), Vector3(-0.14, 0.11, -0.30), 1.2, 0.20, COL_RUBBLE_B))
		root.add_child(_chunk(Vector3(0.22, 0.18, 0.22), Vector3(0.20, 0.09, 0.24), 0.2, 0.0, COL_RUBBLE_A))
	return root

## A single tilted rubble chunk. Always full-tint (bucket 3) so debris stays light grey instead of
## being darkened by the damage tint (the old debris went near-black for that reason).
static func _chunk(size: Vector3, pos: Vector3, rot_y: float, tilt: float, base: Color) -> MeshInstance3D:
	var mi := _box("Rub", size, pos, 3, base, "concrete")
	mi.rotation = Vector3(tilt, rot_y, tilt * 0.4)
	return mi

static func build_rubble() -> Node3D:
	# Collapsed building (M11): a low mound of large broken slabs over the footprint, not a flat pad.
	var root := Node3D.new()
	root.add_child(_chunk(Vector3(1.7, 0.5, 1.5), Vector3(-0.5, 0.25, -0.3), 0.3, 0.06, COL_RUBBLE_B))
	root.add_child(_chunk(Vector3(1.5, 0.45, 1.6), Vector3(0.6, 0.22, 0.4), -0.4, 0.0, COL_RUBBLE_A))
	root.add_child(_chunk(Vector3(1.2, 0.6, 1.1), Vector3(0.2, 0.3, -0.6), 0.8, 0.10, COL_RUBBLE_C))
	root.add_child(_chunk(Vector3(1.0, 0.4, 1.3), Vector3(-0.6, 0.2, 0.6), 1.1, -0.08, COL_RUBBLE_B))
	root.add_child(_chunk(Vector3(0.8, 0.35, 0.8), Vector3(0.0, 0.18, 0.1), 0.5, 0.0, COL_RUBBLE_A))
	return root

static func _box(node_name: String, size: Vector3, pos: Vector3, bucket: int, base: Color, tex: String = "concrete") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	var f := ArtPalette.damage_tint(Color.WHITE, bucket).r
	mat.albedo_color = Color(base.r * f, base.g * f, base.b * f)
	mat.roughness = 0.9
	if tex != "":
		mat.albedo_texture = BuildingTextures.tex(tex)
		# WORLD-space triplanar (~1 tile/m): the texture maps by world position, so a wall and the per-chunk
		# hole geometry that replaces it (world_renderer promotion) sample the IDENTICAL texture and blend
		# seamlessly — no flat/lighter rectangle around a hole (playtest). Also hides UV seams on a box.
		mat.uv1_triplanar = true
		mat.uv1_world_triplanar = true
		mat.uv1_scale = Vector3.ONE * TEX_WORLD_SCALE
	mi.material_override = mat
	return mi

static func _glass(size: Vector3, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Glass"
	var mesh := BoxMesh.new(); mesh.size = size; mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.72, 0.82, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.1
	mat.metallic = 0.3
	mi.material_override = mat
	return mi

static func _cyl(radius: float, height: float, pos: Vector3, bucket: int, base: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Cyl"
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius; mesh.bottom_radius = radius; mesh.height = height; mesh.radial_segments = 10
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	var f := ArtPalette.damage_tint(Color.WHITE, bucket).r
	mat.albedo_color = Color(base.r * f, base.g * f, base.b * f)
	mat.albedo_texture = BuildingTextures.tex("metal")
	mat.roughness = 0.7
	mi.material_override = mat
	return mi
