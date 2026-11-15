extends Control
## On-screen touch controls.
##
## * Left ~45 % of the screen: floating virtual joystick (appears under the thumb).
## * Rest of the screen: drag to look.
## * Round button bottom-right: sprint toggle.
##
## All touches are tracked by index, so moving and looking work at the same time.
## Everything is handled in _input() with manual hit-testing (no Control buttons),
## because Godot GUI controls only see the first touch.

const JOY_RADIUS := 80.0
const JOY_DEAD_ZONE := 0.12
const LOOK_SENSITIVITY := 0.0045  # radians per (virtual) pixel; full width ~ 330 deg
const SPRINT_RADIUS := 52.0

var player: Node  # player.gd

var _joy_index := -1
var _joy_center := Vector2.ZERO
var _joy_vec := Vector2.ZERO
var _look_index := -1
var _look_last := Vector2.ZERO
var _sprint_on := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit_viewport()
	get_viewport().size_changed.connect(_fit_viewport)
	visibility_changed.connect(queue_redraw)


func _fit_viewport() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	queue_redraw()


func _default_joy_center() -> Vector2:
	return Vector2(150.0, size.y - 150.0)


func _sprint_center() -> Vector2:
	return Vector2(size.x - 110.0, size.y - 120.0)


func _input(event: InputEvent) -> void:
	if not visible or player == null:
		return
	if event is InputEventScreenTouch:
		var pos: Vector2 = event.position
		if event.pressed:
			if pos.distance_to(_sprint_center()) <= SPRINT_RADIUS * 1.2:
				_sprint_on = not _sprint_on
				player.touch_sprint = _sprint_on
			elif pos.x < size.x * 0.45 and _joy_index == -1:
				_joy_index = event.index
				_joy_center = pos
				_set_joy(Vector2.ZERO)
			elif _look_index == -1:
				_look_index = event.index
				_look_last = pos
		else:
			if event.index == _joy_index:
				_joy_index = -1
				_set_joy(Vector2.ZERO)
			elif event.index == _look_index:
				_look_index = -1
		get_viewport().set_input_as_handled()
		queue_redraw()
	elif event is InputEventScreenDrag:
		var pos: Vector2 = event.position
		if event.index == _joy_index:
			var d := pos - _joy_center
			if d.length() > JOY_RADIUS:
				# Drag the base along so the thumb never "loses" the stick.
				_joy_center += d - d.normalized() * JOY_RADIUS
				d = d.normalized() * JOY_RADIUS
			_set_joy(d / JOY_RADIUS)
			queue_redraw()
		elif event.index == _look_index:
			var rel := pos - _look_last
			_look_last = pos
			player.add_look(rel.x * LOOK_SENSITIVITY, rel.y * LOOK_SENSITIVITY)
		get_viewport().set_input_as_handled()


func _set_joy(v: Vector2) -> void:
	_joy_vec = v
	var m := v.length()
	var shaped := Vector2.ZERO
	if m > JOY_DEAD_ZONE:
		var t := clampf((m - JOY_DEAD_ZONE) / (0.9 - JOY_DEAD_ZONE), 0.0, 1.0)
		shaped = v / m * t
	player.touch_move = shaped


func _draw() -> void:
	var active := _joy_index != -1
	var c := _joy_center if active else _default_joy_center()
	var a := 0.55 if active else 0.25
	draw_circle(c, JOY_RADIUS, Color(1, 1, 1, a * 0.25))
	draw_arc(c, JOY_RADIUS, 0.0, TAU, 48, Color(1, 1, 1, a), 2.0, true)
	draw_circle(c + _joy_vec * JOY_RADIUS, 30.0, Color(1, 1, 1, a + 0.15))

	var sc := _sprint_center()
	var fill := Color(1.0, 0.8, 0.4, 0.55) if _sprint_on else Color(1, 1, 1, 0.18)
	draw_circle(sc, SPRINT_RADIUS, fill)
	draw_arc(sc, SPRINT_RADIUS, 0.0, TAU, 40, Color(1, 1, 1, 0.6), 2.0, true)
	var font := get_theme_default_font()
	var label := "RUN"
	var fs := 22
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, sc + Vector2(-w * 0.5, fs * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.9))
