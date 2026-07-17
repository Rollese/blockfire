extends TestCase
const EditorPreview := preload("res://addons/map_editor/preview/editor_preview.gd")
const MapDocument := preload("res://shared/mapedit/map_document.gd")

func _doc() -> MapDocument:
	var d := MapDocument.from_dict({
		"name": "Prev", "world_half": 30.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 8.0}],
		"bases": [{"team": 0, "pos": [0, 0, -25]}, {"team": 1, "pos": [0, 0, 25]}],
		"buildings": [{"prefab": "cottage", "origin_cell": [0, 0, 0], "yaw": 0}],
		"scenery": [{"id": "tree_type3_02", "pos": [10, 0, 10], "yaw": 0.0, "scale": 1.0}],
	}, "")
	return d

func _mesh_count(n: Node) -> int:
	var c := 0
	if n is MeshInstance3D:
		c += 1
	for ch in n.get_children():
		c += _mesh_count(ch)
	return c

func test_rebuild_produces_real_meshes_for_buildings() -> void:
	var p := EditorPreview.new()
	autofree(p)
	p.rebuild(_doc())
	assert_gt(_mesh_count(p), 0, "preview built real MeshInstance3D geometry, not proxies")

func test_rebuild_is_idempotent() -> void:
	var p := EditorPreview.new()
	autofree(p)
	var d := _doc()
	p.rebuild(d)
	var first := _mesh_count(p)
	p.rebuild(d)
	assert_eq(_mesh_count(p), first, "rebuilding the same doc does not duplicate geometry")

func test_rebuild_clears_removed_content() -> void:
	var p := EditorPreview.new()
	autofree(p)
	var d := _doc()
	p.rebuild(d)
	assert_gt(_mesh_count(p), 0, "geometry present")
	d.buildings.clear()
	d.scenery.clear()
	p.rebuild(d)
	assert_eq(_mesh_count(p), 0, "clearing the doc clears the preview")

func test_unknown_prefab_does_not_crash() -> void:
	tolerate_runtime_errors()
	var p := EditorPreview.new()
	autofree(p)
	var d := _doc()
	d.buildings = [{"prefab": "no_such_prefab", "origin_cell": Vector3i(0, 0, 0), "yaw": 0}]
	p.rebuild(d)
	assert_true(true, "an unknown prefab is skipped, not fatal (the owner may be mid-typing)")

func test_empty_doc_is_safe() -> void:
	var p := EditorPreview.new()
	autofree(p)
	p.rebuild(null)
	assert_eq(_mesh_count(p), 0, "null doc -> nothing, no crash")
