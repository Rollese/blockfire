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
var _skirt := true    # mirror the game: ground perimeter walls/columns carry a floor-skirt deck
var _noroof := false  # omit the top bfloor slab so a top/iso view sees the interior floor
var _debug := false   # diagnostic: unshaded, shadows off, each piece flat-coloured by facing/type

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=")
			args[String(kv[0])] = String(kv[1]) if kv.size() > 1 else "true"
	var bname := String(args.get("building", "house"))
	var prefix := String(args.get("shot", "/tmp/prev"))
	# --full renders the 9-direction + isometric review sweep (the standard QA pass for any NEW
	# building block / template — see docs/runbooks/building-kit.md). Default stays the quick 4 angles.
	var full := String(args.get("full", "false")) == "true"
	# --skirt (default true, mirrors the game): ground perimeter walls/columns carry a floor-skirt slab
	# so the deck reaches the walls. --noroof omits the top slab so a top/iso view exposes the interior
	# floor coverage (the only way to inspect the floor-to-wall gap + its skirt fix; the roof hides it).
	_skirt = String(args.get("skirt", "true")) == "true"
	_noroof = String(args.get("noroof", "false")) == "true"
	_debug = String(args.get("debug", "false")) == "true"

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

	# 9-direction + isometric QA sweep, or the quick default set.
	var views: Array = ["n", "ne", "e", "se", "s", "sw", "w", "nw", "top", "iso"] if full \
		else ["iso", "front", "side", "eye"]
	for view in views:
		_aim(bb, view)
		for _i in 4:
			await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		if img != null:
			img.save_png("%s_%s.png" % [prefix, view])
	print("[preview] saved %s_{%s}.png building=%s @ %dx%d" % [prefix, ",".join(views), bname, RES.x, RES.y])
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
	sun.shadow_enabled = not _debug   # debug: no shadows so geometry position isn't hidden by shade
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
	var maxy := 0
	var cxmin := 1 << 30; var cxmax := -(1 << 30); var czmin := 1 << 30; var czmax := -(1 << 30)
	for piece in data["pieces"]:
		var o = piece["offset"]
		maxy = maxi(maxy, int(o[1]))
		cxmin = mini(cxmin, int(o[0])); cxmax = maxi(cxmax, int(o[0]))
		czmin = mini(czmin, int(o[2])); czmax = maxi(czmax, int(o[2]))
	var cenx := float(cxmin + cxmax) * 0.5   # building centre in cells
	var cenz := float(czmin + czmax) * 0.5
	for piece in data["pieces"]:
		var off = piece["offset"]
		var cell := Vector3i(int(off[0]), int(off[1]), int(off[2]))
		var pid := String(piece["type"])
		if _noroof and cell.y == maxy and pid == "bfloor":
			continue   # drop the roof slab so the interior floor is visible from above
		# Mirror world_renderer: ground-level (cell.y == 0) perimeter walls/columns + interior props skirt.
		var skirt := _skirt and cell.y == 0 and (pid.begins_with("bwall") or pid == "bcolumn" \
			or pid.begins_with("prop_"))
		var ystep := int(piece.get("yaw", 0))
		var node: Node3D = BuildingKit.build(pid, 3, skirt, ystep)
		var wpos := Vector3((float(cell.x) + 0.5) * CELL, float(cell.y) * CELL, (float(cell.z) + 0.5) * CELL)
		node.position = wpos
		if pid != "bwall_corner":
			node.rotation = Vector3(0.0, BuildGrid.yaw_radians(ystep), 0.0)
		# Edge-align straight walls to the footprint: shift OUTWARD from the building centre along the
		# wall's thin axis (yaw can't tell N from S / E from W — opposite walls share a yaw — so direction
		# must come from the cell's position vs centre). Corner arms are already at the exterior edge.
		if pid.begins_with("bwall") and pid != "bwall_corner":
			var out_amt := CELL * 0.5 - 0.15
			if ystep % 4 == 0:   # yaw 0/4 -> thin in Z -> push along Z
				node.position.z += signf(float(cell.z) - cenz) * out_amt
			else:                # yaw 2/6 -> thin in X -> push along X
				node.position.x += signf(float(cell.x) - cenx) * out_amt
		if _debug:
			_debug_tint(node, pid, ystep)
		_vp.add_child(node)
		lo = Vector3(minf(lo.x, wpos.x - CELL), minf(lo.y, wpos.y), minf(lo.z, wpos.z - CELL))
		hi = Vector3(maxf(hi.x, wpos.x + CELL), maxf(hi.y, wpos.y + CELL), maxf(hi.z, wpos.z + CELL))
	return AABB(lo, hi - lo)

## Diagnostic: replace every mesh material with a flat UNSHADED colour keyed by piece facing/type, so
## it's unambiguous where each piece sits (walls S/W/N/E = red/green/blue/yellow, corner = magenta,
## floor = grey, column = cyan, props = white). No lighting -> no shadow hiding an inset/overhang.
func _debug_tint(node: Node3D, pid: String, ystep: int) -> void:
	var col := Color(1, 0.5, 0)   # fallback: orange
	if pid == "bwall_corner": col = Color(1, 0, 1)
	elif pid == "bfloor": col = Color(0.5, 0.5, 0.5)
	elif pid == "bcolumn": col = Color(0, 0.8, 0.8)
	elif pid.begins_with("prop_"): col = Color(1, 1, 1)
	elif pid.begins_with("bwall"):
		match ystep % 8:
			0: col = Color(0.9, 0.2, 0.2)   # S
			2: col = Color(0.2, 0.8, 0.2)   # W
			4: col = Color(0.2, 0.4, 1.0)   # N
			6: col = Color(0.95, 0.85, 0.1) # E
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = mat

const _COMPASS := {
	"n": Vector2(0, 1), "ne": Vector2(0.707, 0.707), "e": Vector2(1, 0), "se": Vector2(0.707, -0.707),
	"s": Vector2(0, -1), "sw": Vector2(-0.707, -0.707), "w": Vector2(-1, 0), "nw": Vector2(-0.707, 0.707),
}

func _aim(bb: AABB, view: String) -> void:
	var center := bb.position + bb.size * 0.5
	var r := maxf(bb.size.length(), 8.0)
	var pos: Vector3
	if _COMPASS.has(view):
		# 3/4 horizontal view from a compass bearing — elevated enough to read roofline + wall faces,
		# low enough to expose corner gaps and the ground-floor join.
		var d: Vector2 = _COMPASS[view]
		pos = center + Vector3(d.x * r * 1.05, bb.size.y * 0.5 + r * 0.30, d.y * r * 1.05)
	else:
		match view:
			"top":
				pos = center + Vector3(0.01, r * 1.7, 0.0)   # straight down (tiny x so look_at has a basis)
			"front":
				pos = center + Vector3(0, bb.size.y * 0.6, r * 1.05)
			"side":
				pos = center + Vector3(r * 1.05, bb.size.y * 0.6, 0)
			"eye":
				pos = bb.position + Vector3(bb.size.x * 0.5, 1.6, -r * 0.55)
			_:
				pos = center + Vector3(r * 0.95, r * 0.85, r * 0.95)
	var target := center if view != "eye" else center - Vector3(0, bb.size.y * 0.2, 0)
	_cam.look_at_from_position(pos, target, Vector3.UP)
