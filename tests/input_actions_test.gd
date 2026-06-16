extends TestCase
## Verifies the M7-C1 input actions are registered (project.godot [input]). These drive the
## rendered client's input_controller; a parse error in project.godot would also surface here.

const ACTIONS := [
	"move_fwd", "move_back", "move_left", "move_right",
	"jump", "crouch", "prone", "sprint", "lean_left", "lean_right",
	"fire", "aim", "reload", "interact", "scoreboard", "menu",
]

func test_all_client_actions_registered() -> void:
	for a in ACTIONS:
		assert_true(InputMap.has_action(a), "input action '%s' registered" % a)

func test_fire_is_left_mouse() -> void:
	var events := InputMap.action_get_events("fire")
	assert_true(events.size() >= 1, "fire has a bound event")
	var ev := events[0] as InputEventMouseButton
	assert_true(ev != null, "fire is a mouse button")
	assert_eq(ev.button_index, MOUSE_BUTTON_LEFT, "fire = LMB")
