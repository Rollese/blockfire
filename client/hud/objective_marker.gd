extends Control
## (Loaded via preload as `ObjectiveMarker` in hud_view — no class_name so it resolves in headless tests.)
## One BattleBit-style capture-point marker, anchored over a point in the world by HudView. A SQUARE
## when the point is friendly (owned by us), a DIAMOND when enemy/neutral, with the point letter + metre
## distance below. While the point is being captured a colour border fills from 12 o'clock (clockwise
## when our team is taking it, counter-clockwise when the enemy is) tinted by the attacking team.
## Presentation-only: configure()'d each frame; never reads game state itself.

const FRIEND := Color(0.28, 0.62, 1.0)   # us = blue
const ENEMY := Color(1.0, 0.36, 0.28)    # enemy = red
const NEUTRAL := Color(0.82, 0.82, 0.82) # unowned = grey
const ICON_CY := 20.0                    # icon centre y within the node (labels sit below)
const R := 12.0

var owner_team := -1
var my_team := -1
var attacker := -1
var cap := 0.0
var _letter: Label
var _dist: Label

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(54, 62)
	_letter = Label.new()
	_letter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_letter.position = Vector2(0, ICON_CY - 18.0)
	_letter.size = Vector2(54, 36)
	_letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_letter.add_theme_color_override("font_color", Color(1, 1, 1))
	_letter.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_letter.add_theme_constant_override("outline_size", 5)
	_letter.add_theme_font_size_override("font_size", 18)
	add_child(_letter)
	_dist = Label.new()
	_dist.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dist.position = Vector2(0, ICON_CY + 16.0)
	_dist.size = Vector2(54, 16)
	_dist.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dist.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	_dist.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_dist.add_theme_constant_override("outline_size", 4)
	_dist.add_theme_font_size_override("font_size", 12)
	add_child(_dist)

func configure(o_team: int, m_team: int, atk: int, c: float, letter: String, dist_m: int, alpha: float) -> void:
	owner_team = o_team
	my_team = m_team
	attacker = atk
	cap = c
	_letter.text = letter
	_dist.text = "%dm" % dist_m
	modulate.a = alpha
	queue_redraw()

func _own_color() -> Color:
	if owner_team < 0:
		return NEUTRAL
	return FRIEND if owner_team == my_team else ENEMY

func _draw() -> void:
	var c := Vector2(size.x * 0.5, ICON_CY)
	var col := _own_color()
	var friendly := owner_team >= 0 and owner_team == my_team
	if friendly:
		var hs := R * 0.95
		draw_rect(Rect2(c - Vector2(hs + 2.0, hs + 2.0), Vector2((hs + 2.0) * 2.0, (hs + 2.0) * 2.0)), Color(0, 0, 0, 0.55))
		draw_rect(Rect2(c - Vector2(hs, hs), Vector2(hs * 2.0, hs * 2.0)), col)
	else:
		var bg := PackedVector2Array([c + Vector2(0, -R - 2.0), c + Vector2(R + 2.0, 0), c + Vector2(0, R + 2.0), c + Vector2(-R - 2.0, 0)])
		draw_colored_polygon(bg, Color(0, 0, 0, 0.55))
		var dia := PackedVector2Array([c + Vector2(0, -R), c + Vector2(R, 0), c + Vector2(0, R), c + Vector2(-R, 0)])
		draw_colored_polygon(dia, col)
	# Capture-in-progress border: fills from 12 o'clock, tinted by the attacking team, clockwise when
	# our team is taking it / counter-clockwise when the enemy is.
	if attacker >= 0 and cap > 0.02 and cap < 0.98:
		var arc_col := FRIEND if attacker == my_team else ENEMY
		var start := -PI / 2.0
		var dir := 1.0 if attacker == my_team else -1.0
		draw_arc(c, R + 5.0, start, start + dir * cap * TAU, 40, arc_col, 3.5, true)
