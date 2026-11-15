extends Node3D
## Entry point: builds the atmosphere, the streamed city, the player and the UI.

const PlayerScript := preload("res://scripts/player.gd")
const TouchControlsScript := preload("res://scripts/touch_controls.gd")
const InputSetup := preload("res://scripts/input_setup.gd")
const DebugRunner := preload("res://scripts/debug_runner.gd")
const AtmosphereScript := preload("res://scripts/atmosphere.gd")
const StreamerScript := preload("res://scripts/city/chunk_streamer.gd")
const SNOW_SHADER := preload("res://shaders/snow_surface.gdshader")
const NOISE_TEX := preload("res://textures/snow_noise.png")
const NORMAL_TEX := preload("res://textures/snow_normal.png")

const DATA_DIR := "res://data/perm"
const BOUNDARY_MARGIN := 3.0

var args: Dictionary = {}
var atmosphere: Node3D
var player: CharacterBody3D
var streamer: Node3D
var touch_controls: Control
var debug_label: Label
var loading_overlay: ColorRect
var has_city := false


func _ready() -> void:
	args = parse_user_args()
	InputSetup.ensure_actions()

	atmosphere = AtmosphereScript.new()
	atmosphere.name = "Atmosphere"
	add_child(atmosphere)

	player = PlayerScript.new()
	player.name = "Player"
	add_child(player)

	_build_ground()
	streamer = StreamerScript.new()
	streamer.name = "City"
	add_child(streamer)
	has_city = streamer.load_manifest(String(args.get("data", DATA_DIR)))
	_build_ui()
	if has_city:
		var sp: Dictionary = streamer.spawn_transform()
		_place_player(sp["position"], sp["yaw"])
		streamer.target = player
		streamer.initial_load_done.connect(_on_city_ready, CONNECT_ONE_SHOT)
		streamer.begin_initial_load(player.global_position)
	else:
		_build_test_yard()
		_place_player(Vector3(0, 0.1, 0), 0.0)
		_on_city_ready()

	if args.has("autotest") or args.has("screenshot"):
		var runner := DebugRunner.new()
		runner.name = "DebugRunner"
		runner.main = self
		add_child(runner)


static func parse_user_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out


func _place_player(pos: Vector3, yaw: float, pitch := -0.03) -> void:
	if args.has("pos"):
		var p: PackedStringArray = String(args["pos"]).split(",")
		pos = Vector3(float(p[0]), pos.y, float(p[1]))
	if args.has("yaw"):
		yaw = deg_to_rad(float(args["yaw"]))
	if args.has("pitch"):
		pitch = deg_to_rad(float(args["pitch"]))
	player.global_position = pos
	player.set_view(yaw, pitch)
	if args.has("cam-height"):  # debug: look at the city from above
		player.eye_height = float(args["cam-height"])


func _on_city_ready() -> void:
	if loading_overlay:
		var tw := create_tween()
		tw.tween_property(loading_overlay, "modulate:a", 0.0, 0.8)
		tw.tween_callback(loading_overlay.hide)


func make_snow_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SNOW_SHADER
	m.set_shader_parameter("noise_tex", NOISE_TEX)
	m.set_shader_parameter("normal_tex", NORMAL_TEX)
	return m


## An endless snowfield under (and beyond) the streamed chunks, plus the ground collider.
func _build_ground() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Snowfield"
	var plane := PlaneMesh.new()
	plane.size = Vector2(1400, 1400)
	ground.mesh = plane
	ground.material_override = make_snow_material()
	ground.position.y = -0.03
	ground.layers = StreamerScript.LAYER_FLAT
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	set_meta("snowfield", ground)
	var body := StaticBody3D.new()
	body.name = "GroundCollider"
	var col := CollisionShape3D.new()
	col.shape = WorldBoundaryShape3D.new()
	body.add_child(col)
	add_child(body)


## Fallback world used when no map data exists: a snowy field with a few blocks.
func _build_test_yard() -> void:
	var block_mat := StandardMaterial3D.new()
	block_mat.albedo_color = Color(0.45, 0.42, 0.4)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 12:
		var size := Vector3(rng.randf_range(8, 20), rng.randf_range(6, 24), rng.randf_range(8, 20))
		var pos := Vector3(rng.randf_range(-80, 80), size.y * 0.5, rng.randf_range(-80, -15))
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		mi.material_override = block_mat
		mi.position = pos
		add_child(mi)
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		sb.position = pos
		sb.add_child(cs)
		add_child(sb)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)

	touch_controls = TouchControlsScript.new()
	touch_controls.name = "TouchControls"
	touch_controls.player = player
	layer.add_child(touch_controls)
	var touch := args.has("touch") or (DisplayServer.is_touchscreen_available() and not args.has("desktop"))
	_set_touch_mode(touch)

	debug_label = Label.new()
	debug_label.position = Vector2(12, 8)
	debug_label.add_theme_font_size_override("font_size", 16)
	debug_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	debug_label.visible = args.has("debug")
	layer.add_child(debug_label)

	# ODbL requires visible attribution of OpenStreetMap.
	var attrib := Label.new()
	attrib.text = String(streamer.manifest.get("attribution", "© OpenStreetMap contributors")) if has_city \
		else "© OpenStreetMap contributors"
	attrib.add_theme_font_size_override("font_size", 13)
	attrib.modulate = Color(1, 1, 1, 0.55)
	attrib.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT if not touch_controls.visible \
		else Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 8)
	layer.add_child(attrib)

	loading_overlay = ColorRect.new()
	loading_overlay.color = Color(0.02, 0.03, 0.06)
	loading_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vp := get_viewport().get_visible_rect().size
	loading_overlay.size = vp * 2.0  # generous: covers any aspect ratio change while loading
	var lbl := Label.new()
	lbl.text = "Пермь · загрузка…"
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.position = vp * 0.5 - Vector2(120, 20)
	loading_overlay.add_child(lbl)
	layer.add_child(loading_overlay)


func _set_touch_mode(on: bool) -> void:
	touch_controls.visible = on
	player.touch_mode = on


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		debug_label.visible = not debug_label.visible
	elif event.is_action_pressed("toggle_touch_ui"):
		_set_touch_mode(not touch_controls.visible)


func _physics_process(_delta: float) -> void:
	# Soft wall at the edge of the available map data.
	if has_city and streamer.bounds.size.x > 0.0:
		var b: Rect2 = streamer.bounds.grow(-BOUNDARY_MARGIN)
		var p := player.global_position
		var c := Vector3(clampf(p.x, b.position.x, b.end.x), p.y, clampf(p.z, b.position.y, b.end.y))
		if not c.is_equal_approx(p):
			player.global_position = c
	# Keep the endless snowfield centred under the player.
	var field: Node3D = get_meta("snowfield")
	field.global_position = Vector3(snappedf(player.global_position.x, 50.0), -0.03,
		snappedf(player.global_position.z, 50.0))


func _process(_delta: float) -> void:
	if debug_label.visible:
		var p := player.global_position
		var st: Dictionary = streamer.loaded_stats() if has_city else {}
		debug_label.text = "%d fps | draw calls %d | prims %dk | chunks %d (+%d) | buildings %d | pos %.0f, %.0f | heading %.0f°" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
			st.get("chunks", 0), st.get("pending", 0), st.get("buildings", 0),
			p.x, p.z, fposmod(-rad_to_deg(player.rotation.y), 360.0)]


## Extra checks for the command-line autotest (see debug_runner.gd).
func autotest_report(runner: Node) -> void:
	if not has_city:
		runner.log_line("no map data: running in the test yard")
		return
	var st: Dictionary = streamer.loaded_stats()
	runner.log_line("city: %d chunks loaded, %d buildings, %d lamps" % [st["chunks"], st["buildings"], st["lamps"]])
	for lm: Dictionary in streamer.manifest.get("landmarks", []):
		var to := Vector3(float(lm["x"]), 0, float(lm["z"])) - player.global_position
		to.y = 0
		var fwd := -player.global_basis.z
		fwd.y = 0
		var ang := rad_to_deg(fwd.signed_angle_to(to, Vector3.UP))
		runner.log_line("landmark '%s' is %.0f m away, %.1f deg off the view direction" % [lm["name"], to.length(), ang])
