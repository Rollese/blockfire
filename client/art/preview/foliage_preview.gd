extends Node
## Standalone tree/rock screenshot tool (PROTOTYPE). Renders self-generated TreeKit + RockKit foliage
## into a fixed-size offscreen SubViewport and saves PNGs, so the aesthetic can be judged on a real GPU
## without a playtest. Needs a real renderer (GPU + display, or xvfb), NOT --headless; render sequentially.
##
## Run: godot --path . client/art/preview/foliage_preview.tscn -- --shot=<prefix>
## Saves <prefix>_{hero,trees,rock,iso,filter}.png at 1920x1080.
##  - hero:   sunset-lit 3/4 view of the whole set with a 1.8 m scale capsule (echoes the BattleBit shots)
##  - filter: the SAME leaf card at NEAREST (left) vs LINEAR (right) — the pixelated-vs-blurred comparison

const RES := Vector2i(1920, 1080)
var _vp: SubViewport
var _cam: Camera3D

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=")
			args[String(kv[0])] = String(kv[1]) if kv.size() > 1 else "true"
	var prefix := String(args.get("shot", "/tmp/foliage"))

	_vp = SubViewport.new()
	_vp.size = RES
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	add_child(_vp)
	_setup_env()
	_populate()

	_cam = Camera3D.new()
	_cam.fov = 55.0
	_vp.add_child(_cam)

	var views := ["hero", "trees", "rock", "iso", "filter"]
	for view in views:
		_aim(view)
		for _i in 6:
			await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		if img != null:
			img.save_png("%s_%s.png" % [prefix, view])
	print("[foliage-preview] saved %s_{%s}.png @ %dx%d" % [prefix, ",".join(views), RES.x, RES.y])
	get_tree().quit()

func _setup_env() -> void:
	# Dry sandy ground (the reference biome).
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(160, 160)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.62, 0.55, 0.40); gm.roughness = 1.0
	ground.material_override = gm
	_vp.add_child(ground)

	# High-ish bright sun (reference is a blue-sky day, not sunset).
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -120, 0)
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	_vp.add_child(sun)

	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.24, 0.44, 0.78)       # deeper blue up high
	sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sky_mat.ground_horizon_color = Color(0.75, 0.72, 0.62)
	sky_mat.ground_bottom_color = Color(0.55, 0.50, 0.42)
	var sky := Sky.new(); sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.0010
	env.fog_light_color = Color(0.78, 0.82, 0.88)
	env.fog_aerial_perspective = 0.25
	var we := WorldEnvironment.new(); we.environment = env
	_vp.add_child(we)

func _populate() -> void:
	# A few big branching-trunk trees at varied seeds + scales (the hero tree centred).
	var hero_tree := TreeKit.build(3, 1.15)
	hero_tree.position = Vector3(0.0, 0.0, -6.0)
	_vp.add_child(hero_tree)
	for i in 3:
		var t := TreeKit.build(20 + i, randf_scale(i))
		t.position = Vector3(-14.0 + i * 11.0, 0.0, -16.0)
		_vp.add_child(t)

	# The flat cobble ground-patch you stand on, with a 1.8 m scale capsule on it.
	var patch := RockKit.build_patch(1, 4.5)
	patch.position = Vector3(3.0, 0.0, 2.0)
	_vp.add_child(patch)
	_vp.add_child(_scale_capsule(Vector3(3.0, 0.9, 2.0)))

	# A couple of 3D boulders (BattleBit has these too, mostly smaller / distant).
	_add_boulder(30, 1.4, Vector3(-4.0, 0.0, 1.0))
	_add_boulder(31, 1.0, Vector3(-6.5, 0.0, 3.5))

	# Filter comparison: two big identical frond cards side by side (nearest vs linear).
	_vp.add_child(_filter_card(Vector3(-1.8, 2.0, 12.0), BaseMaterial3D.TEXTURE_FILTER_NEAREST))
	_vp.add_child(_filter_card(Vector3(1.8, 2.0, 12.0), BaseMaterial3D.TEXTURE_FILTER_LINEAR))

func randf_scale(i: int) -> float:
	return [0.9, 1.05, 0.8][i % 3]

func _add_boulder(seed: int, size: float, pos: Vector3) -> void:
	var r := RockKit.build(seed, size)
	r.position = pos
	_vp.add_child(r)

func _scale_capsule(pos: Vector3) -> MeshInstance3D:
	var cap := CapsuleMesh.new(); cap.radius = 0.3; cap.height = 1.8
	var mi := MeshInstance3D.new(); mi.mesh = cap; mi.position = pos
	var m := StandardMaterial3D.new(); m.albedo_color = Color(0.2, 0.35, 0.55); m.roughness = 1.0
	mi.material_override = m
	return mi

func _filter_card(pos: Vector3, filter: int) -> MeshInstance3D:
	var q := QuadMesh.new(); q.size = Vector2(3.2, 1.8)
	var mi := MeshInstance3D.new(); mi.mesh = q; mi.position = pos
	var m := TreeKit._frond_material(0).duplicate() as StandardMaterial3D
	m.texture_filter = filter
	mi.material_override = m
	return mi

func _aim(view: String) -> void:
	var pos: Vector3
	var target: Vector3
	match view:
		"hero":       # eye-level, standing back from the hero tree (like the reference)
			pos = Vector3(7.0, 1.7, 4.0); target = Vector3(0.0, 5.0, -6.0)
		"trees":      # look up into the canopy from below (isolates the frond planes)
			pos = Vector3(1.5, 1.6, -2.5); target = Vector3(0.0, 8.0, -6.0)
		"rock":       # down at the cobble ground-patch + scale capsule
			pos = Vector3(3.0, 2.6, 7.0); target = Vector3(3.0, 0.2, 2.0)
		"iso":
			pos = Vector3(14.0, 11.0, 12.0); target = Vector3(0.0, 4.0, -6.0)
		"filter":
			pos = Vector3(0.0, 2.0, 16.5); target = Vector3(0.0, 2.0, 12.0)
		_:
			pos = Vector3(10, 6, 10); target = Vector3.ZERO
	_cam.look_at_from_position(pos, target, Vector3.UP)
