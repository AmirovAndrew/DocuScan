extends Node
## Command-line test driver, so the game can be checked without a person at the controls.
##
## Pass options after `--` on the Godot command line:
##   --autotest            walk a scripted route, print a report, quit
##   --walk=SECONDS        how long the autotest walks forward (default 6)
##   --sprint              autotest sprints instead of walking
##   --screenshot=PATH     save a PNG after the scene settles, then quit
##   --frames=N            frames to wait before the screenshot (default 90)
##   --pos=X,Z --yaw=DEG --pitch=DEG   override the spawn point / view
##   --touch               force the touch UI on a desktop

var main: Node  # main.gd
var _lines: PackedStringArray = []


func _ready() -> void:
	var args: Dictionary = main.args
	if args.has("autotest"):
		await _autotest(args)
		if args.has("touchtest"):
			await _touch_test()
		if args.has("collidetest"):
			await _collision_test()
	if args.has("screenshot"):
		await _screenshot(args)
	if args.has("autotest") or args.has("screenshot"):
		get_tree().quit(0)


func log_line(s: String) -> void:
	print("[autotest] ", s)
	_lines.append(s)


func _autotest(args: Dictionary) -> void:
	var player: CharacterBody3D = main.player
	# Let physics settle onto the ground first.
	for i in 30:
		await get_tree().physics_frame
	var start := player.global_position
	log_line("spawn %s yaw %.1f deg, on_floor=%s" % [_v(start), rad_to_deg(player.rotation.y), player.is_on_floor()])
	if main.has_method("autotest_report"):
		main.autotest_report(self)

	var walk_s := float(args.get("walk", "6"))
	var steps_before: int = player.steps_taken
	var step_times: Array[float] = []
	var cb := func(_p: Vector3, _b: Basis, _l: bool, _s: float) -> void:
		step_times.append(Time.get_ticks_msec() / 1000.0)
	player.stepped.connect(cb)

	player.autopilot_sprint = args.has("sprint")
	player.autopilot_move = Vector2(0, -1)
	var t0 := Time.get_ticks_msec()
	var frames := 0
	var max_speed := 0.0
	while (Time.get_ticks_msec() - t0) / 1000.0 < walk_s:
		await get_tree().physics_frame
		frames += 1
		var v := player.get_real_velocity()
		max_speed = maxf(max_speed, Vector2(v.x, v.z).length())
	player.autopilot_move = Vector2.ZERO
	player.autopilot_sprint = false
	for i in 60:
		await get_tree().physics_frame
	player.stepped.disconnect(cb)

	var dist := Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
	var steps: int = player.steps_taken - steps_before
	log_line("walked %.2f m in %.1f s (top speed %.2f m/s), %d steps, end %s" % [dist, walk_s, max_speed, steps, _v(player.global_position)])
	if step_times.size() > 2:
		var span := step_times[-1] - step_times[0]
		log_line("cadence %.2f steps/s" % ((step_times.size() - 1) / maxf(span, 0.001)))
	log_line("physics frames during walk: %d, render fps now: %.0f" % [frames, Engine.get_frames_per_second()])

	# Turn around and walk back: exercises the look API used by touch / mouse.
	player.add_look(PI, 0.0)
	player.autopilot_move = Vector2(0, -1)
	for i in 90:
		await get_tree().physics_frame
	player.autopilot_move = Vector2.ZERO
	log_line("after turning 180 deg and walking 1.5 s: %s" % _v(player.global_position))


## Injects real touch events: joystick drag, look drag, sprint button tap.
func _touch_test() -> void:
	var player: CharacterBody3D = main.player
	var tc: Control = main.touch_controls
	main._set_touch_mode(true)
	await get_tree().process_frame
	var sz: Vector2 = tc.size
	var p0 := player.global_position
	var yaw0 := player.rotation.y
	# Thumb down on the left half, push "up" (forward) by the full radius.
	_touch(0, Vector2(160, sz.y - 160), true)
	_drag(0, Vector2(160, sz.y - 160 - 90))
	for i in 120:
		await get_tree().physics_frame
	var walked := Vector2(player.global_position.x - p0.x, player.global_position.z - p0.z)
	var spd := Vector2(player.get_real_velocity().x, player.get_real_velocity().z).length()
	log_line("touch joystick: moved %.2f m in 2 s, speed %.2f m/s, touch_move=%s" % [walked.length(), spd, player.touch_move])
	# Second finger on the right half: drag 200 px left -> turn left while still walking.
	_touch(1, Vector2(sz.x * 0.7, sz.y * 0.5), true)
	_drag(1, Vector2(sz.x * 0.7 - 100, sz.y * 0.5))
	_drag(1, Vector2(sz.x * 0.7 - 200, sz.y * 0.5))
	_touch(1, Vector2(sz.x * 0.7 - 200, sz.y * 0.5), false)
	log_line("touch look: yaw changed by %.1f deg (expect ~ +51.6, i.e. turned left)" % rad_to_deg(wrapf(player.rotation.y - yaw0, -PI, PI)))
	# Tap the RUN button with a second finger while the joystick is held.
	var run_pos: Vector2 = tc._sprint_center()
	_touch(2, run_pos, true)
	_touch(2, run_pos, false)
	for i in 120:
		await get_tree().physics_frame
	spd = Vector2(player.get_real_velocity().x, player.get_real_velocity().z).length()
	log_line("touch sprint toggle: touch_sprint=%s speed %.2f m/s" % [player.touch_sprint, spd])
	_touch(2, run_pos, true)
	_touch(2, run_pos, false)
	_touch(0, Vector2(160, sz.y - 250), false)
	for i in 60:
		await get_tree().physics_frame
	spd = Vector2(player.get_real_velocity().x, player.get_real_velocity().z).length()
	log_line("released joystick: speed %.2f m/s, touch_move=%s" % [spd, player.touch_move])


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = pressed
	ev.position = _to_window(pos)
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _drag(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = _to_window(pos)
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


## Real touches arrive in window pixels; the UI works in stretched viewport units.
func _to_window(viewport_pos: Vector2) -> Vector2:
	return get_viewport().get_final_transform() * viewport_pos


## Puts a wall 3 m ahead and walks into it: the player must stop at the wall.
func _collision_test() -> void:
	var player: CharacterBody3D = main.player
	var fwd := -player.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 4, 0.4)
	cs.shape = box
	wall.add_child(cs)
	main.add_child(wall)
	wall.global_position = player.global_position + fwd * 3.0 + Vector3.UP * 2.0
	wall.look_at(wall.global_position + fwd, Vector3.UP)
	for i in 5:
		await get_tree().physics_frame
	player.autopilot_move = Vector2(0, -1)
	for i in 240:
		await get_tree().physics_frame
	player.autopilot_move = Vector2.ZERO
	var d := (player.global_position - (wall.global_position - Vector3.UP * 2.0)).dot(fwd)
	log_line("collision: player stopped %.2f m in front of the wall centre plane (expect ~ -0.48)" % d)
	wall.queue_free()


func _screenshot(args: Dictionary) -> void:
	var frames := int(args.get("frames", "90"))
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	var img := tex.get_image() if tex else null
	if img == null or img.is_empty():
		print("[screenshot] no image (headless / dummy renderer?)")
		return
	var path: String = args["screenshot"]
	var err := img.save_png(path)
	print("[screenshot] saved %s (%dx%d) err=%d fps=%.1f" % [path, img.get_width(), img.get_height(), err, Engine.get_frames_per_second()])


func _v(p: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]
