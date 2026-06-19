extends Node
## Standalone whole-map screenshot tool — loads a maps/<name>.json, draws ground + roads +
## all buildings (via BuildingKit) + point/base markers into a fixed offscreen SubViewport, and
## saves a top-down and an iso PNG. Lets a gameplay map's layout be verified without a playtest.
## Needs a real renderer (GPU + display), NOT --headless. Render sequentially.
##
## Run: godot --path . client/art/preview/map_preview.tscn -- --map=<name> --shot=<prefix>
## Saves <prefix>_{top,iso}.png at 1920x1080.

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
	var mname := String(args.get("map", "conquest_town"))
	var prefix := String(args.get("shot", "/tmp/mapprev"))

	_vp = SubViewport.new()
	_vp.size = RES
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_setup_env()
	var half := _build_map(mname)
	_cam = Camera3D.new()
	_cam.fov = 55.0
	_vp.add_child(_cam)

	for view in ["top", "iso"]:
		_aim(half, view)
		for _i in 5:
			await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		if img != null:
			img.save_png("%s_%s.png" % [prefix, view])
	print("[mapprev] saved %s_{top,iso}.png map=%s half=%.0f" % [prefix, mname, half])
	get_tree().quit()

func _setup_env() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -50, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	_vp.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.66, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.66)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new(); we.environment = env
	_vp.add_child(we)

func _flat(size: Vector2, pos: Vector3, col: Color) -> void:
	var n := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = size
	n.mesh = pm
	var m := StandardMaterial3D.new(); m.albedo_color = col; m.roughness = 1.0
	n.material_override = m
	n.position = pos
	_vp.add_child(n)

func _build_map(name: String) -> float:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://maps/%s.json" % name))
	var half := float(data.get("world_half", 150.0))
	_flat(Vector2(half * 2.0, half * 2.0), Vector3(0, 0, 0), Color(0.30, 0.40, 0.24))  # ground
	for rd in data.get("roads", []):
		var mn = rd["min"]; var mx = rd["max"]
		var w := absf(float(mx[0]) - float(mn[0]))
		var l := absf(float(mx[2]) - float(mn[2]))
		_flat(Vector2(w, l), Vector3((float(mn[0]) + float(mx[0])) * 0.5, 0.04, (float(mn[2]) + float(mx[2])) * 0.5), Color(0.16, 0.16, 0.17))
	for b in data.get("buildings", []):
		var oc = b["origin_cell"]
		var fp = _footprint(String(b["prefab"]))
		var bdata = JSON.parse_string(FileAccess.get_file_as_string("res://buildings/%s.json" % b["prefab"]))
		for piece in bdata["pieces"]:
			var off = piece["offset"]
			var cell := Vector3i(int(oc[0]) + int(off[0]), int(off[1]), int(oc[2]) + int(off[2]))
			var node: Node3D = BuildingKit.build(String(piece["type"]), 3)
			node.position = Vector3((float(cell.x) + 0.5) * CELL, float(cell.y) * CELL, (float(cell.z) + 0.5) * CELL)
			node.rotation = Vector3(0.0, BuildGrid.yaw_radians(int(piece.get("yaw", 0))), 0.0)
			_vp.add_child(node)
	# point + base markers (tall beacons so they read from top-down)
	for p in data.get("points", []):
		var pp = p["pos"]
		_beacon(Vector3(float(pp[0]), 0, float(pp[2])), Color(0.95, 0.85, 0.25), 1.2)
	var bcol := [Color(0.30, 0.55, 0.95), Color(0.90, 0.40, 0.30)]
	for bs in data.get("bases", []):
		var bp = bs["pos"]
		_beacon(Vector3(float(bp[0]), 0, float(bp[2])), bcol[int(bs["team"]) % 2], 2.0)
	return half

func _beacon(pos: Vector3, col: Color, w: float) -> void:
	var n := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(w, 36.0, w)
	n.mesh = bm
	var m := StandardMaterial3D.new(); m.albedo_color = col
	m.emission_enabled = true; m.emission = col; m.emission_energy_multiplier = 0.6
	n.material_override = m
	n.position = pos + Vector3(0, 18, 0)
	_vp.add_child(n)

func _footprint(name: String) -> Vector2i:
	return Vector2i(1, 1)

func _aim(half: float, view: String) -> void:
	var center := Vector3(0, 0, 0)
	match view:
		"top":
			_cam.look_at_from_position(Vector3(0.1, half * 1.55, 0), center, Vector3(0, 0, -1))
		_:
			_cam.look_at_from_position(Vector3(half * 1.05, half * 0.95, half * 1.15), center, Vector3.UP)
