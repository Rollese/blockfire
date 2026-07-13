extends TestCase
## M16/M1: the bandage readout surfaces SELF_STATE.bandage_count (already on the wire) so the owner can
## watch the standing-bleed/bandage loop drain. Shown while holding >=1, hidden at 0 (mirrors grapple).
## Round-2 (owner playtest): rendered as a graphical bandage glyph + a WHITE count number (matching the
## rest of the HUD) instead of the old generic green "BANDAGES xN" font text.

func test_hidden_when_out_of_bandages() -> void:
	var h := HudView.new()
	h._build_bandage_label()
	h._render_bandage({"visible": false, "count": 0})
	assert_false(h._bandage_row.visible, "0 bandages -> cluster hidden")
	h.free()

func test_shows_count_when_held() -> void:
	var h := HudView.new()
	h._build_bandage_label()
	h._render_bandage({"visible": true, "count": 4})
	assert_true(h._bandage_row.visible, "holding bandages -> cluster shown")
	assert_eq(h._bandage_label.text, "x4", "count label shows just the remaining count")
	assert_false(String(h._bandage_label.text).contains("BANDAGES"), "no more generic 'BANDAGES' font text")
	h.free()

func test_count_number_is_white_not_green() -> void:
	var h := HudView.new()
	h._build_bandage_label()
	var c: Color = h._bandage_label.get_theme_color("font_color")
	assert_almost_eq(c.r, 1.0, 0.01, "count number is white (r)")
	assert_almost_eq(c.g, 1.0, 0.01, "count number is white (g)")
	assert_almost_eq(c.b, 1.0, 0.01, "count number is white (b) -> not the old green")
	h.free()

func test_glyph_node_is_built() -> void:
	var h := HudView.new()
	h._build_bandage_label()
	assert_true(h._bandage_glyph != null, "a graphical bandage glyph node is built")
	assert_true(h._bandage_glyph.get_parent() == h._bandage_row, "glyph sits in the bandage cluster")
	h.free()

func test_render_is_safe_before_build() -> void:
	var h := HudView.new()
	h._render_bandage({"visible": true, "count": 2})   # no _build -> must no-op, not crash
	assert_true(h._bandage_row == null, "no cluster built yet -> render is a safe no-op")
	h.free()
