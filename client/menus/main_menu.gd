class_name MainMenu
extends Control
## Pre-game main menu shell — welcome, server browser, player profile, and settings.

const MENU_BG := "res://client/art/menu/menu_background.png"

signal connect_requested(ip: String, port: int, player_name: String)
signal quit_requested

enum Screen { WELCOME, SERVER_BROWSER, PLAYER, SETTINGS }

var _settings: ClientSettings
var _screen := Screen.WELCOME

var _welcome: WelcomePanel
var _browser: ServerBrowser
var _player: PlayerMenu
var _settings_menu: SettingsMenu

func configure(settings: ClientSettings, default_ip: String, default_port: int) -> void:
	_settings = settings
	if _browser != null:
		_browser.configure(default_ip, default_port)
	if _player != null:
		_player.configure(settings)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_show_screen(Screen.WELCOME)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _build_ui() -> void:
	var bg_tex := TextureRect.new()
	bg_tex.texture = MenuArt.load_texture(MENU_BG)
	bg_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg_tex)

	# Darken the background so menu panels and buttons stay readable.
	var overlay := ColorRect.new()
	overlay.color = Color(0.02, 0.05, 0.1, 0.55)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	var stack := Control.new()
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stack)

	_welcome = WelcomePanel.new()
	stack.add_child(_welcome)
	_welcome.play_pressed.connect(func(): _show_screen(Screen.SERVER_BROWSER))
	_welcome.player_pressed.connect(func(): _show_screen(Screen.PLAYER))
	_welcome.settings_pressed.connect(func(): _show_screen(Screen.SETTINGS))
	_welcome.quit_pressed.connect(quit_requested.emit)

	_browser = ServerBrowser.new()
	stack.add_child(_browser)
	_browser.back_pressed.connect(func(): _show_screen(Screen.WELCOME))
	_browser.connect_pressed.connect(_on_connect_pressed)

	_player = PlayerMenu.new()
	stack.add_child(_player)
	_player.back_pressed.connect(func(): _show_screen(Screen.WELCOME))
	_player.name_changed.connect(_on_player_name_changed)

	_settings_menu = SettingsMenu.new()
	_settings_menu.show_back_button = true
	stack.add_child(_settings_menu)
	_settings_menu.back_pressed.connect(func(): _show_screen(Screen.WELCOME))
	_settings_menu.settings_applied.connect(_on_settings_applied)

	if _settings != null:
		_settings_menu.bind_settings(_settings)
		_player.configure(_settings)

func _show_screen(screen: Screen) -> void:
	_screen = screen
	_welcome.visible = screen == Screen.WELCOME
	_browser.visible = screen == Screen.SERVER_BROWSER
	_player.visible = screen == Screen.PLAYER
	_settings_menu.visible = screen == Screen.SETTINGS
	if screen == Screen.SETTINGS and _settings != null:
		_settings_menu.bind_settings(_settings)

func _on_connect_pressed(ip: String, port: int) -> void:
	var name := _settings.player_name if _settings != null else "Player"
	connect_requested.emit(ip, port, name)

func _on_player_name_changed(name: String) -> void:
	if _settings != null:
		_settings.player_name = name
		_settings.save_to()

func _on_settings_applied(new_settings: ClientSettings) -> void:
	_settings = new_settings

func set_connect_error(msg: String) -> void:
	_browser.set_status(msg)
	_show_screen(Screen.SERVER_BROWSER)
