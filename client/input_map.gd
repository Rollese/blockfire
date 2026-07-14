class_name InputMap2
extends Object
## Pure mapping from pressed action names to the InputCommand button bitmask. Kept pure so the
## mapping is unit-testable without the Input singleton (input_controller reads real Input).

const _BITS := {
	"jump": InputCommand.BTN_JUMP, "crouch": InputCommand.BTN_CROUCH,
	"prone": InputCommand.BTN_PRONE, "sprint": InputCommand.BTN_SPRINT,
	"lean_left": InputCommand.BTN_LEAN_L, "lean_right": InputCommand.BTN_LEAN_R,
	"fire": InputCommand.BTN_FIRE, "reload": InputCommand.BTN_RELOAD,
	"aim": InputCommand.BTN_AIM, "redistribute": InputCommand.BTN_REDISTRIBUTE,
}

static func buttons_from(pressed: Dictionary) -> int:
	var b := 0
	for action in _BITS:
		if pressed.get(action, false):
			b |= int(_BITS[action])
	return b
