class_name PlayerMenu
extends Control
## Player profile screen. Level and global stats are placeholders until backend ships.

signal back_pressed
signal name_changed(name: String)

const Protocol := preload("res://shared/net/protocol.gd")

var _name_edit: LineEdit

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()

func configure(settings: ClientSettings) -> void:
	if _name_edit != null:
		_name_edit.text = settings.player_name

func _build_ui() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(420, 0)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "PLAYER PROFILE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vbox.add_child(title)

	vbox.add_child(_row_label("Display name"))
	_name_edit = LineEdit.new()
	_name_edit.max_length = Protocol.MAX_NAME_LEN
	_name_edit.placeholder_text = "Player"
	vbox.add_child(_name_edit)

	var hint := Label.new()
	hint.text = "Allowed: letters, numbers, and %s" % Protocol._ALLOWED_NAME_SYMBOLS
	hint.modulate = Color(0.65, 0.7, 0.75)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)

	vbox.add_child(_hline())

	vbox.add_child(_row_label("Level"))
	vbox.add_child(_placeholder_stat("1  (placeholder — backend not connected)"))

	vbox.add_child(_row_label("Experience"))
	vbox.add_child(_placeholder_stat("0 / 1,000 XP  (placeholder)"))

	vbox.add_child(_hline())

	vbox.add_child(_row_label("Global statistics"))
	for line in [
		"Matches played:  —",
		"Total kills:     —",
		"Total deaths:    —",
		"Win rate:        —",
		"Hours played:    —",
	]:
		vbox.add_child(_placeholder_stat(line))

	var note := Label.new()
	note.text = "Stats will sync when online services land (M9)."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate = Color(0.75, 0.8, 0.85)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(note)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.pressed.connect(_on_back)
	vbox.add_child(back_btn)

func _on_back() -> void:
	var raw := _name_edit.text
	var sanitized := Protocol._sanitize_name(raw)
	if _name_edit.text != sanitized:
		_name_edit.text = sanitized
	name_changed.emit(sanitized)
	back_pressed.emit()

static func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

static func _placeholder_stat(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.modulate = Color(0.8, 0.82, 0.86)
	return l

static func _hline() -> HSeparator:
	return HSeparator.new()
