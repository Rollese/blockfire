extends Node
## Standalone building screenshot tool — renders a building prefab from several angles into a
## fixed-size offscreen SubViewport (so capture resolution is independent of the OS window) and saves
## PNGs. Lets the building LOOK be iterated without a playtest. Needs a real renderer (GPU + display,
## or xvfb), NOT --headless. Render buildings sequentially (parallel godot fights over the GPU).
##
## Run: godot --path . client/art/preview/building_preview.tscn -- --building=<name> --shot=<prefix>
## Saves <prefix>_{iso,front,side,eye}.png at 1920x1080.

const CELL := 2.0
const RES := Vector2i(1920, 1080)
var _vp: SubViewport
var _cam: Camera3D

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=")
			args[String(kv[0])] = String(kv[1]) if kv.size() > 1 else "true"
	var bname := String(args.get("building", "house"))
	var prefix := String(args.get("shot", "/tmp/prev"))

	_vp = SubViewport.new()
	_vp.size = RES
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	add_child(_vp)
	_setup_env()
	var bb := _build_building(bname)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	_vp.add_child(_cam)

	for view in ["iso", "front", "side", "eye"]:
		_aim(bb, view)
		for _i in 4:
			await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		if img != null:
			img.save_png("%s_%s.png" % [prefix, view])
	print("[preview] saved %s_{iso,front,side,eye}.png building=%s @ %dx%d" % [prefix, bname, RES.x, RES.y])
	get_tree().quit()

func _setup_env() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(200, 200)
	ground.mesh = pm
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.32, 0.40, 0.26); gm.roughness = 1.0
	ground.material_override = gm
	_vp.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -55, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	_vp.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.66, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new(); we.environment = env
	_vp.add_child(we)

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
		_vp.add_child(node)
		lo = Vector3(minf(lo.x, wpos.x - CELL), minf(lo.y, wpos.y), minf(lo.z, wpos.z - CELL))
		hi = Vector3(maxf(hi.x, wpos.x + CELL), maxf(hi.y, wpos.y + CELL), maxf(hi.z, wpos.z + CELL))
	return AABB(lo, hi - lo)

func _aim(bb: AABB, view: String) -> void:
	var center := bb.position + bb.size * 0.5
	var r := maxf(bb.size.length(), 8.0)
	var pos: Vector3
	match view:
		"front":
			pos = center + Vector3(0, bb.size.y * 0.6, r * 1.05)
		"side":
			pos = center + Vector3(r * 1.05, bb.size.y * 0.6, 0)
		"eye":
			pos = bb.position + Vector3(bb.size.x * 0.5, 1.6, -r * 0.55)
		_:
			pos = center + Vector3(r * 0.95, r * 0.85, r * 0.95)
	_cam.look_at_from_position(pos, center if view != "eye" else center - Vector3(0, bb.size.y * 0.2, 0), Vector3.UP)
