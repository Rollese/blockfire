extends TestCase
## Scoreboard render-churn regression: _render_scoreboard used to queue_free + recreate
## every row Control on EVERY render frame while TAB was held (~650 nodes/frame at 128
## players). It must rebuild only when the scoreboard content actually changes.

const HudView := preload("res://client/hud/hud_view.gd")

func _sb(tickets0 := 120, kills := 3) -> Dictionary:
	return {"teams": [
		{"team": 0, "tickets": tickets0, "rows": [
			{"name": "alpha", "kills": kills, "deaths": 1, "score": 300},
			{"name": "bravo", "kills": 0, "deaths": 2, "score": 50},
		]},
		{"team": 1, "tickets": 80, "rows": [
			{"name": "charlie", "kills": 5, "deaths": 0, "score": 500},
		]},
	]}

func _vbox(hv: Control, t: int) -> VBoxContainer:
	# _scoreboard_root: [0]=backdrop, [1]=CenterContainer > HBoxContainer > per-team VBoxes.
	return hv._scoreboard_root.get_child(1).get_child(0).get_child(t) as VBoxContainer

func test_identical_content_does_not_rebuild_rows() -> void:
	var hv: Control = HudView.new()
	hv._build_scoreboard()
	hv.set_scoreboard_held(true)
	hv._render_scoreboard(_sb())
	var vbox := _vbox(hv, 0)
	var count := vbox.get_child_count()
	assert_eq(count, 4, "header + column header + 2 player rows")
	var first := vbox.get_child(0)
	hv._render_scoreboard(_sb())   # same content, fresh dict (as HudModel produces per frame)
	assert_eq(vbox.get_child_count(), count, "no node churn while content is unchanged")
	assert_true(vbox.get_child(0) == first, "row widgets reused, not recreated")
	hv.free()

func test_changed_content_rebuilds_rows() -> void:
	var hv: Control = HudView.new()
	hv._build_scoreboard()
	hv.set_scoreboard_held(true)
	hv._render_scoreboard(_sb(120, 3))
	var vbox := _vbox(hv, 0)
	hv._render_scoreboard(_sb(110, 4))   # tickets + kills moved
	assert_eq(vbox.get_child_count(), 4, "rebuild replaces rows without leaving dying nodes behind")
	assert_true(String((vbox.get_child(0) as Label).text).contains("110"), "header reflects the new tickets")
	hv.free()
