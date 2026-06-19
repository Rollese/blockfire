extends Node3D
## Standalone building screenshot tool — renders a building prefab in isolation and saves a PNG, so
## the look can be iterated without a full playtest. Needs a real renderer (a GPU + display, or
## xvfb-run on a headless box) — NOT --headless (DummyRenderer can't capture).
##
## Run: godot --path . client/art/preview/building_preview.tscn -- --building=<name> --shot=<path> [--view=iso|front|top]

const CELL := 2.0

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=")
			args[String(kv[0])] = String(kv[1]) if kv.size() > 1 else "true"
	var bname := String(args.get("building", "house"))
	var shot := String(args.get("shot", "/tmp/building.png"))
	var view := String(args.get("view", "iso"))
	DisplayServer.window_set_size(Vector2i(1280, 800))
	_setup_env()
	var bb := _build_building(bname)
	_place_camera(bb, view)
	# Let the renderer produce a couple of full frames before grabbing the image.
	for _i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(shot)
		print("[preview] saved %s (%dx%d) building=%s view=%s" % [shot, img.get_width(), img.get_height(), bname, view])
	else:
		push_error("[preview] no image captured (renderer?)")
	get_tree().quit()

func _setup_env() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(120, 120)
	ground.mesh = pm
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.32, 0.40, 0.26); gm.roughness = 1.0
	ground.material_override = gm
	add_child(ground)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -55, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.66, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new(); we.environment = env
	add_child(we)

## Build every piece at its grid cell + yaw (mirrors WorldRenderer). Returns the world-space AABB.
func _build_building(name: String) -> AABB:
	var text := FileAccess.get_file_as_string("res://buildings/%s.json" % name)
	var data = JSON.parse_string(text)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for piece in data["pieces"]:
		var off = piece["offset"]
		var cell := Vector3i(int(off[0]), int(off[1]), int(off[2]))
		var node: Node3D = BuildingKit.build(String(piece["type"]), 3)
		var wpos := Vector3((float(cell.x) + 0.5) * CELL, float(cell.y) * CELL, (float(cell.z) + 0.5) * CELL)
		node.position = wpos
		node.rotation = Vector3(0.0, BuildGrid.yaw_radians(int(piece.get("yaw", 0))), 0.0)
		add_child(node)
		lo = Vector3(minf(lo.x, wpos.x - CELL), minf(lo.y, wpos.y), minf(lo.z, wpos.z - CELL))
		hi = Vector3(maxf(hi.x, wpos.x + CELL), maxf(hi.y, wpos.y + CELL), maxf(hi.z, wpos.z + CELL))
	return AABB(lo, hi - lo)

func _place_camera(bb: AABB, view: String) -> void:
	var cam := Camera3D.new()
	var center := bb.position + bb.size * 0.5
	var r := maxf(bb.size.length(), 8.0)
	var pos: Vector3
	match view:
		"front":
			pos = center + Vector3(0, bb.size.y * 0.5, r * 1.1)
		"top":
			pos = center + Vector3(0.1, r * 1.4, 0.1)
		_:  # iso 3/4
			pos = center + Vector3(r * 0.95, r * 0.85, r * 0.95)
	cam.fov = 50.0
	cam.current = true
	add_child(cam)   # must be in the tree before look_at()
	cam.look_at_from_position(pos, center, Vector3.UP)
