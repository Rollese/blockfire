class_name SettingsMenu
extends Control
## Settings overlay with Graphics / Audio / Controls tabs.
## Emits settings_applied(settings) when the player applies/saves.
## show_back_button=true adds a Back button for the pre-game main menu flow.

signal settings_applied(settings: ClientSettings)
signal back_pressed

var settings: ClientSettings = null
var show_back_button: bool = false
var save_path: String = "user://settings.cfg"

# Graphics
var _resolution_option: OptionButton = null
var _window_mode_option: OptionButton = null
var _fov_spin: SpinBox = null
var _fallback_check: CheckBox = null

# Audio
var _master_slider: HSlider = null
var _voice_slider: HSlider = null
var _output_option: OptionButton = null
var _input_option: OptionButton = null
var _mic_level: ProgressBar = null
var _mic_status: Label = null
var _mic_player: AudioStreamPlayer = null
var _mic_testing := false

# Controls
var _sensitivity_slider: HSlider = null
var _invert_y_check: CheckBox = null
var _bind_rows: Dictionary = {}   # action -> Button
var _rebind_action: String = ""
var _rebind_label: Label = null
var _back_btn: Button = null

func _ready() -> void:
	_build_ui()

func _input(event: InputEvent) -> void:
	if _rebind_action == "":
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_finish_rebind(event)
	elif event is InputEventMouseButton and event.pressed:
		_finish_rebind(event)

func _process(_delta: float) -> void:
	if not _mic_testing or _mic_level == null:
		return
	var peak := 0.0
	if AudioServer.get_bus_index("Record") >= 0:
		var idx := AudioServer.get_bus_index("Record")
		var l := AudioServer.get_bus_peak_volume_left_db(idx, 0)
		var r := AudioServer.get_bus_peak_volume_right_db(idx, 0)
		peak = maxf(db_to_linear(l), db_to_linear(r))
	_mic_level.value = clampf(peak * 4.0, 0.0, 1.0) * 100.0

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.65)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(580, 500)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	root.add_child(title)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	_build_graphics_tab(tabs)
	_build_audio_tab(tabs)
	_build_controls_tab(tabs)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	root.add_child(btn_row)

	_back_btn = Button.new()
	_back_btn.text = "Back"
	_back_btn.visible = show_back_button
	_back_btn.pressed.connect(func(): back_pressed.emit())
	btn_row.add_child(_back_btn)

	var apply_btn := Button.new()
	apply_btn.text = "Apply / Save"
	apply_btn.pressed.connect(apply)
	btn_row.add_child(apply_btn)

func _build_graphics_tab(tabs: TabContainer) -> void:
	var scroll := _scroll_page("Graphics")
	tabs.add_child(scroll)
	var vbox: VBoxContainer = scroll.get_child(0).get_child(0)

	vbox.add_child(_row_label("Resolution"))
	_resolution_option = _full_width_option()
	for res: Vector2i in VideoSettings.common_resolutions():
		_resolution_option.add_item(VideoSettings.resolution_label(res))
	vbox.add_child(_resolution_option)

	vbox.add_child(_row_label("Display mode"))
	_window_mode_option = _full_width_option()
	for mode in VideoSettings.WINDOW_MODES:
		_window_mode_option.add_item(mode.capitalize())
	vbox.add_child(_window_mode_option)

	vbox.add_child(_row_label("Field of view"))
	_fov_spin = SpinBox.new()
	_fov_spin.min_value = 60.0
	_fov_spin.max_value = 120.0
	_fov_spin.step = 1.0
	_fov_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_fov_spin)

	_fallback_check = CheckBox.new()
	_fallback_check.text = "Renderer fallback (GL Compatibility)"
	vbox.add_child(_fallback_check)

func _build_audio_tab(tabs: TabContainer) -> void:
	var scroll := _scroll_page("Audio")
	tabs.add_child(scroll)
	var vbox: VBoxContainer = scroll.get_child(0).get_child(0)

	vbox.add_child(_row_label("Master volume"))
	_master_slider = _full_width_slider(0.0, 1.0, 0.01)
	vbox.add_child(_master_slider)

	vbox.add_child(_row_label("Voice volume"))
	_voice_slider = _full_width_slider(0.0, 1.0, 0.01)
	vbox.add_child(_voice_slider)

	vbox.add_child(_row_label("Output device"))
	_output_option = _full_width_option()
	_output_option.add_item("System default")
	for dev in AudioServer.get_output_device_list():
		_output_option.add_item(dev)
	vbox.add_child(_output_option)

	vbox.add_child(_row_label("Input device"))
	_input_option = _full_width_option()
	_input_option.add_item("System default")
	for dev in AudioServer.get_input_device_list():
		_input_option.add_item(dev)
	vbox.add_child(_input_option)

	var mic_btn_row := HBoxContainer.new()
	mic_btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(mic_btn_row)

	var mic_btn := Button.new()
	mic_btn.text = "Test microphone"
	mic_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mic_btn.pressed.connect(_toggle_mic_test)
	mic_btn_row.add_child(mic_btn)

	var mic_stop := Button.new()
	mic_stop.text = "Stop"
	mic_stop.pressed.connect(_stop_mic_test)
	mic_btn_row.add_child(mic_stop)

	_mic_level = ProgressBar.new()
	_mic_level.min_value = 0.0
	_mic_level.max_value = 100.0
	_mic_level.show_percentage = false
	_mic_level.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_mic_level)

	_mic_status = Label.new()
	_mic_status.text = "Mic test idle"
	_mic_status.modulate = Color(0.7, 0.75, 0.8)
	vbox.add_child(_mic_status)

func _build_controls_tab(tabs: TabContainer) -> void:
	var scroll := _scroll_page("Controls")
	tabs.add_child(scroll)
	var vbox: VBoxContainer = scroll.get_child(0).get_child(0)

	vbox.add_child(_row_label("Mouse sensitivity"))
	_sensitivity_slider = _full_width_slider(0.01, 2.0, 0.01)
	vbox.add_child(_sensitivity_slider)

	_invert_y_check = CheckBox.new()
	_invert_y_check.text = "Invert Y"
	vbox.add_child(_invert_y_check)

	vbox.add_child(_hline())

	_rebind_label = Label.new()
	_rebind_label.text = "Click a binding, then press a key or mouse button."
	_rebind_label.modulate = Color(0.75, 0.8, 0.9)
	vbox.add_child(_rebind_label)

	for entry: Dictionary in InputBindings.REBINDABLE:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(row)

		var name_l := Label.new()
		name_l.text = String(entry["label"])
		name_l.custom_minimum_size = Vector2(140, 0)
		name_l.size_flags_stretch_ratio = 0.4
		name_l.clip_text = true
		row.add_child(name_l)

		var btn := Button.new()
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.size_flags_stretch_ratio = 0.6
		btn.clip_text = true
		btn.pressed.connect(_start_rebind.bind(String(entry["action"])))
		row.add_child(btn)
		_bind_rows[String(entry["action"])] = btn

func bind_settings(s: ClientSettings) -> void:
	settings = s
	if _back_btn != null:
		_back_btn.visible = show_back_button
	_populate_controls()

func set_show_back(show_it: bool) -> void:
	show_back_button = show_it
	if _back_btn != null:
		_back_btn.visible = show_it

func _populate_controls() -> void:
	if settings == null:
		return
	if _sensitivity_slider != null:
		_sensitivity_slider.value = settings.sensitivity
	if _fov_spin != null:
		_fov_spin.value = settings.fov
	if _master_slider != null:
		_master_slider.value = settings.master_volume
	if _voice_slider != null:
		_voice_slider.value = settings.voice_volume
	if _invert_y_check != null:
		_invert_y_check.button_pressed = settings.invert_y
	if _fallback_check != null:
		_fallback_check.button_pressed = settings.renderer_fallback
	if _resolution_option != null:
		var idx := VideoSettings.find_resolution_index(settings.resolution_x, settings.resolution_y)
		_resolution_option.select(maxi(idx, 0))
	if _window_mode_option != null:
		var mode_idx := VideoSettings.WINDOW_MODES.find(settings.window_mode)
		_window_mode_option.select(maxi(mode_idx, 0))
	_select_device_option(_output_option, settings.output_device)
	_select_device_option(_input_option, settings.input_device)
	_refresh_bind_labels()

func _select_device_option(opt: OptionButton, device: String) -> void:
	if opt == null:
		return
	if device == "":
		opt.select(0)
		return
	for i in opt.item_count:
		if opt.get_item_text(i) == device:
			opt.select(i)
			return
	opt.select(0)

func _refresh_bind_labels() -> void:
	for action in _bind_rows:
		var btn: Button = _bind_rows[action]
		var ev := InputBindings.primary_event(action)
		btn.text = InputBindings.event_label(ev)

func apply() -> void:
	if settings == null:
		settings = ClientSettings.new()
	if _sensitivity_slider != null:
		settings.sensitivity = _sensitivity_slider.value
	if _fov_spin != null:
		settings.fov = _fov_spin.value
	if _master_slider != null:
		settings.master_volume = _master_slider.value
	if _voice_slider != null:
		settings.voice_volume = _voice_slider.value
	if _invert_y_check != null:
		settings.invert_y = _invert_y_check.button_pressed
	if _fallback_check != null:
		settings.renderer_fallback = _fallback_check.button_pressed
	if _resolution_option != null:
		var res_idx := _resolution_option.selected
		var presets := VideoSettings.common_resolutions()
		if res_idx >= 0 and res_idx < presets.size():
			settings.resolution_x = presets[res_idx].x
			settings.resolution_y = presets[res_idx].y
	if _window_mode_option != null:
		var mode_idx := _window_mode_option.selected
		if mode_idx >= 0 and mode_idx < VideoSettings.WINDOW_MODES.size():
			settings.window_mode = VideoSettings.WINDOW_MODES[mode_idx]
	if _output_option != null:
		settings.output_device = _device_from_option(_output_option)
	if _input_option != null:
		settings.input_device = _device_from_option(_input_option)
	settings.save_to(save_path)
	InputBindings.apply(settings)
	VideoSettings.apply(settings)
	_apply_audio_devices(settings)
	settings_applied.emit(settings)

func _device_from_option(opt: OptionButton) -> String:
	if opt == null or opt.selected <= 0:
		return ""
	return opt.get_item_text(opt.selected)

func _apply_audio_devices(s: ClientSettings) -> void:
	if s.output_device != "":
		AudioServer.output_device = s.output_device
	if s.input_device != "":
		AudioServer.input_device = s.input_device

func _start_rebind(action: String) -> void:
	_rebind_action = action
	if _rebind_label != null:
		_rebind_label.text = "Press a key or mouse button for: %s (Esc to cancel)" % action

func _finish_rebind(event: InputEvent) -> void:
	if _rebind_action == "":
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.physical_keycode == KEY_ESCAPE:
			_rebind_action = ""
			if _rebind_label != null:
				_rebind_label.text = "Rebind cancelled."
			return
	var d := InputBindings.event_to_dict(event)
	if d.is_empty():
		return
	if settings == null:
		settings = ClientSettings.new()
	settings.bindings[_rebind_action] = d
	InputMap.action_erase_events(_rebind_action)
	InputMap.action_add_event(_rebind_action, InputBindings.dict_to_event(d))
	_rebind_action = ""
	_refresh_bind_labels()
	if _rebind_label != null:
		_rebind_label.text = "Binding saved — click Apply / Save to persist."

func _toggle_mic_test() -> void:
	if _mic_testing:
		_stop_mic_test()
		return
	if _mic_player == null:
		_mic_player = AudioStreamPlayer.new()
		_mic_player.stream = AudioStreamMicrophone.new()
		add_child(_mic_player)
	_mic_player.play()
	_mic_testing = true
	if _mic_status != null:
		_mic_status.text = "Microphone live — speak to see the level meter."

func _stop_mic_test() -> void:
	_mic_testing = false
	if _mic_player != null:
		_mic_player.stop()
	if _mic_level != null:
		_mic_level.value = 0.0
	if _mic_status != null:
		_mic_status.text = "Mic test idle"

static func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

static func _hline() -> HSeparator:
	return HSeparator.new()

static func _scroll_page(tab_title: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 320)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	scroll.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	return scroll

static func _full_width_slider(min_v: float, max_v: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s

static func _full_width_option() -> OptionButton:
	var o := OptionButton.new()
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.clip_text = true
	return o
