class_name InputBindings
extends Object
## Persist and apply custom key/mouse bindings on top of project.godot defaults.
## Overrides are stored in ClientSettings.bindings: action -> event dict.

const REBINDABLE: Array = [
	{"action": "move_fwd", "label": "Move forward"},
	{"action": "move_back", "label": "Move back"},
	{"action": "move_left", "label": "Move left"},
	{"action": "move_right", "label": "Move right"},
	{"action": "jump", "label": "Jump"},
	{"action": "crouch", "label": "Crouch"},
	{"action": "prone", "label": "Prone"},
	{"action": "sprint", "label": "Sprint"},
	{"action": "lean_left", "label": "Lean left"},
	{"action": "lean_right", "label": "Lean right"},
	{"action": "fire", "label": "Fire"},
	{"action": "aim", "label": "Aim down sights"},
	{"action": "reload", "label": "Reload"},
	{"action": "interact", "label": "Interact"},
	{"action": "scoreboard", "label": "Scoreboard (hold)"},
	{"action": "menu", "label": "Menu / settings"},
	{"action": "throw", "label": "Throw grenade / RPG"},
	{"action": "throwable_cycle", "label": "Cycle throwable"},
	{"action": "gadget", "label": "Gadget"},
	{"action": "fire_select", "label": "Fire mode select"},
	{"action": "melee", "label": "Melee"},
	{"action": "swap_weapon", "label": "Swap weapon"},
	{"action": "squad_menu", "label": "Squad menu"},
	{"action": "build_mode", "label": "Build mode"},
]

static func event_to_dict(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		return {"type": "key", "physical_keycode": k.physical_keycode}
	if ev is InputEventMouseButton:
		var m := ev as InputEventMouseButton
		return {"type": "mouse", "button_index": m.button_index}
	return {}

static func dict_to_event(d: Dictionary) -> InputEvent:
	var t := String(d.get("type", ""))
	if t == "key":
		var k := InputEventKey.new()
		k.physical_keycode = int(d.get("physical_keycode", 0))
		return k
	if t == "mouse":
		var m := InputEventMouseButton.new()
		m.button_index = int(d.get("button_index", 0))
		return m
	return null

static func event_label(ev: InputEvent) -> String:
	if ev == null:
		return "(none)"
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var name := OS.get_keycode_string(k.physical_keycode)
		return name if name != "" else "Key %d" % k.physical_keycode
	if ev is InputEventMouseButton:
		var m := ev as InputEventMouseButton
		match m.button_index:
			MOUSE_BUTTON_LEFT: return "Mouse Left"
			MOUSE_BUTTON_RIGHT: return "Mouse Right"
			MOUSE_BUTTON_MIDDLE: return "Mouse Middle"
			MOUSE_BUTTON_WHEEL_UP: return "Mouse Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Mouse Wheel Down"
			_: return "Mouse %d" % m.button_index
	return ev.as_text()

## Apply stored overrides onto the global InputMap. Safe headless (no-op if actions missing).
static func apply(settings: ClientSettings) -> void:
	for action in settings.bindings:
		if not InputMap.has_action(action):
			continue
		var d: Variant = settings.bindings[action]
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var ev := dict_to_event(d)
		if ev == null:
			continue
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, ev)

static func primary_event(action: String) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	var events := InputMap.action_get_events(action)
	return events[0] if events.size() > 0 else null
