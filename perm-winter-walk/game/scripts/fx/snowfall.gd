extends GPUParticles3D
## Light falling snow around the camera (GPU particles, see snowfall_particles.gdshader).
## Flakes wrap around a box that follows the camera, so there is always snow.

const PROCESS_SHADER := preload("res://shaders/snowfall_particles.gdshader")
const FLAKE_SHADER := preload("res://shaders/snowflake.gdshader")
const BOX := Vector3(36.0, 20.0, 36.0)

var follow: Node3D           ## usually the camera
var streamer: Node3D         ## to borrow the light map of the chunk under the camera
var _flake_mat: ShaderMaterial
var _chunk_key := ""


func _init() -> void:
	name = "Snowfall"
	amount = 2400
	lifetime = 600.0          # flakes wrap instead of dying; this only re-seeds rarely
	explosiveness = 1.0
	local_coords = false
	fixed_fps = 30
	interpolate = true
	visibility_aabb = AABB(-BOX * 0.5 - Vector3(2, 2, 2), BOX + Vector3(4, 4, 4))
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ShaderMaterial.new()
	pm.shader = PROCESS_SHADER
	pm.set_shader_parameter("box", BOX)
	process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_flake_mat = ShaderMaterial.new()
	_flake_mat.shader = FLAKE_SHADER
	quad.material = _flake_mat
	draw_pass_1 = quad


func _process(_delta: float) -> void:
	if follow == null:
		return
	# Centre the box a little above the eyes so most flakes are in view.
	global_position = follow.global_position + Vector3(0.0, 4.0, 0.0)
	if streamer == null or not streamer.has_method("light_map_at"):
		return
	var key: String = streamer.chunk_key_at(follow.global_position)
	if key != _chunk_key:
		var lm: Array = streamer.light_map_at(follow.global_position)
		if not lm.is_empty():
			_chunk_key = key
			_flake_mat.set_shader_parameter("light_map", lm[0])
			_flake_mat.set_shader_parameter("light_rect", lm[1])
