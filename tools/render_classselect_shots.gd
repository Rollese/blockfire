extends SceneTree
## Standalone screenshot harness for the M19 P3 class-select / deploy loadout screen.
## Instantiates ClassSelectPanel directly (NO server / networking), seeds it with each class's
## default loadout via Loadout.default_loadout(), and writes one PNG per class so the deploy
## loadout screen (pickers + trait_blurbs perk panel) can be judged on a real GPU without a playtest.
## Needs a real renderer (GPU + display, or xvfb), NOT --headless. Run:
##   godot --path . -s res://tools/render_classselect_shots.gd --rendering-driver opengl3 -- --shot=<prefix>
## Saves <prefix>_{assault,medic,engineer,support}.png at 1920x1080. Deterministic (no bots, no net).

const RES := Vector2i(1920, 1080)

func _initialize() -> void:
	var prefix := "/tmp/classselect"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			prefix = a.substr(7)

	var root := get_root()
	root.size = RES

	# A neutral dark background stands in for the deploy screen behind the overlay.
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# The primary picker labels come from the named-variant registry, which the real client loads
	# at init (client_main.gd) — load it here too so the screenshot shows the actual primary list.
	Weapon.load_from_file("res://data/weapons.json")
	var attach: Attachment = Attachment.load_file("res://data/attachments.json")

	var panel: ClassSelectPanel = ClassSelectPanel.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)

	var classes := [
		[Loadout.ASSAULT, "assault"],
		[Loadout.MEDIC, "medic"],
		[Loadout.ENGINEER, "engineer"],
		[Loadout.SUPPORT, "support"],
	]

	await process_frame
	await process_frame

	for entry in classes:
		var cls: int = int(entry[0])
		var tag: String = String(entry[1])
		panel.setup(Loadout.default_loadout(cls), attach)
		# Let the UI theme / label reflow settle before capturing.
		for _i in 6:
			await process_frame
		var img := get_root().get_texture().get_image()
		var path := "%s_%s.png" % [prefix, tag]
		img.save_png(path)
		print("[classselect-preview] wrote %s (class=%d)" % [ProjectSettings.globalize_path(path), cls])

	quit(0)
