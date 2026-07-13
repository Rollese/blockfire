extends TestCase
## M16/M1: the bandage readout surfaces SELF_STATE.bandage_count (already on the wire) so the owner can
## watch the standing-bleed/bandage loop drain. Shown while holding >=1, hidden at 0 (mirrors grapple).

func test_hidden_when_out_of_bandages() -> void:
	var h := HudView.new()
	h._build_bandage_label()
	h._render_bandage({"visible": false, "count": 0})
	assert_false(h._bandage_label.visible, "0 bandages -> readout hidden")
	h.free()

func test_shows_count_when_held() -> void:
	var h := HudView.new()
	h._build_bandage_label()
	h._render_bandage({"visible": true, "count": 4})
	assert_true(h._bandage_label.visible, "holding bandages -> readout shown")
	assert_eq(h._bandage_label.text, "BANDAGES x4", "label shows the remaining count")
	h.free()

func test_render_is_safe_before_build() -> void:
	var h := HudView.new()
	h._render_bandage({"visible": true, "count": 2})   # no _build -> must no-op, not crash
	assert_true(h._bandage_label == null, "no label built yet -> render is a safe no-op")
	h.free()
