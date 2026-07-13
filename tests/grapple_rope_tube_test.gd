extends TestCase
## G1 round-2: the deployed grapple rope must render as a visible THICK TUBE, not a 1px GPU line.
## These exercise the PURE tube-geometry helpers on GrappleRope (no SceneTree / camera needed):
## a low-poly extruded tube around the verlet polyline, with per-vertex outward unit normals so it
## shades under the scene lighting. Proving "not a line" = far more than 2 verts per ring.

const RADIUS := 0.045
const SIDES := 6


func test_tube_emits_triangle_soup_not_a_line() -> void:
	# 3 polyline points -> (N-1) segments, each stitched from `sides` quads (2 tris = 6 verts).
	var pts := PackedVector3Array([Vector3(0, 3, 0), Vector3(0, 2, 0), Vector3(0, 1, 0)])
	var geo: Dictionary = GrappleRope._tube_geometry(pts, RADIUS, SIDES)
	var verts: PackedVector3Array = geo["verts"]
	assert_eq(verts.size(), (pts.size() - 1) * SIDES * 6, "tube = (N-1)*sides*6 triangle verts")
	# A LINE_STRIP over N points would be N verts. A tube emits vastly more (>2 per ring), proving
	# it is real 3D geometry, not a 1px line.
	assert_gt(verts.size(), pts.size() * 2, "far more verts than any line — it's a tube")


func test_tube_degenerate_inputs_are_empty() -> void:
	assert_eq((GrappleRope._tube_geometry(PackedVector3Array([Vector3.ZERO]), RADIUS, SIDES)["verts"] as PackedVector3Array).size(), 0, "single point -> no tube")
	var two := PackedVector3Array([Vector3(0, 1, 0), Vector3(0, 0, 0)])
	assert_eq((GrappleRope._tube_geometry(two, RADIUS, 2)["verts"] as PackedVector3Array).size(), 0, "sides<3 -> no tube")


func test_ring_vertices_sit_at_radius_perpendicular_to_segment() -> void:
	var f: Array = GrappleRope._frame(Vector3.DOWN)
	var u: Vector3 = f[0]
	var v: Vector3 = f[1]
	var center := Vector3(1, 5, 2)
	var ring: PackedVector3Array = GrappleRope._ring_points(center, u, v, RADIUS, SIDES)
	assert_eq(ring.size(), SIDES, "one vertex per side")
	for p in ring:
		assert_almost_eq((p - center).length(), RADIUS, 0.0005, "vertex lies at the tube radius")
		# The rope hangs vertically here (DOWN), so the ring plane is horizontal: constant y.
		assert_almost_eq(p.y, center.y, 0.0005, "ring is perpendicular to the segment direction")


func test_normals_are_unit_length_and_point_outward() -> void:
	# A straight vertical tube centred on the y-axis: every outward normal must be radial (no
	# vertical component) and aligned with the vertex's own offset from the axis.
	var pts := PackedVector3Array([Vector3(0, 3, 0), Vector3(0, 0, 0)])
	var geo: Dictionary = GrappleRope._tube_geometry(pts, RADIUS, SIDES)
	var verts: PackedVector3Array = geo["verts"]
	var normals: PackedVector3Array = geo["normals"]
	assert_gt(verts.size(), 0, "non-empty tube")
	assert_eq(verts.size(), normals.size(), "one normal per vertex")
	for nrm in normals:
		assert_almost_eq((nrm as Vector3).length(), 1.0, 0.001, "unit-length normal")
	for i in range(verts.size()):
		var p: Vector3 = verts[i]
		var radial := Vector3(p.x, 0.0, p.z).normalized()
		assert_gt((normals[i] as Vector3).dot(radial), 0.9, "normal points radially outward from the axis")
