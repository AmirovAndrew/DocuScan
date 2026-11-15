extends CharacterBody3D
## First-person walker.
##
## Desktop: WASD / arrows to move, mouse to look (click to capture, Esc to release),
## Shift to sprint. Touch input arrives through `touch_move`, `touch_sprint` and
## `add_look()` from touch_controls.gd. A right-stick gamepad also works.
##
## Emits `stepped` once per footfall, spaced by stride length, so footstep sounds and
## footprints stay in sync with the real walking speed (including sliding along walls).

signal stepped(foot_position: Vector3, foot_basis: Basis, is_left: bool, speed: float)

@export var walk_speed := 1.4          # m/s, a calm stroll
@export var sprint_speed := 3.0        # m/s, a brisk jog in snow
@export var acceleration := 5.0        # m/s^2
@export var deceleration := 8.0
@export var eye_height := 1.65
@export var mouse_sensitivity := 0.0022  # radians per screen pixel
@export var pad_look_speed := 2.2        # radians per second at full stick
@export var walk_stride := 0.72          # metres per step when walking (~1.9 steps/s)
@export var sprint_stride := 1.05
@export var bob_amount := 0.022

var touch_move := Vector2.ZERO   ## set by the virtual joystick, length <= 1
var touch_sprint := false
var autopilot_move := Vector2.ZERO  ## used by automated tests (debug_runner.gd)
var autopilot_sprint := false
var touch_mode := false

var head: Node3D
var camera: Camera3D
var steps_taken := 0

var _pitch := 0.0
var _step_distance := 0.0
var _left_foot := false
var _bob_weight := 0.0


func _init() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.28
	shape.height = 1.75
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5
	add_child(col)

	head = Node3D.new()
	head.name = "Head"
	head.position.y = eye_height
	add_child(head)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 72.0
	camera.near = 0.05
	camera.far = 460.0  # fog hides everything beyond ~400 m
	camera.current = true
	head.add_child(camera)

	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.35
	floor_constant_speed = true
	safe_margin = 0.02


func set_view(yaw: float, pitch: float) -> void:
	rotation = Vector3(0.0, yaw, 0.0)
	_pitch = clampf(pitch, deg_to_rad(-80.0), deg_to_rad(80.0))
	head.rotation.x = _pitch
	reset_physics_interpolation()


func add_look(yaw_delta: float, pitch_delta: float) -> void:
	rotate_y(-yaw_delta)
	_pitch = clampf(_pitch - pitch_delta, deg_to_rad(-80.0), deg_to_rad(80.0))
	head.rotation.x = _pitch


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var rel: Vector2 = event.screen_relative
		add_look(rel.x * mouse_sensitivity, rel.y * mouse_sensitivity)
	elif event is InputEventMouseButton and event.pressed and not touch_mode:
		if event.button_index == MOUSE_BUTTON_LEFT and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	var move := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	move = (move + touch_move + autopilot_move).limit_length(1.0)

	var pad_look := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if pad_look.length() > 0.15:
		add_look(pad_look.x * pad_look_speed * delta, pad_look.y * pad_look_speed * delta)

	var sprinting := (Input.is_action_pressed("sprint") or touch_sprint or autopilot_sprint) and move.y < 0.3
	var speed := sprint_speed if sprinting else walk_speed
	var wish := global_basis * Vector3(move.x, 0.0, move.y)
	wish.y = 0.0
	var target := wish * speed  # analog sticks give proportionally slower walking

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := acceleration if target.length() >= horizontal.length() else deceleration
	horizontal = horizontal.move_toward(target, rate * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if is_on_floor():
		velocity.y = maxf(velocity.y, -0.1)
	else:
		velocity.y -= 9.81 * delta
	move_and_slide()
	_update_steps(delta)


func _update_steps(delta: float) -> void:
	var real := get_real_velocity()
	real.y = 0.0
	var spd := real.length()
	var run_t := clampf((spd - walk_speed) / maxf(sprint_speed - walk_speed, 0.01), 0.0, 1.0)
	var stride := lerpf(walk_stride, sprint_stride, run_t)

	if spd > 0.15 and is_on_floor():
		_step_distance += spd * delta
		_bob_weight = move_toward(_bob_weight, 1.0, delta * 4.0)
		if _step_distance >= stride:
			_step_distance -= stride
			_footfall(spd)
	else:
		_bob_weight = move_toward(_bob_weight, 0.0, delta * 3.0)
		# Coming to rest mid-stride: plant the trailing foot once.
		if _step_distance > stride * 0.45 and spd <= 0.15:
			_footfall(0.6)
		_step_distance = 0.0

	var phase := _step_distance / stride
	var bob := bob_amount * (1.0 + run_t)
	head.position.y = eye_height - bob * cos(phase * TAU) * _bob_weight
	head.position.x = 0.012 * sin(phase * PI) * (1.0 if _left_foot else -1.0) * _bob_weight


func _footfall(spd: float) -> void:
	_left_foot = not _left_foot
	steps_taken += 1
	var b := global_basis
	var side := b.x * (-0.13 if _left_foot else 0.13)
	stepped.emit(global_position + side, b, _left_foot, spd)
