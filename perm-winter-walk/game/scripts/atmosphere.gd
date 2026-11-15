extends Node3D
## Night-time winter atmosphere: sky, cold ambient light, moonlight, fog, glow (bloom).
##
## Kept in one place so the look can be tuned without touching gameplay code.

const SKY_SHADER := preload("res://shaders/night_sky.gdshader")
const NOISE_TEX := preload("res://textures/snow_noise.png")

var environment: Environment
var world_env: WorldEnvironment
var moon: DirectionalLight3D


func _ready() -> void:
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	sky_mat.set_shader_parameter("cloud_noise", NOISE_TEX)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	# Static sky (no TIME in the shader): the radiance map is rendered once, not per frame.
	sky.process_mode = Sky.PROCESS_MODE_QUALITY

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	# Cold blue ambient. Using a flat colour (not the sky) keeps it predictable.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.52, 0.7)
	env.ambient_light_energy = 0.3
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	# Light fog: depth fog that swallows the far end of streets, in a colour that
	# matches the sky's horizon so silhouettes melt into it.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.12, 0.12, 0.155)
	env.fog_light_energy = 1.0
	env.fog_density = 0.008
	env.fog_sky_affect = 0.35
	env.fog_height = 30.0
	env.fog_height_density = 0.0
	env.fog_aerial_perspective = 0.0

	# Bloom so lit windows and lamps halo in the snowy air.
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 0.6
	env.glow_hdr_scale = 2.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	for i in 7:
		env.set_glow_level(i, 0.0)
	env.set_glow_level(1, 0.6)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(3, 0.8)
	env.set_glow_level(4, 0.4)

	env.adjustment_enabled = true
	env.adjustment_saturation = 0.9
	env.adjustment_contrast = 1.05

	environment = env
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	# A pale, weak moon behind thin cloud: just enough to model the snow and roofs.
	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_color = Color(0.62, 0.72, 1.0)
	moon.light_energy = 0.22
	moon.light_specular = 0.25
	moon.shadow_enabled = false
	moon.rotation_degrees = Vector3(-38.0, -150.0, 0.0)
	moon.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(moon)
