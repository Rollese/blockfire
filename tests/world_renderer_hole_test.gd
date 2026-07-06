extends TestCase
## M11 Gate-B hole-aware geometry: WorldRenderer.chunk_hole_xforms subdivides a piece face into a
## grid*grid array of sub-cell boxes, emitting one transform per ALIVE chunk and OMITTING cleared
## chunks (a real see-through hole). Must mirror ChunkMask's bit layout so a rendered hole lands
## exactly where the sim carved. Pure math -> deterministic.

const GRID := 8
const HEIGHT := 2.0        # full piece = CELL_SIZE
const THICK := 0.3

func test_full_mask_fills_every_chunk() -> void:
	var full := ChunkMask.full_mask(GRID)
	var xf := WorldRenderer.chunk_hole_xforms(full, GRID, HEIGHT, THICK)
	assert_eq(xf.size(), GRID * GRID, "a pristine face renders all grid*grid chunk boxes")

func test_empty_mask_renders_nothing() -> void:
	assert_eq(WorldRenderer.chunk_hole_xforms(0, GRID, HEIGHT, THICK).size(), 0, "no alive chunks -> no boxes")

func test_count_matches_popcount() -> void:
	var mask := ChunkMask.full_mask(GRID) & ~0x00000000FFFFFFFF   # clear the low 32 chunks
	var xf := WorldRenderer.chunk_hole_xforms(mask, GRID, HEIGHT, THICK)
	assert_eq(xf.size(), ChunkMask.popcount(mask), "one box per alive chunk (hole where cleared)")
	assert_eq(xf.size(), 32, "clearing 32 of 64 chunks leaves 32 boxes")

func test_cleared_corner_leaves_a_hole_there() -> void:
	# Clear bit 0 (row0,col0 = min-U/min-V corner). No box should sit at that chunk centre.
	var mask := ChunkMask.full_mask(GRID) & ~1
	var xf := WorldRenderer.chunk_hole_xforms(mask, GRID, HEIGHT, THICK)
	assert_eq(xf.size(), GRID * GRID - 1, "exactly one chunk missing")
	var ustep := BuildGrid.CELL_SIZE / float(GRID)
	var vstep := HEIGHT / float(GRID)
	var hole := Vector3(-BuildGrid.CELL_SIZE * 0.5 + 0.5 * ustep, 0.5 * vstep, 0.0)
	for t: Transform3D in xf:
		assert_true(t.origin.distance_to(hole) > 0.01, "no box at the cleared corner chunk")

func test_boxes_are_scaled_to_chunk_size_and_within_the_face() -> void:
	var xf := WorldRenderer.chunk_hole_xforms(ChunkMask.full_mask(GRID), GRID, HEIGHT, THICK)
	var ustep := BuildGrid.CELL_SIZE / float(GRID)
	var vstep := HEIGHT / float(GRID)
	for t: Transform3D in xf:
		var s := t.basis.get_scale()
		assert_almost_eq(s.x, ustep, 0.001, "chunk box width = CELL/grid")
		assert_almost_eq(s.y, vstep, 0.001, "chunk box height = face_height/grid")
		assert_almost_eq(s.z, THICK, 0.001, "chunk box depth = wall thickness")
		# Centre stays inside the cell face: x in [-CELL/2, CELL/2], y in [0, height].
		assert_true(absf(t.origin.x) <= BuildGrid.CELL_SIZE * 0.5 + 0.001, "box within face width")
		assert_true(t.origin.y >= -0.001 and t.origin.y <= HEIGHT + 0.001, "box within face height")

func test_half_piece_height_packs_into_lower_half() -> void:
	# A half wall (height = CELL*0.5) must keep all chunks below CELL*0.5, not float at full height.
	var half_h := BuildGrid.CELL_SIZE * 0.5
	var xf := WorldRenderer.chunk_hole_xforms(ChunkMask.full_mask(GRID), GRID, half_h, THICK)
	for t: Transform3D in xf:
		assert_true(t.origin.y <= half_h + 0.001, "half-piece chunks stay within the half height")
