extends Node3D
## A small pool of real SpotLights that follow the street lamps nearest to the player.
##
## Every lamp already lights the snow through the baked light map and glows through its
## emissive bulb and additive cone. These few real lights add what a texture cannot:
## warm light on nearby walls, trees and lamp posts. They are masked off the flat ground
## layer, so the ground is never lit twice. Lights fade out before they move, so
## reassignment never pops.

@export var count := 6
@export var search_radius := 48.0
@export var energy := 2.6
@export var fade_speed := 5.0

var streamer: Node3D  ## chunk_streamer.gd
var target: Node3D

var _lights: Array[SpotLight3D] = []
var _current: Array = []   ## Vector4 head currently lit by each light (or null)
var _wanted: Array = []
var _timer := 0.0


func _ready() -> void:
	var flat_layer: int = streamer.LAYER_FLAT
	for i in count:
		var l := SpotLight3D.new()
		l.name = "PoolLight%d" % i
		l.light_color = Color(1.0, 0.7, 0.42)
		l.light_energy = 0.0
		l.light_specular = 0.35
		l.spot_range = 17.0
		l.spot_angle = 64.0
		l.spot_attenuation = 0.9
		l.spot_angle_attenuation = 1.6
		l.shadow_enabled = false
		l.light_cull_mask = 0xFFFFF & ~flat_layer
		l.rotation_degrees = Vector3(-90, 0, 0)  # straight down
		l.visible = false
		add_child(l)
		_lights.append(l)
		_current.append(null)
		_wanted.append(null)


func _process(delta: float) -> void:
	if target == null or streamer == null:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = 0.2
		_choose(target.global_position)
	for i in count:
		var l := _lights[i]
		var want: Variant = _wanted[i]
		if _current[i] != want:
			l.light_energy = move_toward(l.light_energy, 0.0, delta * fade_speed * energy)
			if l.light_energy <= 0.0:
				_current[i] = want
				if want != null:
					var h: Vector4 = want
					l.global_position = Vector3(h.x, h.y - 0.1, h.z)
					l.spot_range = h.w + 3.0
				l.visible = want != null
		elif want != null:
			l.light_energy = move_toward(l.light_energy, energy, delta * fade_speed * energy)


func _choose(pos: Vector3) -> void:
	var heads: PackedVector4Array = streamer.lamps_near(pos, search_radius)
	var arr: Array = Array(heads)
	arr.sort_custom(func(a: Vector4, b: Vector4) -> bool:
		return Vector2(a.x - pos.x, a.z - pos.z).length_squared() < Vector2(b.x - pos.x, b.z - pos.z).length_squared())
	var chosen: Array = arr.slice(0, count)
	# Keep lights that are already on a chosen lamp; hand out the rest.
	var free: Array[int] = []
	for i in count:
		var cur: Variant = _current[i]
		if cur != null and chosen.has(cur):
			_wanted[i] = cur
			chosen.erase(cur)
		else:
			free.append(i)
	for i in free:
		_wanted[i] = chosen.pop_front() if not chosen.is_empty() else null


## Number of pool lights currently shining (for tests / the debug overlay).
func active_count() -> int:
	var n := 0
	for l in _lights:
		if l.visible and l.light_energy > 0.01:
			n += 1
	return n
