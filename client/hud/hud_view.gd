class_name HudView
extends Control
## Presentation-only HUD. Draws data from HudModel.build() — no gameplay logic here.
## All Control tree setup happens in _ready() / setup(); render(model) updates it each frame.
## AGENTS.md §7: no health, no minimap, no numeric damage.

const COMPASS_STRIP_WIDTH := 400.0
const COMPASS_HEIGHT := 24.0
const KILLFEED_MAX := 6
const ARC_POOL_SIZE := 8        # max concurrent directional-damage arcs
const ARC_RADIUS := 180.0       # distance from screen centre where arcs appear

# ---- node references --------------------------------------------------
var _ammo_label: Label
var _reload_label: Label
var _compass_label: Label
var _compass_container: Control   # holds marker labels; children are reused per render
var _tickets_label: Label
var _cap_bar: ColorRect           # capture progress bar background
var _cap_fill: ColorRect          # capture progress fill
var _killfeed_labels: Array[Label] = []
var _vignette: ColorRect
var _arc_pool: Array[Control] = []
var _prompt_label: Label          # placeholder interaction hook

# ---- constants for owner tint -----------------------------------------
const _OWNER_COLORS: Array[Color] = [
	Color(0.3, 0.6, 1.0),    # team 0 — blue
	Color(1.0, 0.4, 0.3),    # team 1 — red
	Color(0.8, 0.8, 0.8),    # neutral / -1 (index 2 used as fallback)
]


func _ready() -> void:
	if _ammo_label == null:
		_build_tree()


## Public: call once after adding HudView to the scene tree when _ready() has NOT yet fired
## (e.g. you added it before calling add_child). In normal Godot flow _ready fires automatically.
func setup() -> void:
	if _ammo_label == null:
		_build_tree()


## Public interface consumed by client_main (Task 25).
## Guard against partial / empty model so a missing key can never crash this.
## Also safe to call before _ready() fires — lazily initialises the tree.
func render(model: Dictionary) -> void:
	if _ammo_label == null:
		_build_tree()
	_render_ammo(model.get("ammo", {}))
	_render_compass(model.get("compass", {}))
	_render_tickets(model.get("tickets", [0, 0]), model.get("capture"))
	_render_killfeed(model.get("killfeed", []))
	_render_damage(model.get("damage_arcs", []), float(model.get("vignette", 0.0)))


# -----------------------------------------------------------------------
# Tree construction
# -----------------------------------------------------------------------

func _build_tree() -> void:
	# This control covers the full screen but ignores mouse so menus work.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = MOUSE_FILTER_IGNORE

	_build_crosshair()
	_build_ammo()
	_build_compass()
	_build_tickets()
	_build_killfeed()
	_build_vignette()
	_build_damage_arcs()
	_build_prompt()


func _build_crosshair() -> void:
	# Simple "+" drawn as a label at screen centre.
	var ch := Label.new()
	ch.text = "+"
	ch.add_theme_font_size_override("font_size", 20)
	ch.anchor_left = 0.5
	ch.anchor_top = 0.5
	ch.anchor_right = 0.5
	ch.anchor_bottom = 0.5
	ch.offset_left = -8.0
	ch.offset_top = -12.0
	ch.modulate = Color(1, 1, 1, 0.85)
	ch.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(ch)


func _build_ammo() -> void:
	# Ammo count — bottom-right.
	var panel := Control.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -160.0
	panel.offset_right = 0.0
	panel.offset_top = -80.0
	panel.offset_bottom = 0.0
	panel.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(panel)

	_ammo_label = Label.new()
	_ammo_label.text = "30"
	_ammo_label.add_theme_font_size_override("font_size", 28)
	_ammo_label.modulate = Color(1, 1, 1)
	_ammo_label.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(_ammo_label)

	_reload_label = Label.new()
	_reload_label.text = "RELOADING"
	_reload_label.add_theme_font_size_override("font_size", 16)
	_reload_label.modulate = Color(1.0, 0.8, 0.2)
	_reload_label.position = Vector2(0, 36)
	_reload_label.visible = false
	_reload_label.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(_reload_label)


func _build_compass() -> void:
	# Compass strip — top-centre.
	var strip := Control.new()
	strip.anchor_left = 0.5
	strip.anchor_right = 0.5
	strip.anchor_top = 0.0
	strip.anchor_bottom = 0.0
	strip.offset_left = -COMPASS_STRIP_WIDTH * 0.5
	strip.offset_right = COMPASS_STRIP_WIDTH * 0.5
	strip.offset_top = 8.0
	strip.offset_bottom = 8.0 + COMPASS_HEIGHT + 16.0
	strip.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(strip)

	# Background bar.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.4)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	strip.add_child(bg)

	# Heading label centred in the strip.
	_compass_label = Label.new()
	_compass_label.anchor_left = 0.5
	_compass_label.anchor_top = 0.0
	_compass_label.anchor_right = 0.5
	_compass_label.offset_left = -40.0
	_compass_label.offset_right = 40.0
	_compass_label.offset_top = 2.0
	_compass_label.text = "N 0°"
	_compass_label.mouse_filter = MOUSE_FILTER_IGNORE
	strip.add_child(_compass_label)

	# Container for objective markers (children reused each render).
	_compass_container = strip


func _build_tickets() -> void:
	# Tickets — top-left; capture bar below them.
	var panel := Control.new()
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = 12.0
	panel.offset_right = 200.0
	panel.offset_top = 8.0
	panel.offset_bottom = 80.0
	panel.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(panel)

	_tickets_label = Label.new()
	_tickets_label.text = "T0: 0  T1: 0"
	_tickets_label.add_theme_font_size_override("font_size", 16)
	_tickets_label.modulate = Color(1, 1, 1)
	_tickets_label.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(_tickets_label)

	# Capture progress bar (bg + fill).
	_cap_bar = ColorRect.new()
	_cap_bar.color = Color(0.2, 0.2, 0.2, 0.8)
	_cap_bar.position = Vector2(0, 28)
	_cap_bar.size = Vector2(160, 14)
	_cap_bar.visible = false
	_cap_bar.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(_cap_bar)

	_cap_fill = ColorRect.new()
	_cap_fill.color = Color(0.4, 0.8, 0.4, 0.9)
	_cap_fill.position = Vector2(0, 0)
	_cap_fill.size = Vector2(0, 14)
	_cap_fill.mouse_filter = MOUSE_FILTER_IGNORE
	_cap_bar.add_child(_cap_fill)


func _build_killfeed() -> void:
	# Killfeed — top-right column.
	var panel := Control.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -280.0
	panel.offset_right = -4.0
	panel.offset_top = 8.0
	panel.offset_bottom = 8.0 + KILLFEED_MAX * 22.0
	panel.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(panel)

	for i in KILLFEED_MAX:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.modulate = Color(1, 1, 1, 0.9)
		lbl.position = Vector2(0, i * 22.0)
		lbl.text = ""
		lbl.visible = false
		lbl.mouse_filter = MOUSE_FILTER_IGNORE
		panel.add_child(lbl)
		_killfeed_labels.append(lbl)


func _build_vignette() -> void:
	# Full-screen red overlay whose alpha encodes received-damage intensity.
	_vignette = ColorRect.new()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color(0.9, 0.05, 0.05, 0.0)
	_vignette.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_vignette)


func _build_damage_arcs() -> void:
	# Pool of small Control nodes that draw directional damage triangles.
	# They are positioned around the screen centre; alpha = fade.
	for i in ARC_POOL_SIZE:
		var arc := _ArcMarker.new()
		arc.visible = false
		arc.mouse_filter = MOUSE_FILTER_IGNORE
		add_child(arc)
		_arc_pool.append(arc)


func _build_prompt() -> void:
	# Placeholder for future interaction prompts (hidden unless client_main sets it).
	_prompt_label = Label.new()
	_prompt_label.anchor_left = 0.5
	_prompt_label.anchor_top = 0.75
	_prompt_label.anchor_right = 0.5
	_prompt_label.offset_left = -120.0
	_prompt_label.offset_right = 120.0
	_prompt_label.text = ""
	_prompt_label.visible = false
	_prompt_label.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_prompt_label)


# -----------------------------------------------------------------------
# Per-frame render helpers
# -----------------------------------------------------------------------

func _render_ammo(ammo: Dictionary) -> void:
	var mag: int = int(ammo.get("mag", 0))
	var reloading: bool = bool(ammo.get("reloading", false))
	var low: bool = bool(ammo.get("low", false))

	_ammo_label.text = "%d /∞" % mag
	_ammo_label.modulate = Color(1.0, 0.4, 0.3) if low else Color(1, 1, 1)
	_reload_label.visible = reloading


func _render_compass(compass: Dictionary) -> void:
	var heading_rad: float = float(compass.get("heading", 0.0))
	var heading_deg: int = int(round(rad_to_deg(heading_rad)))
	if heading_deg < 0:
		heading_deg += 360
	var cardinal: String = _cardinal(heading_deg)
	_compass_label.text = "%s %d°" % [cardinal, heading_deg]

	# Remove previous marker children (all except the bg ColorRect and the heading label).
	# We keep index 0 (bg) and index 1 (compass_label) — remove any after.
	var child_count := _compass_container.get_child_count()
	for i in range(child_count - 1, 1, -1):
		_compass_container.get_child(i).queue_free()

	# Rebuild objective markers.
	var markers: Array = compass.get("markers", [])
	for m: Dictionary in markers:
		var rel: float = float(m.get("rel_bearing", 0.0))
		var owner: int = int(m.get("owner", -1))
		# Map rel_bearing (-PI..PI] to x offset within strip.
		var strip_half := COMPASS_STRIP_WIDTH * 0.5
		var x := (rel / PI) * strip_half + strip_half - 6.0   # centre of strip at rel=0
		var dot := Label.new()
		dot.text = "▼"
		dot.add_theme_font_size_override("font_size", 12)
		dot.modulate = _owner_color(owner)
		dot.position = Vector2(clampf(x, 2.0, COMPASS_STRIP_WIDTH - 14.0), COMPASS_HEIGHT - 2.0)
		dot.mouse_filter = MOUSE_FILTER_IGNORE
		_compass_container.add_child(dot)


func _render_tickets(tickets: Array, capture) -> void:
	var t0: int = int(tickets[0]) if tickets.size() > 0 else 0
	var t1: int = int(tickets[1]) if tickets.size() > 1 else 0
	_tickets_label.text = "%d  |  %d" % [t0, t1]

	if capture == null:
		_cap_bar.visible = false
	else:
		_cap_bar.visible = true
		var cap: float = clampf(float(capture.get("cap", 0.0)), 0.0, 1.0)
		_cap_fill.size = Vector2(_cap_bar.size.x * cap, _cap_bar.size.y)
		# Tint fill by attacker team.
		var attacker: int = int(capture.get("attacker", -1))
		_cap_fill.color = _owner_color(attacker).lerp(Color(1, 1, 1, 0.9), 0.3)


func _render_killfeed(entries: Array) -> void:
	var n: int = mini(entries.size(), KILLFEED_MAX)
	# Show most-recent at the top.
	for i in KILLFEED_MAX:
		var lbl: Label = _killfeed_labels[i]
		var entry_idx: int = entries.size() - 1 - i
		if i >= n or entry_idx < 0:
			lbl.visible = false
		else:
			var e: Dictionary = entries[entry_idx]
			var hs: String = " ☆" if bool(e.get("headshot", false)) else ""
			lbl.text = "%d → %d%s" % [int(e.get("killer", 0)), int(e.get("victim", 0)), hs]
			lbl.visible = true


func _render_damage(arcs: Array, vignette: float) -> void:
	# Vignette alpha — clamp for safety.
	_vignette.color.a = clampf(vignette, 0.0, 1.0)

	# Directional arc markers — pool reuse.
	var n: int = mini(arcs.size(), ARC_POOL_SIZE)
	for i in ARC_POOL_SIZE:
		var arc := _arc_pool[i] as _ArcMarker
		if i >= n:
			arc.visible = false
		else:
			var entry: Dictionary = arcs[i]
			arc.rel_bearing = float(entry.get("rel_bearing", 0.0))
			arc.fade = clampf(float(entry.get("fade", 0.0)), 0.0, 1.0)
			arc.visible = true
			arc.queue_redraw()


# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

static func _cardinal(deg: int) -> String:
	var sectors := ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
	return sectors[int(round(float(deg) / 45.0)) % 8]


static func _owner_color(owner: int) -> Color:
	match owner:
		0: return _OWNER_COLORS[0]
		1: return _OWNER_COLORS[1]
		_: return _OWNER_COLORS[2]


# -----------------------------------------------------------------------
# Inner class: arc marker drawn via _draw
# -----------------------------------------------------------------------

class _ArcMarker extends Control:
	var rel_bearing: float = 0.0   # radians, relative to camera facing
	var fade: float = 1.0

	const _SIZE := 22.0
	const _DIST := 160.0   # pixels from screen centre

	func _ready() -> void:
		# Size the control around screen centre so _draw origin maps naturally.
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var centre := size * 0.5
		# Point along the bearing circle.
		# rel_bearing = 0 is forward (up on screen). Godot 2D +Y is down, so:
		# forward = -Y. rel_bearing increases clockwise.
		var dir := Vector2(sin(rel_bearing), -cos(rel_bearing))
		var tip := centre + dir * _DIST
		var perp := Vector2(-dir.y, dir.x)
		var base_half := _SIZE * 0.5
		var base := tip - dir * _SIZE
		var p1 := base + perp * base_half
		var p2 := base - perp * base_half
		var col := Color(0.9, 0.1, 0.1, fade)
		draw_colored_polygon(PackedVector2Array([tip, p1, p2]), col)
