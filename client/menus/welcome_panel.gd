class_name WelcomePanel
extends Control
## Main-menu home screen — logo + navigation buttons.

const MENU_LOGO := "res://client/art/menu/blockfire_logo.png"

signal play_pressed
signal player_pressed
signal settings_pressed
signal quit_pressed

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()

func _build_ui() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	vbox.custom_minimum_size = Vector2(520, 0)
	center.add_child(vbox)

	var logo := TextureRect.new()
	logo.texture = MenuArt.load_texture(MENU_LOGO)
	logo.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(900, 280)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(logo)

	var subtitle := Label.new()
	subtitle.text = "Low-poly Conquest FPS"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.modulate = Color(0.82, 0.86, 0.9)
	vbox.add_child(subtitle)

	vbox.add_child(_spacer(24))

	for spec in [
		["Play", play_pressed],
		["Player Profile", player_pressed],
		["Settings", settings_pressed],
		["Quit", quit_pressed],
	]:
		var btn := Button.new()
		btn.text = spec[0]
		btn.custom_minimum_size = Vector2(280, 44)
		btn.pressed.connect(spec[1].emit)
		vbox.add_child(btn)

static func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s
