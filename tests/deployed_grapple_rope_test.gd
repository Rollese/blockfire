extends TestCase
## G1: a deployed grapple (DEPLOYED_LADDER_LIST is exclusively grapple-origin) must render as a
## client-only verlet GrappleRope ONLY — never the red ladder mesh. Regression guard: the marker
## used to build BOTH a _make_ladder mesh AND a rope, so a grapple showed a bogus ladder.


func test_deployed_grapple_hosts_a_rope_and_no_ladder_mesh() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.set_deployed_ladders([
		{"id": 1, "x": 5.0, "z": 7.0, "bottom_y": 2.0, "top_y": 12.0},
	])
	var node: Node3D = wr._deployed_ladder_nodes.get(1)
	assert_true(node != null, "a marker node is tracked for the deployed grapple id")
	var ropes := 0
	var ladder_meshes := 0   # _make_ladder / merge_by_material leave MeshInstance3D rails directly on the node
	var rope: GrappleRope = null
	for c in node.get_children():
		if c is GrappleRope:
			ropes += 1
			rope = c
		elif c is MeshInstance3D:
			ladder_meshes += 1
	assert_eq(ropes, 1, "deployed grapple hosts exactly one verlet rope")
	assert_eq(ladder_meshes, 0, "deployed grapple has NO ladder mesh child")
	# The rope's anchor endpoints must be unchanged from the pre-fix straight climb line.
	assert_eq(rope._top, Vector3(5.0, 12.0, 7.0), "rope pinned at the top anchor (x, top_y, z)")
	assert_eq(rope._bottom, Vector3(5.0, 2.0, 7.0), "rope hangs to the bottom anchor (x, bottom_y, z)")


func test_deployed_grapple_marker_self_heals_when_cut() -> void:
	# Sanity: id bookkeeping still frees a marker whose rope leaves the authoritative list.
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.set_deployed_ladders([{"id": 9, "x": 0.0, "z": 0.0, "bottom_y": 1.0, "top_y": 6.0}])
	assert_true(wr._deployed_ladder_nodes.has(9), "marker acquired")
	wr.set_deployed_ladders([])
	assert_false(wr._deployed_ladder_nodes.has(9), "marker freed when the rope leaves the list")
