class_name BuildingKit
extends Object
## Procedural low-poly geometry for M11 building pieces. Presentation-only, no team-tint. Keyed by
## piece id + damage bucket (3 pristine .. 0 heavy), mirroring StructureKit's damage read.

const CELL := 2.0  # BuildGrid.CELL_SIZE

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

static func build(piece_id: String, bucket: int) -> Node3D:
	var root := Node3D.new()
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
			# A ~1m square window set high on the wall: solid sill + header + side fills leave a square
			# opening, with a thin trim frame around it.
			root.add_child(_box("Sill", Vector3(CELL, CELL * 0.42, 0.3), Vector3(0, CELL * 0.21, 0), bucket, COL_WALL))
			root.add_child(_box("Header", Vector3(CELL, CELL * 0.14, 0.3), Vector3(0, CELL * 0.93, 0), bucket, COL_WALL))
			root.add_child(_box("WSideL", Vector3(CELL * 0.26, CELL * 0.52, 0.3), Vector3(-CELL * 0.37, CELL * 0.66, 0), bucket, COL_WALL))
			root.add_child(_box("WSideR", Vector3(CELL * 0.26, CELL * 0.52, 0.3), Vector3(CELL * 0.37, CELL * 0.66, 0), bucket, COL_WALL))
			root.add_child(_box("WTrimB", Vector3(CELL * 0.55, 0.08, 0.34), Vector3(0, CELL * 0.43, 0), bucket, COL_TRIM))
			root.add_child(_box("WTrimT", Vector3(CELL * 0.55, 0.08, 0.34), Vector3(0, CELL * 0.89, 0), bucket, COL_TRIM))
		"bwall_door":
			# Tall doorway: jambs + lintel reach ~2.3m (into the cell above) so a standing pawn clearly
			# clears it; the wall in the cell above is the header.
			root.add_child(_box("JambL", Vector3(CELL * 0.22, CELL * 1.15, 0.35), Vector3(-CELL * 0.39, CELL * 0.575, 0), bucket, COL_TRIM))
			root.add_child(_box("JambR", Vector3(CELL * 0.22, CELL * 1.15, 0.35), Vector3(CELL * 0.39, CELL * 0.575, 0), bucket, COL_TRIM))
			root.add_child(_box("Lintel", Vector3(CELL, CELL * 0.14, 0.35), Vector3(0, CELL * 1.12, 0), bucket, COL_TRIM))
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
		# Tile ~1 tile/m across the piece's dominant face (two largest dimensions).
		var d := [absf(size.x), absf(size.y), absf(size.z)]
		d.sort()
		mat.uv1_scale = Vector3(maxf(d[2], 0.5), maxf(d[1], 0.5), 1.0)
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
