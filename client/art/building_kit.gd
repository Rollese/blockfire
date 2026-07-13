class_name BuildingKit
extends Object
## Procedural low-poly geometry for M11 building pieces. Presentation-only, no team-tint. Keyed by
## piece id + damage bucket (3 pristine .. 0 heavy), mirroring StructureKit's damage read.

const CELL := 2.4  # BuildGrid.CELL_SIZE
const TEX_WORLD_SCALE := 1.0   # texture tiles per metre (world-triplanar) — shared by walls + hole chunks
# Roof-floor / deck slabs are full-cell wide, and a `bwall*` directly below (pushed to the footprint
# edge by world_renderer `out_amt = CELL*0.5 - 0.15 = 1.05`, 0.3 m thick) has its EXTERIOR face at
# exactly cell_centre ± 1.20 = the cell boundary. A full-CELL slab's outer edge lands on that same
# boundary -> two coplanar vertical faces z-fight in a dithered band under the roof soffit (round-1).
# Round-1 fixed that by INSETTING the slab (edge to ±1.19, buried 0.01 m inside the wall), but that also
# pulled every slab 0.01 m off the shared cell boundary, opening a 0.02 m gap on every interior deck-to-
# deck seam (round-2 owner playtest). The wall exterior sits EXACTLY where neighbours meet, so no
# symmetric footprint is both gap-free AND coplanar-free — we must pick which side of the boundary to
# break on. OVERSIZE (edge to ±1.21) is the round-2 fix: adjacent decks now OVERLAP by 0.02 m total
# (coplanar tops -> the overlap is invisible from above, NO gap), and the edge is 0.01 m PAST the wall
# exterior plane rather than on it, so the coplanar z-fight is gone (the two faces are now 0.01 m apart
# instead of coincident). Residual cost: a 0.01 m poke past the exterior on perimeter/roof
# edges — half the owner-flagged gap, hidden under the roof coping's 0.06 m eave on capped walls, and
# sub-visible (equal to round-1's accepted inset) on open edges. MESH-ONLY: collision is server-side
# (structure.gd floor_height_at, cell-base plane) and never reads this.
const ROOF_FLOOR_OVERLAP := 0.02

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

static func build(piece_id: String, bucket: int, floor_skirt: bool = false, yaw_step: int = 0, roof_cap: bool = false) -> Node3D:
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
		root.add_child(_box("Skirt", Vector3(CELL + ROOF_FLOOR_OVERLAP, 0.32, CELL + ROOF_FLOOR_OVERLAP), Vector3(0, -0.12, 0), 3, skirt_col, skirt_tex))
	match piece_id:
		"bcolumn":
			root.add_child(_box("Col", Vector3(0.5, CELL, 0.5), Vector3(0, CELL * 0.5, 0), bucket, COL_STRUCT))
		"bfloor":
			# Walkable surface = cell base plane (M14). Hang the slab just below it so the pawn's feet
			# rest on the visible top.
			# Slab top sits a hair ABOVE the cell base so a roof slab swallows the wall top below it
			# (was coplanar -> z-fight "walls clipping the roof"). Walkable surface stays ~cell base.
			# Footprint is OVERSIZED by ROOF_FLOOR_OVERLAP so adjacent decks overlap (no inter-slab gap)
			# and the outer edge sits just PAST the wall exterior plane instead of on it (no coplanar
			# z-fight band). Collision unchanged (server-side).
			root.add_child(_box("Floor", Vector3(CELL + ROOF_FLOOR_OVERLAP, 0.32, CELL + ROOF_FLOOR_OVERLAP), Vector3(0, -0.12, 0), bucket, COL_FLOOR, "wood"))
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
			# Kenney-style framed window: a large opening left by solid sill/header/side fills (these form
			# the CELL-wide, full-cell-height carvable slab -> chunk-hole promotion stays seamless), a
			# RECESSED glazing pane + mullions read as a real window, and a proud trim frame + sill ledge
			# give the face depth. Trim/glazing are shallow relief -> they harmlessly drop when the slab carves.
			var sill_top := 0.9   # windowsill height
			var op_h := 1.05      # opening height (sill_top .. sill_top+op_h)
			var op_cy := sill_top + op_h * 0.5   # opening centre Y
			var head_bot := sill_top + op_h      # header fill bottom
			var op_hw := 0.55     # opening half-width
			root.add_child(_box("Sill", Vector3(CELL, sill_top, 0.3), Vector3(0, sill_top * 0.5, 0), bucket, COL_WALL))
			root.add_child(_box("Header", Vector3(CELL, CELL - head_bot, 0.3), Vector3(0, head_bot + (CELL - head_bot) * 0.5, 0), bucket, COL_WALL))
			root.add_child(_box("WSideL", Vector3(CELL * 0.5 - op_hw, op_h, 0.3), Vector3(-(op_hw + (CELL * 0.5 - op_hw) * 0.5), op_cy, 0), bucket, COL_WALL))
			root.add_child(_box("WSideR", Vector3(CELL * 0.5 - op_hw, op_h, 0.3), Vector3(op_hw + (CELL * 0.5 - op_hw) * 0.5, op_cy, 0), bucket, COL_WALL))
			# DEEP recessed glazing (set well back for a real reveal) + a mullion cross on the pane.
			root.add_child(_box("Glaze", Vector3(op_hw * 2.0, op_h, 0.05), Vector3(0, op_cy, -0.11), 3, Color(0.22, 0.27, 0.32), ""))
			root.add_child(_box("MullV", Vector3(0.05, op_h, 0.06), Vector3(0, op_cy, -0.05), bucket, COL_TRIM, ""))
			root.add_child(_box("MullH", Vector3(op_hw * 2.0, 0.05, 0.06), Vector3(0, op_cy, -0.05), bucket, COL_TRIM, ""))
			# Proud architrave frame (face at z=+0.15) — jambs + head, a projecting stone SILL, and a
			# KEYSTONE centred on the head for the Kenney look.
			root.add_child(_box("TrimT", Vector3(op_hw * 2.0 + 0.16, 0.10, 0.12), Vector3(0, op_cy + op_h * 0.5 + 0.01, 0.17), bucket, COL_TRIM, ""))
			root.add_child(_box("TrimL", Vector3(0.10, op_h + 0.20, 0.12), Vector3(-op_hw - 0.06, op_cy, 0.17), bucket, COL_TRIM, ""))
			root.add_child(_box("TrimR", Vector3(0.10, op_h + 0.20, 0.12), Vector3(op_hw + 0.06, op_cy, 0.17), bucket, COL_TRIM, ""))
			root.add_child(_box("Keystone", Vector3(0.18, 0.22, 0.16), Vector3(0, op_cy + op_h * 0.5 + 0.05, 0.19), bucket, COL_TRIM, ""))
			root.add_child(_box("SillLedge", Vector3(op_hw * 2.0 + 0.34, 0.12, 0.22), Vector3(0, op_cy - op_h * 0.5 - 0.02, 0.12), bucket, COL_TRIM, ""))
		"bwall_door":
			# Framed doorway self-contained in ONE 2.4 m cell (no "the cell above is the header" hack):
			# full-height side fills + a solid header fill above a fixed ~2.1 m opening form the CELL-wide
			# carvable slab; a RECESSED panelled leaf + a proud trim surround give depth. Trim/leaf are
			# shallow relief -> they harmlessly drop when the slab carves.
			var d_hw := 0.5                      # door opening half-width (1.0 m leaf)
			var op_h := 2.1                      # opening height — clears a standing pawn
			var side_w := CELL * 0.5 - d_hw      # solid fill each side of the opening
			var head_h := CELL - op_h            # solid header fill above the opening (~0.3 m)
			root.add_child(_box("DSideL", Vector3(side_w, CELL, 0.3), Vector3(-(d_hw + side_w * 0.5), CELL * 0.5, 0), bucket, COL_WALL))
			root.add_child(_box("DSideR", Vector3(side_w, CELL, 0.3), Vector3(d_hw + side_w * 0.5, CELL * 0.5, 0), bucket, COL_WALL))
			root.add_child(_box("DHeader", Vector3(d_hw * 2.0, head_h, 0.3), Vector3(0, op_h + head_h * 0.5, 0), bucket, COL_WALL))
			# Recessed door leaf (dark wood) + two proud panel strips so it reads as a real door.
			root.add_child(_box("DoorLeaf", Vector3(d_hw * 2.0 - 0.08, op_h - 0.06, 0.06), Vector3(0, (op_h - 0.06) * 0.5, -0.05), 3, Color(0.32, 0.22, 0.14), ""))
			root.add_child(_box("DPanelL", Vector3(0.06, op_h - 0.4, 0.03), Vector3(-0.22, op_h * 0.5, -0.01), 3, Color(0.26, 0.18, 0.11), ""))
			root.add_child(_box("DPanelR", Vector3(0.06, op_h - 0.4, 0.03), Vector3(0.22, op_h * 0.5, -0.01), 3, Color(0.26, 0.18, 0.11), ""))
			# Proud architrave (jambs + lintel) at the face, a KEYSTONE on the lintel, and a projecting
			# threshold step at the base — the Kenney doorway look.
			root.add_child(_box("DJambL", Vector3(0.11, op_h, 0.13), Vector3(-d_hw - 0.055, op_h * 0.5, 0.17), bucket, COL_TRIM, ""))
			root.add_child(_box("DJambR", Vector3(0.11, op_h, 0.13), Vector3(d_hw + 0.055, op_h * 0.5, 0.17), bucket, COL_TRIM, ""))
			root.add_child(_box("DLintel", Vector3(d_hw * 2.0 + 0.24, 0.13, 0.13), Vector3(0, op_h + 0.065, 0.17), bucket, COL_TRIM, ""))
			root.add_child(_box("DKeystone", Vector3(0.20, 0.24, 0.17), Vector3(0, op_h + 0.10, 0.19), bucket, COL_TRIM, ""))
			root.add_child(_box("DThreshold", Vector3(d_hw * 2.0 + 0.30, 0.10, 0.24), Vector3(0, 0.05, 0.10), bucket, COL_TRIM, ""))
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
			# Quoins up the outer vertical edge (the two-arm join). Outer-corner sign per orientation.
			var q := (yaw_step % BuildGrid.YAW_STEPS) / 2
			var csx := -1.0 if (q == 0 or q == 3) else 1.0
			var csz := -1.0 if (q == 0 or q == 1) else 1.0
			_corner_quoins(root, bucket, csx, csz)
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
	# Kenney flat-roof cap on a top-course wall: a low parapet rising above the roofline + a proud trim
	# coping (the coping's overhang reads as a small eave). A straight wall caps along its length; a corner
	# caps BOTH exterior arms so the parapet is a continuous ring (no gap at the corners). Shallow relief
	# riding the slab -> it drops harmlessly when a straight wall carves into hole chunks (constraint).
	if roof_cap and piece_id.begins_with("bwall"):
		if piece_id == "bwall_corner":
			var e := CELL * 0.5 - 0.15   # exterior edge offset (matches the corner arms)
			match (yaw_step % BuildGrid.YAW_STEPS) / 2:
				0:   _roof_parapet_x(root, bucket, -e); _roof_parapet_z(root, bucket, -e)   # S + W
				1:   _roof_parapet_x(root, bucket, -e); _roof_parapet_z(root, bucket, e)    # S + E
				2:   _roof_parapet_x(root, bucket, e);  _roof_parapet_z(root, bucket, e)    # N + E
				_:   _roof_parapet_x(root, bucket, e);  _roof_parapet_z(root, bucket, -e)   # N + W
		else:
			# Straight wall: parapet on the cell centre-line; _structure_xform shifts it out to the edge.
			_roof_parapet_x(root, bucket, 0.0)
	if bucket <= 1:
		# Heavy damage -> a small pile of broken-concrete chunks at the BASE of the piece (rests on the
		# floor/ground). Several light, irregular, tilted blocks read as rubble, not a dark box.
		root.add_child(_chunk(Vector3(0.5, 0.30, 0.46), Vector3(-0.26, 0.13, 0.10), 0.4, 0.12, COL_RUBBLE_A))
		root.add_child(_chunk(Vector3(0.4, 0.24, 0.50), Vector3(0.28, 0.11, -0.16), -0.5, 0.0, COL_RUBBLE_B))
		root.add_child(_chunk(Vector3(0.34, 0.38, 0.30), Vector3(0.06, 0.18, 0.30), 0.9, -0.15, COL_RUBBLE_C))
		root.add_child(_chunk(Vector3(0.28, 0.22, 0.26), Vector3(-0.14, 0.11, -0.30), 1.2, 0.20, COL_RUBBLE_B))
		root.add_child(_chunk(Vector3(0.22, 0.18, 0.22), Vector3(0.20, 0.09, 0.24), 0.2, 0.0, COL_RUBBLE_A))
	return root

## One roof-cap parapet+coping segment running along X (thin in Z) at z=`zoff`. The coping's overhang
## (wider than the parapet) reads as a small eave. Parapet takes the damage tint; coping stays full.
static func _roof_parapet_x(root: Node3D, bucket: int, zoff: float) -> void:
	root.add_child(_box("Parapet", Vector3(CELL, 0.5, 0.30), Vector3(0, CELL + 0.25, zoff), bucket, COL_WALL))
	root.add_child(_box("Coping", Vector3(CELL, 0.08, 0.42), Vector3(0, CELL + 0.54, zoff), 3, COL_TRIM, ""))

## One roof-cap parapet+coping segment running along Z (thin in X) at x=`xoff`.
static func _roof_parapet_z(root: Node3D, bucket: int, xoff: float) -> void:
	root.add_child(_box("Parapet", Vector3(0.30, 0.5, CELL), Vector3(xoff, CELL + 0.25, 0), bucket, COL_WALL))
	root.add_child(_box("Coping", Vector3(0.42, 0.08, CELL), Vector3(xoff, CELL + 0.54, 0), 3, COL_TRIM, ""))

## Alternating proud blocks up the outer vertical edge of a corner -> quoined stonework. Same wall tone;
## the proud offset (beyond the two faces) casts the reading shadow line. csx/csz = outer-corner sign.
static func _corner_quoins(root: Node3D, bucket: int, csx: float, csz: float) -> void:
	var n := 5
	for i in n:
		var qw := 0.44 if i % 2 == 0 else 0.30
		var qh := CELL / float(n) - 0.07
		var cy := (float(i) + 0.5) * CELL / float(n)
		var px := csx * (CELL * 0.5 - qw * 0.5 + 0.05)
		var pz := csz * (CELL * 0.5 - qw * 0.5 + 0.05)
		root.add_child(_box("Quoin%d" % i, Vector3(qw, qh, qw), Vector3(px, cy, pz), bucket, COL_WALL))

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
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST   # game-wide pixel look
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
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST   # game-wide pixel look
	mat.roughness = 0.7
	mi.material_override = mat
	return mi
