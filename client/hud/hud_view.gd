class_name HudView
extends Control
## Presentation-only HUD. Draws data from HudModel.build() — no gameplay logic here.
## All Control tree setup happens in _ready() / setup(); render(model) updates it each frame.
## AGENTS.md §7: no health, no minimap, no numeric damage.

const COMPASS_STRIP_WIDTH := 400.0
const COMPASS_HEIGHT := 24.0
const COMPASS_MARKER_POOL := 12   # reused objective-marker labels (never realloc per frame)
const KILLFEED_MAX := 6
const ARC_POOL_SIZE := 8        # max concurrent directional-damage arcs
const ARC_RADIUS := 180.0       # distance from screen centre where arcs appear

# ---- throwable kind -> display label (data-driven; extend as new kinds are added) ----
const _THROWABLE_LABELS: Dictionary = {
	0: "Frag",
	1: "Smoke",
	100: "RPG",
}

# ---- node references --------------------------------------------------
var _ammo_label: Label
var _reload_label: Label
var _firemode_label: Label   # AUTO/SEMI/BURST glyph above the ammo count (M5.5-P1 fire-mode)
var _ammo_panel: Control   # ammo readout container — hidden while downed/dead
var _compass_label: Label
var _compass_container: Control   # holds marker labels; children are reused per render
var _compass_markers: Array[Label] = []   # pooled objective-marker labels (▼), reused each frame
var _tickets_label: Label
var _cap_bar: ColorRect           # capture progress bar background
var _cap_fill: ColorRect          # capture progress fill
var _killfeed_labels: Array[Label] = []
var _vignette: ColorRect
var _suppress_overlay: ColorRect  # M5.5-P2 suppression screen FX (bottom of HUD: blurs the world, HUD stays crisp)
var _suppress_mat: ShaderMaterial
var _blind_overlay: ColorRect     # M5.5-P3 flashbang white-out (topmost; alpha = blind intensity)
var _arc_pool: Array[Control] = []
var _prompt_label: Label          # placeholder interaction hook
var _hitmarker: _Hitmarker        # brief crosshair flash when your shot lands
# DBNO downed screen
var _downed_root: Control
var _downed_timer: Label
var _downed_friendly: Label
var _downed_giveup_fill: ColorRect
var _perf_label: Label            # debug perf overlay (FPS / frame-time / draw calls)
var _perf_accum: float = 0.0      # throttle perf-label refresh to ~4 Hz
# Per-section CPU timings (usec), written by client_main each frame; shown on the overlay.
var perf_render_us: int = 0       # WorldRenderer.update (world/entities/camera/tracers)
var perf_build_us: int = 0        # HudModel.build
var perf_hud_us: int = 0          # HudView.render (this object)
var _perf_compass_us: int = 0     # _render_compass slice of render()
# ---- new C3 elements --------------------------------------------------------
# Scoreboard overlay (TAB)
var _scoreboard_root: Control
var _scoreboard_held := false     # toggled by set_scoreboard_held(); gates visibility
# Squad roster (bottom-left)
var _squad_root: Control
var _squad_labels: Array[Label] = []
const _SQUAD_MAX := 6             # pool size; extra members silently truncated
# Interaction prompt (center-low) + revive-hold progress ring
var _interact_label: Label
var _revive_bar_bg: ColorRect
var _revive_bar_fill: ColorRect
var _revive_progress: float = 0.0  # [0,1]; set by set_revive_progress()
# Throwable selector (bottom-right, above ammo)
var _throwable_root: Control
var _throwable_labels: Array[Label] = []
const _THROWABLE_POOL := 8        # max displayed throwable slots
# Death-recap card (center, shown while deploy menu up)
var _recap_root: Control
var _recap_title: Label
var _recap_attacker_labels: Array[Label] = []

signal squad_picked(squad_id: int)   # emitted by the U squad-select overlay
var _squad_menu_root: Control
const SQUAD_MENU_COUNT := 6
const _RECAP_ATTACKER_MAX := 8

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
	var _cs := Time.get_ticks_usec()
	_render_compass(model.get("compass", {}))
	_perf_compass_us = Time.get_ticks_usec() - _cs
	_render_tickets(model.get("tickets", [0, 0]), model.get("capture"))
	_render_killfeed(model.get("killfeed", []))
	_render_damage(model.get("damage_arcs", []), float(model.get("vignette", 0.0)))
	_render_scoreboard(model.get("scoreboard", {}))
	_render_squad_roster(model.get("squad_roster", []))
	_render_interaction_prompt(model.get("interaction_prompt"))
	_render_throwables(model.get("throwables", {}))
	_render_death_recap(model.get("death_recap"))


# -----------------------------------------------------------------------
# Tree construction
# -----------------------------------------------------------------------

## Flash a hitmarker on the crosshair when your shot lands: white for a hit, red for a
## kill/down (lethal), slightly larger on a headshot. Driven by the server HITMARKER event.
func flash_hitmarker(headshot: bool, lethal: bool) -> void:
	if _hitmarker == null:
		return
	_hitmarker.flash(Color(1.0, 0.3, 0.2) if lethal else Color(1, 1, 1), headshot)


func _build_tree() -> void:
	# This control covers the full screen but ignores mouse so menus work.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = MOUSE_FILTER_IGNORE

	_build_suppression()   # first: samples only the rendered world; the HUD below draws crisp over it
	_build_crosshair()
	_hitmarker = _Hitmarker.new()
	add_child(_hitmarker)
	_build_ammo()
	_build_compass()
	_build_tickets()
	_build_killfeed()
	_build_vignette()
	_build_damage_arcs()
	_build_prompt()
	_build_downed()
	_build_squad_roster()
	_build_throwable_selector()
	_build_interaction_prompt()
	_build_death_recap()
	_build_squad_menu()
	_build_scoreboard()   # last: highest z-order so it overlays everything
	_build_perf()
	_build_blind()        # truly last: a flashbang white-out covers even the HUD/scoreboard


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
	_ammo_panel = panel

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

	_firemode_label = Label.new()
	_firemode_label.text = "AUTO"
	_firemode_label.add_theme_font_size_override("font_size", 15)
	_firemode_label.modulate = Color(0.7, 0.85, 1.0)
	_firemode_label.position = Vector2(0, -22)   # just above the ammo count
	_firemode_label.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(_firemode_label)


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

	# Container for objective markers — pooled labels, created ONCE and reused each frame.
	# (Recreating them per frame cost ~10 ms/frame: Label alloc + theme + add_child.)
	_compass_container = strip
	for i in COMPASS_MARKER_POOL:
		var dot := Label.new()
		dot.text = "▼"
		dot.add_theme_font_size_override("font_size", 12)
		dot.mouse_filter = MOUSE_FILTER_IGNORE
		dot.visible = false
		strip.add_child(dot)
		_compass_markers.append(dot)


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


## Full-screen suppression overlay (M5.5-P2). A canvas shader samples the rendered world (this is the
## first HUD child, so the screen texture holds only the 3D scene) and applies a tunnel vignette +
## desaturation + edge blur scaled by a `strength` uniform. At strength 0 it passes the screen through
## untouched (invisible). Built before the HUD readouts so they stay crisp, and before the flashbang
## white-out so a flash still covers it.
func _build_suppression() -> void:
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\n" + \
		"uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;\n" + \
		"uniform float strength : hint_range(0.0, 1.0) = 0.0;\n" + \
		"void fragment() {\n" + \
		"	vec2 uv = SCREEN_UV;\n" + \
		"	vec3 base = texture(screen_tex, uv).rgb;\n" + \
		"	if (strength <= 0.001) { COLOR = vec4(base, 1.0); }\n" + \
		"	else {\n" + \
		"		vec2 px = SCREEN_PIXEL_SIZE * (1.5 + 2.5 * strength);\n" + \
		"		vec3 b = base;\n" + \
		"		b += texture(screen_tex, uv + vec2(px.x, 0.0)).rgb;\n" + \
		"		b += texture(screen_tex, uv - vec2(px.x, 0.0)).rgb;\n" + \
		"		b += texture(screen_tex, uv + vec2(0.0, px.y)).rgb;\n" + \
		"		b += texture(screen_tex, uv - vec2(0.0, px.y)).rgb;\n" + \
		"		b /= 5.0;\n" + \
		"		float d = distance(uv, vec2(0.5)) * 1.4142;\n" + \
		"		float vig = smoothstep(0.35, 1.0, d);\n" + \
		"		vec3 col = mix(base, b, clamp(vig * strength + strength * 0.3, 0.0, 1.0));\n" + \
		"		float lum = dot(col, vec3(0.299, 0.587, 0.114));\n" + \
		"		col = mix(col, vec3(lum), strength * 0.6);\n" + \
		"		col *= 1.0 - vig * strength * 0.6;\n" + \
		"		COLOR = vec4(col, 1.0);\n" + \
		"	}\n" + \
		"}\n"
	_suppress_mat = ShaderMaterial.new()
	_suppress_mat.shader = sh
	_suppress_mat.set_shader_parameter("strength", 0.0)
	_suppress_overlay = ColorRect.new()
	_suppress_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_suppress_overlay.color = Color(1, 1, 1, 1)   # opaque; the shader replaces it with the processed screen
	_suppress_overlay.material = _suppress_mat
	_suppress_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_suppress_overlay)


## Set the suppression screen-FX strength (0..1). Safe before _ready() (lazy-inits the tree).
func set_suppression(strength: float) -> void:
	if _suppress_mat == null:
		_build_tree()
	_suppress_mat.set_shader_parameter("strength", clampf(strength, 0.0, 1.0))


func _build_blind() -> void:
	# Full-screen white overlay whose alpha encodes flashbang blind intensity (M5.5-P3). Built last
	# so it covers everything, including the HUD, when you are fully flashed.
	_blind_overlay = ColorRect.new()
	_blind_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blind_overlay.color = Color(1, 1, 1, 0.0)
	_blind_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_blind_overlay)


## Set the flashbang white-out opacity (0..1). Safe before _ready() (lazy-inits the tree).
func set_blind(intensity: float) -> void:
	if _blind_overlay == null:
		_build_tree()
	_blind_overlay.color.a = clampf(intensity, 0.0, 1.0)


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


func _build_downed() -> void:
	# DBNO overlay: red wash + bleed-out countdown + nearest-friendly + hold-to-give-up bar.
	_downed_root = Control.new()
	_downed_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_downed_root.mouse_filter = MOUSE_FILTER_IGNORE
	_downed_root.visible = false
	add_child(_downed_root)
	var wash := ColorRect.new()
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash.color = Color(0.45, 0.0, 0.0, 0.32)
	wash.mouse_filter = MOUSE_FILTER_IGNORE
	_downed_root.add_child(wash)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_downed_root.add_child(center)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vbox)
	var title := Label.new()
	title.text = "DOWNED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(1, 0.35, 0.3))
	vbox.add_child(title)
	_downed_timer = Label.new()
	_downed_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_downed_timer.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_downed_timer)
	_downed_friendly = Label.new()
	_downed_friendly.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_downed_friendly)
	var giveup := Label.new()
	giveup.text = "Hold [SPACE] to give up"
	giveup.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(giveup)
	var barbg := ColorRect.new()
	barbg.color = Color(0.15, 0.15, 0.15, 0.85)
	barbg.custom_minimum_size = Vector2(240, 12)
	vbox.add_child(barbg)
	_downed_giveup_fill = ColorRect.new()
	_downed_giveup_fill.color = Color(1.0, 0.45, 0.2)
	_downed_giveup_fill.position = Vector2.ZERO
	_downed_giveup_fill.size = Vector2(0, 12)
	_downed_giveup_fill.mouse_filter = MOUSE_FILTER_IGNORE
	barbg.add_child(_downed_giveup_fill)


## Drive the downed (DBNO) overlay. active=false hides it. secs_left = bleed-out countdown,
## nearest_dist = metres to nearest standing teammate (<0 = none), giveup = hold progress [0,1].
func set_downed(active: bool, secs_left: float, nearest_dist: float, giveup: float, being_revived: bool = false) -> void:
	if _downed_root == null:
		return
	_downed_root.visible = active
	if not active:
		return
	if being_revived:
		# A teammate is actively reviving — tell the player to hold on (don't give up).
		_downed_timer.text = "Being revived — hold on!"
		_downed_timer.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
		_downed_friendly.text = "A teammate is reviving you"
	else:
		_downed_timer.text = "Bleeding out — %d s" % int(ceil(secs_left))
		_downed_timer.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
		_downed_friendly.text = ("Nearest friendly: %d m" % int(round(nearest_dist))) if nearest_dist >= 0.0 else "No friendly nearby"
	_downed_giveup_fill.size = Vector2(240.0 * clampf(giveup, 0.0, 1.0), 12.0)


func _build_perf() -> void:
	# Debug perf overlay — top-left, just below the tickets panel. Self-updating via _process.
	_perf_label = Label.new()
	_perf_label.anchor_left = 0.0
	_perf_label.anchor_top = 0.0
	_perf_label.offset_left = 12.0
	_perf_label.offset_top = 92.0
	_perf_label.add_theme_font_size_override("font_size", 13)
	_perf_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	_perf_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_perf_label.add_theme_constant_override("outline_size", 4)
	_perf_label.text = "fps —"
	_perf_label.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_perf_label)


## Toggle the debug perf overlay (the green fps/draws/vram readout). Default on; hiding it gives a
## clean HUD for normal play / screenshots without entering free-fly photo mode (F8). Wired to F3.
func set_perf_visible(v: bool) -> void:
	if _perf_label != null:
		_perf_label.visible = v


## Show/hide the alive-only combat HUD (ammo + throwable selector). Call each frame with
## `true` only when the local player is alive and standing — hides them while downed, dead,
## or on the deploy screen.
func set_alive_hud(alive: bool) -> void:
	if _ammo_panel != null:
		_ammo_panel.visible = alive
	if _throwable_root != null:
		_throwable_root.visible = alive

## Toggle TAB scoreboard visibility. Call from client_main when the tab key is held/released.
func set_scoreboard_held(held: bool) -> void:
	_scoreboard_held = held
	if _scoreboard_root != null:
		_scoreboard_root.visible = held


## Update revive-hold progress ring/bar [0,1]. Call from client_main each frame while reviving.
## When progress is 0 (or revive stops), call with 0 to hide the bar.
func set_revive_progress(progress: float) -> void:
	_revive_progress = clampf(progress, 0.0, 1.0)


func _build_scoreboard() -> void:
	# Full-screen semi-opaque overlay. Hidden by default; shown only while TAB is held.
	_scoreboard_root = Control.new()
	_scoreboard_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scoreboard_root.mouse_filter = MOUSE_FILTER_IGNORE
	_scoreboard_root.visible = false
	add_child(_scoreboard_root)

	# Dark backdrop so the scoreboard is readable over the scene.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.6)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	_scoreboard_root.add_child(bg)

	# Center container so the two-column layout is always screen-centred.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_scoreboard_root.add_child(center)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 40)
	hbox.mouse_filter = MOUSE_FILTER_IGNORE
	center.add_child(hbox)

	# Two VBoxes — one per team. We store references so _render_scoreboard can rebuild rows.
	for _t in 2:
		var vbox := VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 4)
		vbox.mouse_filter = MOUSE_FILTER_IGNORE
		hbox.add_child(vbox)
	# (Row Labels are created dynamically in _render_scoreboard each update — scoreboard is only
	# shown on key-hold, not every frame, so dynamic creation here is fine.)


func _render_scoreboard(sb: Dictionary) -> void:
	if _scoreboard_root == null:
		return
	_scoreboard_root.visible = _scoreboard_held
	if not _scoreboard_held:
		return

	# The two VBoxes are children [1] of hbox (index 0 is the backdrop, skipped; actual layout
	# node is the CenterContainer > HBoxContainer).
	var center: CenterContainer = _scoreboard_root.get_child(1) as CenterContainer
	if center == null:
		return
	var hbox: HBoxContainer = center.get_child(0) as HBoxContainer
	if hbox == null:
		return

	var teams: Array = sb.get("teams", [])
	for t_idx in mini(teams.size(), hbox.get_child_count()):
		var team_data: Dictionary = teams[t_idx]
		var vbox: VBoxContainer = hbox.get_child(t_idx) as VBoxContainer
		if vbox == null:
			continue

		# Clear previous rows.
		for ch in vbox.get_children():
			ch.queue_free()

		# Header: "Team 0  |  120 tickets"
		var header := Label.new()
		var team_color := _owner_color(int(team_data.get("team", t_idx)))
		header.text = "Team %d  |  %d tickets" % [int(team_data.get("team", t_idx)), int(team_data.get("tickets", 0))]
		header.add_theme_font_size_override("font_size", 16)
		header.modulate = team_color
		header.mouse_filter = MOUSE_FILTER_IGNORE
		vbox.add_child(header)

		# Column header — fixed-width cells so columns align regardless of name length
		# (the default Godot font is proportional; string padding does NOT line columns up).
		vbox.add_child(_make_score_row("Name", "K", "D", "Score", 12, Color(0.8, 0.8, 0.8)))

		# Player rows.
		var rows: Array = team_data.get("rows", [])
		for rw in rows:
			var name_str := String(rw.get("name", "?"))
			if name_str.length() > 16:
				name_str = name_str.substr(0, 15) + "…"
			vbox.add_child(_make_score_row(
				name_str,
				str(int(rw.get("kills", 0))),
				str(int(rw.get("deaths", 0))),
				str(int(rw.get("score", 0))),
				13, Color(1, 1, 1)))


## One scoreboard row as fixed-width cells: name (left) + 3 right-aligned stat columns.
## Using per-cell min widths instead of string padding keeps columns aligned in the
## proportional default font, no matter how long a player's name is.
func _make_score_row(name_s: String, k_s: String, d_s: String, score_s: String,
		font_size: int, col: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = MOUSE_FILTER_IGNORE
	var cells := [
		{"t": name_s, "w": 180.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"t": k_s, "w": 44.0, "align": HORIZONTAL_ALIGNMENT_RIGHT},
		{"t": d_s, "w": 44.0, "align": HORIZONTAL_ALIGNMENT_RIGHT},
		{"t": score_s, "w": 72.0, "align": HORIZONTAL_ALIGNMENT_RIGHT},
	]
	for cell in cells:
		var lbl := Label.new()
		lbl.text = String(cell["t"])
		lbl.custom_minimum_size = Vector2(float(cell["w"]), 0.0)
		lbl.horizontal_alignment = int(cell["align"])
		lbl.add_theme_font_size_override("font_size", font_size)
		lbl.modulate = col
		lbl.mouse_filter = MOUSE_FILTER_IGNORE
		row.add_child(lbl)
	return row


## Standalone squad-select overlay toggled by U while alive. Buttons emit squad_picked(id);
## client_main sends SET_SQUAD and folds this into its menu-open (mouse-release) handling.
func _build_squad_menu() -> void:
	_squad_menu_root = Control.new()
	_squad_menu_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_squad_menu_root.visible = false
	_squad_menu_root.z_index = 90
	add_child(_squad_menu_root)
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = MOUSE_FILTER_STOP   # swallow clicks so they don't fall through to the world
	_squad_menu_root.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_squad_menu_root.add_child(center)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	center.add_child(vb)
	var title := Label.new()
	title.text = "Select Squad"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vb.add_child(title)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	for i in SQUAD_MENU_COUNT:
		var b := Button.new()
		b.text = "Squad %d" % i
		b.custom_minimum_size = Vector2(96, 44)
		b.pressed.connect(squad_picked.emit.bind(i))
		hb.add_child(b)
	var hint := Label.new()
	hint.text = "Press U to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(0.8, 0.8, 0.8)
	vb.add_child(hint)

func set_squad_menu_open(open: bool) -> void:
	if _squad_menu_root != null:
		_squad_menu_root.visible = open

func is_squad_menu_open() -> bool:
	return _squad_menu_root != null and _squad_menu_root.visible


func _build_squad_roster() -> void:
	# Bottom-left cluster, above the ammo panel area.
	_squad_root = Control.new()
	_squad_root.anchor_left = 0.0
	_squad_root.anchor_right = 0.0
	_squad_root.anchor_top = 1.0
	_squad_root.anchor_bottom = 1.0
	_squad_root.offset_left = 12.0
	_squad_root.offset_right = 220.0
	_squad_root.offset_top = -(_SQUAD_MAX * 22.0 + 90.0)
	_squad_root.offset_bottom = -90.0
	_squad_root.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_squad_root)

	for i in _SQUAD_MAX:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.position = Vector2(0, i * 22.0)
		lbl.text = ""
		lbl.visible = false
		lbl.mouse_filter = MOUSE_FILTER_IGNORE
		_squad_root.add_child(lbl)
		_squad_labels.append(lbl)


func _render_squad_roster(roster: Array) -> void:
	if _squad_root == null:
		return
	var n: int = mini(roster.size(), _SQUAD_MAX)
	for i in _SQUAD_MAX:
		var lbl: Label = _squad_labels[i]
		if i >= n:
			lbl.visible = false
			continue
		var entry: Dictionary = roster[i]
		var status: String = String(entry.get("status", "dead"))
		var col: Color
		match status:
			"alive":   col = Color(0.4, 1.0, 0.4)
			"downed":  col = Color(1.0, 0.7, 0.1)
			_:         col = Color(0.5, 0.5, 0.5)   # dead
		lbl.text = "[%s] %s" % [status.left(1).to_upper(), String(entry.get("name", "?"))]
		lbl.modulate = col
		lbl.visible = true


func _build_interaction_prompt() -> void:
	# Center-low label; replaces the old placeholder _prompt_label for action prompts.
	# The existing _prompt_label is kept (it was built earlier) but we add a richer version here.
	_interact_label = Label.new()
	_interact_label.anchor_left = 0.5
	_interact_label.anchor_top = 0.78
	_interact_label.anchor_right = 0.5
	_interact_label.offset_left = -180.0
	_interact_label.offset_right = 180.0
	_interact_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interact_label.add_theme_font_size_override("font_size", 18)
	_interact_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_interact_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_interact_label.add_theme_constant_override("outline_size", 4)
	_interact_label.text = ""
	_interact_label.visible = false
	_interact_label.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_interact_label)

	# Revive hold-progress bar — shown under the prompt when reviving.
	# NOTE: progress value must be provided by client_main via set_revive_progress().
	_revive_bar_bg = ColorRect.new()
	_revive_bar_bg.anchor_left = 0.5
	_revive_bar_bg.anchor_top = 0.78
	_revive_bar_bg.anchor_right = 0.5
	_revive_bar_bg.offset_left = -80.0
	_revive_bar_bg.offset_right = 80.0
	_revive_bar_bg.offset_top = 26.0
	_revive_bar_bg.offset_bottom = 40.0
	_revive_bar_bg.color = Color(0.15, 0.15, 0.15, 0.85)
	_revive_bar_bg.visible = false
	_revive_bar_bg.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_revive_bar_bg)

	_revive_bar_fill = ColorRect.new()
	_revive_bar_fill.position = Vector2.ZERO
	_revive_bar_fill.size = Vector2(0, 14)
	_revive_bar_fill.color = Color(0.3, 0.85, 0.4, 0.9)
	_revive_bar_fill.mouse_filter = MOUSE_FILTER_IGNORE
	_revive_bar_bg.add_child(_revive_bar_fill)


func _render_interaction_prompt(prompt) -> void:
	if _interact_label == null:
		return
	if prompt == null:
		_interact_label.visible = false
		if _revive_bar_bg != null:
			_revive_bar_bg.visible = false
		return

	var action: String = String(prompt.get("action", ""))
	match action:
		"revive":
			# The model gives a target id; the roster name resolution was done in HudModel.
			# We do NOT have the name here (model["squad_roster"] has names but not all mates are
			# in-squad). Show a generic prompt; Task 19 (client_main) can pass name via a separate
			# setter if desired.
			_interact_label.text = "Hold F to revive squadmate"
			_interact_label.visible = true
			# Revive hold-progress ring (bar) — driven by set_revive_progress() from client_main.
			if _revive_bar_bg != null:
				_revive_bar_bg.visible = _revive_progress > 0.0
				if _revive_bar_fill != null:
					var bar_w: float = _revive_bar_bg.size.x if _revive_bar_bg.size.x > 0 else 160.0
					_revive_bar_fill.size = Vector2(bar_w * _revive_progress, _revive_bar_fill.size.y if _revive_bar_fill.size.y > 0 else 14.0)
		"enter_vehicle":
			_interact_label.text = "F to enter vehicle"
			_interact_label.visible = true
			if _revive_bar_bg != null:
				_revive_bar_bg.visible = false
		_:
			_interact_label.visible = false
			if _revive_bar_bg != null:
				_revive_bar_bg.visible = false


func _build_throwable_selector() -> void:
	# Small cluster bottom-right, sitting just above the ammo panel.
	_throwable_root = Control.new()
	_throwable_root.anchor_left = 1.0
	_throwable_root.anchor_right = 1.0
	_throwable_root.anchor_top = 1.0
	_throwable_root.anchor_bottom = 1.0
	_throwable_root.offset_left = -160.0
	_throwable_root.offset_right = 0.0
	_throwable_root.offset_top = -(_THROWABLE_POOL * 22.0 + 90.0)
	_throwable_root.offset_bottom = -90.0
	_throwable_root.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_throwable_root)

	for i in _THROWABLE_POOL:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.position = Vector2(0, i * 22.0)
		lbl.text = ""
		lbl.visible = false
		lbl.mouse_filter = MOUSE_FILTER_IGNORE
		_throwable_root.add_child(lbl)
		_throwable_labels.append(lbl)


func _render_throwables(throwables: Dictionary) -> void:
	if _throwable_root == null:
		return
	var list: Array = throwables.get("list", [])
	var active_idx: int = int(throwables.get("active", 0))
	var n: int = mini(list.size(), _THROWABLE_POOL)
	for i in _THROWABLE_POOL:
		var lbl: Label = _throwable_labels[i]
		if i >= n:
			lbl.visible = false
			continue
		var slot: Dictionary = list[i]
		var kind: int = int(slot.get("kind", -1))
		var count: int = int(slot.get("count", 0))
		var kind_str: String = _THROWABLE_LABELS.get(kind, "#%d" % kind)
		lbl.text = "%s x%d" % [kind_str, count]
		if i == active_idx:
			lbl.modulate = Color(1.0, 0.9, 0.3)   # highlighted: yellow-white
			lbl.add_theme_font_size_override("font_size", 16)
		else:
			lbl.modulate = Color(0.7, 0.7, 0.7)
			lbl.add_theme_font_size_override("font_size", 14)
		lbl.visible = true


func _build_death_recap() -> void:
	# Left side, vertically centered — kept clear of the centered respawn options and the
	# top compass (earlier center/top placements overlapped both).
	_recap_root = Control.new()
	_recap_root.anchor_left = 0.0
	_recap_root.anchor_top = 0.5
	_recap_root.anchor_right = 0.0
	_recap_root.anchor_bottom = 0.5
	_recap_root.offset_left = 30.0
	_recap_root.offset_right = 380.0   # wider so the killer line has room
	_recap_root.offset_top = -(_RECAP_ATTACKER_MAX * 20.0 + 110.0) * 0.5
	_recap_root.offset_bottom = (_RECAP_ATTACKER_MAX * 20.0 + 110.0) * 0.5
	# Draw above the deploy menu (same CanvasLayer, added after hud_view) + its full-screen dim,
	# so the recap isn't hidden/darkened behind the respawn screen.
	_recap_root.z_index = 100
	_recap_root.mouse_filter = MOUSE_FILTER_IGNORE
	_recap_root.visible = false
	add_child(_recap_root)

	# Semi-transparent panel background.
	var panel_bg := ColorRect.new()
	panel_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel_bg.color = Color(0.05, 0.05, 0.05, 0.75)
	panel_bg.mouse_filter = MOUSE_FILTER_IGNORE
	_recap_root.add_child(panel_bg)

	# Title label: "Killed by X · weapon · Y m · Z HP" — word-wraps within the card so it never
	# overflows the box on long names/weapons.
	_recap_title = Label.new()
	_recap_title.anchor_left = 0.0
	_recap_title.anchor_top = 0.0
	_recap_title.anchor_right = 1.0
	_recap_title.offset_left = 8.0
	_recap_title.offset_right = -8.0
	_recap_title.offset_top = 8.0
	_recap_title.offset_bottom = 66.0
	_recap_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recap_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_recap_title.add_theme_font_size_override("font_size", 14)
	_recap_title.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
	_recap_title.mouse_filter = MOUSE_FILTER_IGNORE
	_recap_root.add_child(_recap_title)

	# Per-attacker rows.
	for i in _RECAP_ATTACKER_MAX:
		var lbl := Label.new()
		lbl.anchor_left = 0.0
		lbl.anchor_right = 1.0
		lbl.offset_top = 74.0 + i * 20.0
		lbl.offset_bottom = 92.0 + i * 20.0
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.modulate = Color(0.85, 0.85, 0.85)
		lbl.mouse_filter = MOUSE_FILTER_IGNORE
		lbl.visible = false
		_recap_root.add_child(lbl)
		_recap_attacker_labels.append(lbl)


static func _weapon_label(weapon_id: int) -> String:
	match weapon_id:
		0: return "AR"
		1: return "SMG"
		2: return "DMR"
		3: return "RPG"
		_: return "#%d" % weapon_id


func _render_death_recap(recap) -> void:
	if _recap_root == null:
		return
	if recap == null:
		_recap_root.visible = false
		return

	_recap_root.visible = true
	var weapon_str := _weapon_label(int(recap.get("weapon", -1)))
	_recap_title.text = "Killed by %s  ·  %s  ·  %d m  ·  they had %d HP" % [
		String(recap.get("killer_name", "?")),
		weapon_str,
		int(round(float(recap.get("distance", 0)))),
		int(recap.get("killer_hp", 0))]

	var attackers: Array = recap.get("attackers", [])
	var n: int = mini(attackers.size(), _RECAP_ATTACKER_MAX)
	for i in _RECAP_ATTACKER_MAX:
		var lbl: Label = _recap_attacker_labels[i]
		if i >= n:
			lbl.visible = false
			continue
		var a: Dictionary = attackers[i]
		lbl.text = "%s — %d dmg" % [String(a.get("name", "?")), int(a.get("dmg", 0))]
		lbl.visible = true


func _process(delta: float) -> void:
	# Refresh the perf overlay ~4x/sec so the numbers are readable, not a blur.
	if _perf_label == null:
		return
	if not _perf_label.visible:
		return   # hidden (F3) — skip the Performance-monitor reads entirely
	_perf_accum += delta
	if _perf_accum < 0.25:
		return
	_perf_accum = 0.0
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / fps if fps > 0 else 0.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vram_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var objs := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var vsync: String = ["off", "on", "adaptive", "mailbox"][DisplayServer.window_get_vsync_mode()]
	# CPU main-thread time per frame. If proc+phys ≈ frame_ms, we're CPU-bound (not GPU/vsync).
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_perf_label.text = "fps %d  %.1f ms  vsync:%s\ndraws %d  prims %s  vram %.0f MB  nodes %d\nproc %.1f ms  phys %.1f ms\nworld %.2f  build %.2f  hud %.2f (cmp %.2f) ms" % [
		fps, frame_ms, vsync, draws, _commafy(prims), vram_mb, objs, proc_ms, phys_ms,
		perf_render_us / 1000.0, perf_build_us / 1000.0, perf_hud_us / 1000.0, _perf_compass_us / 1000.0]


static func _commafy(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


# -----------------------------------------------------------------------
# Per-frame render helpers
# -----------------------------------------------------------------------

func _render_ammo(ammo: Dictionary) -> void:
	var mag: int = int(ammo.get("mag", 0))
	var reloading: bool = bool(ammo.get("reloading", false))
	var low: bool = bool(ammo.get("low", false))

	_ammo_label.text = ("RPG  %d" % mag) if bool(ammo.get("is_rpg", false)) else ("%d /∞" % mag)
	_ammo_label.modulate = Color(1.0, 0.4, 0.3) if low else Color(1, 1, 1)
	_reload_label.visible = reloading
	var fm: String = String(ammo.get("fire_mode", ""))
	_firemode_label.text = fm
	_firemode_label.visible = fm != ""


func _render_compass(compass: Dictionary) -> void:
	var heading_rad: float = float(compass.get("heading", 0.0))
	var heading_deg: int = int(round(rad_to_deg(heading_rad)))
	if heading_deg < 0:
		heading_deg += 360
	var cardinal: String = _cardinal(heading_deg)
	_compass_label.text = "%s %d°" % [cardinal, heading_deg]

	# Update objective markers by REUSING the pooled labels — no per-frame alloc/free.
	# (The old recreate-every-frame path cost ~10 ms/frame and capped the client at ~40 fps.)
	var markers: Array = compass.get("markers", [])
	var strip_half := COMPASS_STRIP_WIDTH * 0.5
	for i in _compass_markers.size():
		var dot: Label = _compass_markers[i]
		if i >= markers.size():
			dot.visible = false
			continue
		var m: Dictionary = markers[i]
		var rel: float = float(m.get("rel_bearing", 0.0))
		var owner: int = int(m.get("owner", -1))
		var x := (rel / PI) * strip_half + strip_half - 6.0   # centre of strip at rel=0
		dot.position = Vector2(clampf(x, 2.0, COMPASS_STRIP_WIDTH - 14.0), COMPASS_HEIGHT - 2.0)
		dot.modulate = _owner_color(owner)
		dot.visible = true


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

class _Hitmarker extends Control:
	var _until_ms: int = 0
	var _color := Color(1, 1, 1)
	var _scale := 1.0
	const TTL_MS := 180

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = MOUSE_FILTER_IGNORE

	func flash(color: Color, big: bool) -> void:
		_color = color
		_scale = 1.5 if big else 1.0
		_until_ms = Time.get_ticks_msec() + TTL_MS
		queue_redraw()

	func _process(_delta: float) -> void:
		if _until_ms != 0:
			queue_redraw()

	func _draw() -> void:
		var remaining := _until_ms - Time.get_ticks_msec()
		if remaining <= 0:
			_until_ms = 0
			return
		var a := clampf(float(remaining) / float(TTL_MS), 0.0, 1.0)
		var c := Color(_color.r, _color.g, _color.b, a)
		var ctr := size * 0.5
		var inner := 5.0 * _scale
		var outer := 11.0 * _scale
		# Four diagonal ticks around the centre — the classic hitmarker "X".
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var dir: Vector2 = d.normalized()
			draw_line(ctr + dir * inner, ctr + dir * outer, c, 2.0)


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
