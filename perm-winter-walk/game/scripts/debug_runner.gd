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
	if main.has_city and not main.streamer.initial_done:
		var t0 := Time.get_ticks_msec()
		await main.streamer.initial_load_done
		log_line("initial city load took %d ms" % (Time.get_ticks_msec() - t0))
	if args.has("autotest"):
		await _autotest(args)
		if args.has("touchtest"):
			await _touch_test()
		if args.has("collidetest"):
			await _collision_test()
		if args.has("buildingtest"):
			await _building_collision_test()
		if args.has("streamtest"):
			await _stream_test()
	if args.has("glowtest"):
		await _glow_test(args)
	if args.has("screenshot"):
		await _screenshot(args)
	if args.has("autotest") or args.has("screenshot") or args.has("glowtest"):
		# Stop audio and let the audio server release its playbacks before quitting.
		main.ambience.queue_free()
		main.footsteps.queue_free()
		for i in 3:
			await get_tree().process_frame
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
	log_line("audio: %d footstep sounds played (one per stride), %d footprints in the snow, wind playing=%s" % [
		main.footsteps.steps_played, main.footsteps.print_count(), main.ambience.is_playing()])
	log_line("snowfall: %d flakes, emitting=%s, box centred %.1f m above the camera" % [
		main.snowfall.amount, main.snowfall.emitting, main.snowfall.global_position.y - main.player.camera.global_position.y])
	if main.light_pool:
		log_line("real lamp lights active near the player: %d of %d" % [main.light_pool.active_count(), main.light_pool.count])

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


## Finds the nearest building wall by ray casting, stands 4 m in front of it and walks
## into it. The player must stop one capsule radius from the wall.
func _building_collision_test() -> void:
	var player: CharacterBody3D = main.player
	await get_tree().physics_frame
	var space := player.get_world_3d().direct_space_state
	var origin := player.global_position + Vector3(0, 1.0, 0)
	var best := {}
	for i in 72:
		var dir := Vector3(sin(i * TAU / 72.0), 0, cos(i * TAU / 72.0))
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 120.0)
		q.exclude = [player.get_rid()]
		var hit := space.intersect_ray(q)
		if hit and (best.is_empty() or origin.distance_to(hit["position"]) < best["d"]):
			best = {"pos": hit["position"], "normal": hit["normal"], "d": origin.distance_to(hit["position"])}
	if best.is_empty():
		log_line("building collision: no wall within 120 m of %s" % _v(origin))
		return
	var n: Vector3 = best["normal"]
	n.y = 0.0
	n = n.normalized()
	var wall: Vector3 = best["pos"]
	player.global_position = Vector3(wall.x, 0.05, wall.z) + n * 4.0
	player.set_view(atan2(n.x, n.z), 0.0)
	player.velocity = Vector3.ZERO
	for i in 3:
		await get_tree().physics_frame
	player.autopilot_move = Vector2(0, -1)
	for i in 300:
		await get_tree().physics_frame
	player.autopilot_move = Vector2.ZERO
	var gap := (player.global_position - Vector3(wall.x, player.global_position.y, wall.z)).dot(n)
	log_line("building collision: wall found %.1f m away; after walking 5 s into it the player is %.2f m from the wall (capsule radius 0.28)" % [best["d"], gap])


## Teleports 600 m away and checks that chunks stream in there and out behind.
func _stream_test() -> void:
	var player: CharacterBody3D = main.player
	var streamer: Node3D = main.streamer
	var before: Array = streamer.chunks.keys()
	var b: Rect2 = streamer.bounds
	var target := player.global_position + Vector3(600, 0, 0)
	if target.x > b.end.x - 10.0:
		target.x = player.global_position.x - 600.0
	player.global_position = target
	player.reset_physics_interpolation()
	var t0 := Time.get_ticks_msec()
	var key := "%d,%d" % [floori(target.x / streamer.chunk_size), floori(target.z / streamer.chunk_size)]
	while Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
		if streamer.chunks.has(key) and streamer.loaded_stats()["pending"] == 0:
			break
	var after: Array = streamer.chunks.keys()
	var added := after.filter(func(k): return not before.has(k)).size()
	var removed := before.filter(func(k): return not after.has(k)).size()
	log_line("streaming: moved to %s; chunk %s loaded=%s after %d ms; +%d / -%d chunks, %d resident" % [
		_v(target), key, streamer.chunks.has(key), Time.get_ticks_msec() - t0, added, removed, after.size()])
	var tm: Dictionary = streamer.timing
	var n := maxi(int(tm["count"]), 1)
	log_line("chunk cost over %d chunks: worker build avg %.1f ms (max %.1f), main-thread instantiate avg %.1f ms (max %.1f)" % [
		tm["count"], tm["build_ms_sum"] / n, tm["build_ms_max"], tm["inst_ms_sum"] / n, tm["inst_ms_max"]])


## Renders the current view with glow off and on and compares brightness around
## emissive things, to prove the bloom pass actually runs on this renderer.
func _glow_test(args: Dictionary) -> void:
	for i in 60:
		await get_tree().process_frame
	var env: Environment = main.atmosphere.environment
	var base_intensity := env.glow_intensity
	var out := String(args.get("glowtest"))
	var results := {}
	for mode: Array in [["off", false, 0.0], ["on", true, base_intensity], ["x4", true, base_intensity * 4.0]]:
		env.glow_enabled = mode[1]
		env.glow_intensity = mode[2]
		for i in 8:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if img == null or img.is_empty():
			log_line("glow test needs a real renderer")
			return
		if out != "true":
			img.save_png(out.get_basename() + "_" + mode[0] + ".png")
		var sum := 0.0
		for y in range(0, img.get_height(), 4):
			for x in range(0, img.get_width(), 4):
				sum += img.get_pixel(x, y).get_luminance()
		results[mode[0]] = sum / float((img.get_height() / 4) * (img.get_width() / 4))
	env.glow_enabled = true
	env.glow_intensity = base_intensity
	log_line("glow (msaa %d): mean luminance off %.4f, on %.4f, x4 %.4f" % [get_viewport().msaa_3d, results["off"], results["on"], results["x4"]])
	if args.has("glow-nomsaa") and get_viewport().msaa_3d != Viewport.MSAA_DISABLED:
		get_viewport().msaa_3d = Viewport.MSAA_DISABLED
		await _glow_test(args)


func _screenshot(args: Dictionary) -> void:
	var frames := int(args.get("frames", "90"))
	if args.has("shot-pitch"):
		main.player.set_view(main.player.rotation.y + deg_to_rad(float(args.get("shot-turn", "0"))),
			deg_to_rad(float(args["shot-pitch"])))
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
