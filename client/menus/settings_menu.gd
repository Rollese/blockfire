class_name SettingsMenu
extends Control
## In-game settings overlay: sensitivity, FOV, master volume, invert Y, renderer fallback.
## Emits settings_applied(settings) when the player applies/saves. Esc toggles visibility
## (client_main wires the toggle in Task 25).
## bind_settings → populate controls; apply() → read controls back → save → emit.

signal settings_applied(settings: ClientSettings)

## The active settings object. Populated by bind_settings().
var settings: ClientSettings = null

# UI controls — may be null when run headless / in tests.
var _sensitivity_slider: HSlider = null
var _fov_spin: SpinBox = null
var _volume_slider: HSlider = null
var _invert_y_check: CheckBox = null
var _fallback_check: CheckBox = null

func _ready() -> void:
	# Build a minimal UI tree. In a real scene these come from the .tscn; here we
	# construct them so the node works both in-scene and headless.
	_build_ui()

func _build_ui() -> void:
	# Full-screen overlay: dimmed backdrop + centered panel so the menu is obvious and not a
	# top-left cluster. STOP mouse on the root so clicks don't fall through to the 3D world.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 20)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(320, 0)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(_row_label("Mouse sensitivity"))
	_sensitivity_slider = HSlider.new()
	_sensitivity_slider.min_value = 0.01
	_sensitivity_slider.max_value = 2.0
	_sensitivity_slider.step = 0.01
	vbox.add_child(_sensitivity_slider)

	vbox.add_child(_row_label("Field of view"))
	_fov_spin = SpinBox.new()
	_fov_spin.min_value = 60.0
	_fov_spin.max_value = 120.0
	_fov_spin.step = 1.0
	vbox.add_child(_fov_spin)

	vbox.add_child(_row_label("Master volume"))
	_volume_slider = HSlider.new()
	_volume_slider.min_value = 0.0
	_volume_slider.max_value = 1.0
	_volume_slider.step = 0.01
	vbox.add_child(_volume_slider)

	_invert_y_check = CheckBox.new()
	_invert_y_check.text = "Invert Y"
	vbox.add_child(_invert_y_check)

	_fallback_check = CheckBox.new()
	_fallback_check.text = "Renderer Fallback (GL Compat)"
	vbox.add_child(_fallback_check)

	var apply_btn := Button.new()
	apply_btn.text = "Apply / Save"
	apply_btn.pressed.connect(apply)
	vbox.add_child(apply_btn)

static func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

## Store the settings object and populate controls from it.
func bind_settings(s: ClientSettings) -> void:
	settings = s
	_populate_controls()

func _populate_controls() -> void:
	if settings == null:
		return
	if _sensitivity_slider != null:
		_sensitivity_slider.value = settings.sensitivity
	if _fov_spin != null:
		_fov_spin.value = settings.fov
	if _volume_slider != null:
		_volume_slider.value = settings.master_volume
	if _invert_y_check != null:
		_invert_y_check.button_pressed = settings.invert_y
	if _fallback_check != null:
		_fallback_check.button_pressed = settings.renderer_fallback

## Read controls back into settings, save, and emit. Safe to call headless
## (falls back to current settings values when controls are null).
func apply() -> void:
	if settings == null:
		settings = ClientSettings.new()
	if _sensitivity_slider != null:
		settings.sensitivity = _sensitivity_slider.value
	if _fov_spin != null:
		settings.fov = _fov_spin.value
	if _volume_slider != null:
		settings.master_volume = _volume_slider.value
	if _invert_y_check != null:
		settings.invert_y = _invert_y_check.button_pressed
	if _fallback_check != null:
		settings.renderer_fallback = _fallback_check.button_pressed
	settings.save_to()
	settings_applied.emit(settings)
