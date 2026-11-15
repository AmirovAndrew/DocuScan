extends Node3D
## Entry point: builds the atmosphere, the world, the player and the UI.

const PlayerScript := preload("res://scripts/player.gd")
const TouchControlsScript := preload("res://scripts/touch_controls.gd")
const InputSetup := preload("res://scripts/input_setup.gd")
const DebugRunner := preload("res://scripts/debug_runner.gd")
const AtmosphereScript := preload("res://scripts/atmosphere.gd")
const SNOW_SHADER := preload("res://shaders/snow_surface.gdshader")
const NOISE_TEX := preload("res://textures/snow_noise.png")
const NORMAL_TEX := preload("res://textures/snow_normal.png")

var args: Dictionary = {}
var atmosphere: Node3D
var player: CharacterBody3D
var touch_controls: Control
var debug_label: Label


func _ready() -> void:
	args = parse_user_args()
	InputSetup.ensure_actions()

	atmosphere = AtmosphereScript.new()
	atmosphere.name = "Atmosphere"
	add_child(atmosphere)

	player = PlayerScript.new()
	player.name = "Player"
	add_child(player)

	_build_test_yard()
	_place_player(Vector3(0, 0.1, 0), 0.0)
	_build_ui()

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


func _place_player(pos: Vector3, yaw: float, pitch := -0.05) -> void:
	if args.has("pos"):
		var p: PackedStringArray = String(args["pos"]).split(",")
		pos = Vector3(float(p[0]), pos.y, float(p[1]))
	if args.has("yaw"):
		yaw = deg_to_rad(float(args["yaw"]))
	if args.has("pitch"):
		pitch = deg_to_rad(float(args["pitch"]))
	player.global_position = pos
	player.set_view(yaw, pitch)


func make_snow_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SNOW_SHADER
	m.set_shader_parameter("noise_tex", NOISE_TEX)
	m.set_shader_parameter("normal_tex", NORMAL_TEX)
	return m


## Fallback world used before any map data exists: a snowy field with a few blocks.
func _build_test_yard() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	ground.material_override = make_snow_material()
	add_child(ground)
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = WorldBoundaryShape3D.new()
	body.add_child(col)
	add_child(body)

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


func _set_touch_mode(on: bool) -> void:
	touch_controls.visible = on
	player.touch_mode = on


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		debug_label.visible = not debug_label.visible
	elif event.is_action_pressed("toggle_touch_ui"):
		_set_touch_mode(not touch_controls.visible)


func _process(_delta: float) -> void:
	if debug_label.visible:
		var p := player.global_position
		debug_label.text = "%d fps  |  draw calls %d  |  pos %.0f, %.0f  heading %.0f°" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			p.x, p.z, fposmod(-rad_to_deg(player.rotation.y), 360.0)]
