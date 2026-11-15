extends RefCounted
## Registers the keyboard actions at start-up, so project.godot stays readable.

const KEYS := {
	"move_forward": [KEY_W, KEY_UP, KEY_Z],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT, KEY_Q],
	"move_right": [KEY_D, KEY_RIGHT],
	"sprint": [KEY_SHIFT],
	"toggle_debug": [KEY_F3],
	"toggle_touch_ui": [KEY_F4],
}


static func ensure_actions() -> void:
	for action: String in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for keycode: Key in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)
	# Gamepad support costs nothing: left stick moves, L3/RB sprints.
	_add_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_add_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_add_axis("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_add_axis("move_back", JOY_AXIS_LEFT_Y, 1.0)
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_LEFT_STICK
	InputMap.action_add_event("sprint", b)


static func _add_axis(action: String, axis: JoyAxis, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)
