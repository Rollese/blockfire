class_name ServerBrowser
extends Control
## Server list + direct connect. Master server is not implemented yet — placeholder entries only.

signal back_pressed
signal connect_pressed(ip: String, port: int)

## Placeholder until M9 online services lands a master server browser.
const MASTER_SERVER_PLACEHOLDER := "Master server browser — not connected (M9 placeholder)"

const PLACEHOLDER_SERVERS: Array = [
	{
		"name": "LAN — game2",
		"ip": "192.168.1.166",
		"port": 27015,
		"map": "conquest_proving_grounds",
		"players": "—/128",
		"ping": "—",
	},
	{
		"name": "Localhost (dev)",
		"ip": "127.0.0.1",
		"port": 27015,
		"map": "conquest_dev_arena",
		"players": "—/128",
		"ping": "—",
	},
]

var _ip_edit: LineEdit
var _port_spin: SpinBox
var _status_label: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()

func configure(default_ip: String, default_port: int) -> void:
	if _ip_edit != null:
		_ip_edit.text = default_ip
	if _port_spin != null:
		_port_spin.value = default_port

func set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 40)
	add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	margin.add_child(outer)

	var title := Label.new()
	title.text = "SERVER BROWSER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	outer.add_child(title)

	var master_note := Label.new()
	master_note.text = MASTER_SERVER_PLACEHOLDER
	master_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	master_note.modulate = Color(0.85, 0.75, 0.45)
	master_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(master_note)

	outer.add_child(_hline())

	var list_label := Label.new()
	list_label.text = "Saved / placeholder servers"
	outer.add_child(list_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 180)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var list_vbox := VBoxContainer.new()
	list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(list_vbox)

	for srv: Dictionary in PLACEHOLDER_SERVERS:
		var row := _server_row(srv)
		list_vbox.add_child(row)

	outer.add_child(_hline())

	var direct_label := Label.new()
	direct_label.text = "Direct connect"
	outer.add_child(direct_label)

	var form := HBoxContainer.new()
	form.add_theme_constant_override("separation", 8)
	outer.add_child(form)

	form.add_child(_field_label("IP"))
	_ip_edit = LineEdit.new()
	_ip_edit.placeholder_text = "127.0.0.1"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(_ip_edit)

	form.add_child(_field_label("Port"))
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1
	_port_spin.max_value = 65535
	_port_spin.value = 27015
	form.add_child(_port_spin)

	var connect_btn := Button.new()
	connect_btn.text = "Connect"
	connect_btn.pressed.connect(_on_connect_pressed)
	outer.add_child(connect_btn)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.modulate = Color(0.9, 0.5, 0.5)
	outer.add_child(_status_label)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.pressed.connect(back_pressed.emit)
	outer.add_child(back_btn)

func _server_row(srv: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info)

	var name_l := Label.new()
	name_l.text = String(srv["name"])
	info.add_child(name_l)

	var meta := Label.new()
	meta.text = "%s  ·  %s  ·  ping %s" % [srv["map"], srv["players"], srv["ping"]]
	meta.modulate = Color(0.7, 0.75, 0.8)
	info.add_child(meta)

	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(_join_server.bind(String(srv["ip"]), int(srv["port"])))
	hbox.add_child(join)

	return panel

func _join_server(ip: String, port: int) -> void:
	connect_pressed.emit(ip, port)

func _on_connect_pressed() -> void:
	var ip := _ip_edit.text.strip_edges()
	if ip == "":
		set_status("Enter a server IP address.")
		return
	connect_pressed.emit(ip, int(_port_spin.value))

static func _field_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l

static func _hline() -> HSeparator:
	return HSeparator.new()
