extends TestCase

func test_key_event_round_trip() -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_W
	var d := InputBindings.event_to_dict(ev)
	var back := InputBindings.dict_to_event(d)
	assert_true(back is InputEventKey)
	assert_eq((back as InputEventKey).physical_keycode, KEY_W)

func test_mouse_event_round_trip() -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	var d := InputBindings.event_to_dict(ev)
	var back := InputBindings.dict_to_event(d)
	assert_true(back is InputEventMouseButton)
	assert_eq((back as InputEventMouseButton).button_index, MOUSE_BUTTON_LEFT)

func test_rebindable_list_covers_movement() -> void:
	var actions: Array = []
	for entry: Dictionary in InputBindings.REBINDABLE:
		actions.append(entry["action"])
	assert_true(actions.has("move_fwd"))
	assert_true(actions.has("fire"))
