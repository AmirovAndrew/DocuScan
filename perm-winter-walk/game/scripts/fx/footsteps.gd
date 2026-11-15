extends Node3D
## Footstep sounds and footprints, driven by the player's `stepped` signal.
##
## Steps fire once per stride, so their rate follows the real walking speed. Each step
## picks a random sample (never the same twice in a row) with slight random pitch and
## volume; running uses heavier samples a little louder. Footprints are a ring buffer
## in one MultiMesh (one draw call), multiplied onto the snow.

const STEP_FILES := [
	"res://audio/footsteps/snow_step_00.wav", "res://audio/footsteps/snow_step_01.wav",
	"res://audio/footsteps/snow_step_02.wav", "res://audio/footsteps/snow_step_03.wav",
	"res://audio/footsteps/snow_step_04.wav", "res://audio/footsteps/snow_step_05.wav",
	"res://audio/footsteps/snow_step_06.wav", "res://audio/footsteps/snow_step_07.wav"]
const RUN_FILES := [
	"res://audio/footsteps/snow_run_00.wav", "res://audio/footsteps/snow_run_01.wav",
	"res://audio/footsteps/snow_run_02.wav", "res://audio/footsteps/snow_run_03.wav"]
const PRINT_SHADER := preload("res://shaders/footprint.gdshader")
const PRINT_TEX := preload("res://textures/footprint.png")
const MAX_PRINTS := 240
const RUN_THRESHOLD := 2.0  # m/s

@export var walk_volume_db := -7.0
@export var run_volume_db := -4.0

var player: CharacterBody3D
var steps_played := 0

var _walk: AudioStreamPlayer
var _run: AudioStreamPlayer
var _prints: MultiMesh
var _print_mat: ShaderMaterial
var _next := 0
var _clock := 0.0


func _ready() -> void:
	_walk = _make_player("Walk", STEP_FILES, walk_volume_db)
	_run = _make_player("Run", RUN_FILES, run_volume_db)

	var plane := PlaneMesh.new()
	plane.size = Vector2(0.13, 0.3)
	_print_mat = ShaderMaterial.new()
	_print_mat.shader = PRINT_SHADER
	_print_mat.set_shader_parameter("print_tex", PRINT_TEX)
	_print_mat.render_priority = 1
	plane.material = _print_mat
	_prints = MultiMesh.new()
	_prints.transform_format = MultiMesh.TRANSFORM_3D
	_prints.use_custom_data = true
	_prints.mesh = plane
	_prints.instance_count = MAX_PRINTS
	_prints.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Footprints"
	mmi.multimesh = _prints
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.layers = 2  # ground layer: not lit by real lights
	mmi.extra_cull_margin = 16384.0  # prints are spread over the whole walk
	add_child(mmi)

	player.stepped.connect(_on_step)


func _make_player(n: String, files: Array, vol: float) -> AudioStreamPlayer:
	var r := AudioStreamRandomizer.new()
	r.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS
	r.random_pitch = 1.09            # about +-9 %
	r.random_volume_offset_db = 2.5  # +-2.5 dB
	for i in files.size():
		r.add_stream(i, load(files[i]))
	var p := AudioStreamPlayer.new()
	p.name = n
	p.stream = r
	p.volume_db = vol
	p.max_polyphony = 3
	add_child(p)
	return p


func _process(delta: float) -> void:
	_clock += delta
	_print_mat.set_shader_parameter("now", _clock)


func _on_step(foot_position: Vector3, foot_basis: Basis, is_left: bool, speed: float) -> void:
	steps_played += 1
	var running := speed > RUN_THRESHOLD
	var p := _run if running else _walk
	# Slower steps land softer: scale volume a little with speed.
	var base := run_volume_db if running else walk_volume_db
	p.volume_db = base + clampf((speed - 1.4) * 1.5, -4.0, 2.0)
	p.play()
	_add_print(foot_position, foot_basis, is_left)


func _add_print(pos: Vector3, basis: Basis, is_left: bool) -> void:
	var b := basis.orthonormalized()
	b = b.rotated(Vector3.UP, randf_range(-0.12, 0.12))
	if is_left:
		b = b * Basis.from_scale(Vector3(-1, 1, 1))  # mirror for the left boot
	var xf := Transform3D(b, Vector3(pos.x, 0.035, pos.z))
	_prints.set_instance_transform(_next, xf)
	_prints.set_instance_custom_data(_next, Color(_clock, 0, 0, 0))
	_next = (_next + 1) % MAX_PRINTS
	_prints.visible_instance_count = mini(_prints.visible_instance_count + 1, MAX_PRINTS)


func print_count() -> int:
	return _prints.visible_instance_count
