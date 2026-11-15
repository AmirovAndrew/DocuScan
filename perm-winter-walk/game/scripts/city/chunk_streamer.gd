extends Node3D
## Streams map chunks in and out around a target (the player).
##
## Chunk files are listed in data/<area>/manifest.json. Loading and mesh-array
## building run on WorkerThreadPool threads (chunk_loader.gd); only node creation
## and GPU upload happen on the main thread, at most a couple of chunks per frame.
## New areas can be added to the manifest at any time (see tools/preprocess_osm.py
## --merge); nothing here assumes a fixed map size.

signal initial_load_done
signal chunk_added(key: String)
signal chunk_removed(key: String)

const Loader := preload("res://scripts/city/chunk_loader.gd")
const Props := preload("res://scripts/city/props.gd")
const SNOW_SHADER := preload("res://shaders/snow_surface.gdshader")
const FACADE_SHADER := preload("res://shaders/facade.gdshader")
const DECAL_SHADER := preload("res://shaders/road_decal.gdshader")
const CONE_SHADER := preload("res://shaders/light_cone.gdshader")
const NOISE_TEX := preload("res://textures/snow_noise.png")
const NORMAL_TEX := preload("res://textures/snow_normal.png")

const LAYER_DEFAULT := 1
const LAYER_FLAT := 2   ## ground-level surfaces: lit by the baked light map, not by real lights

@export var load_radius := 400.0
@export var unload_radius := 520.0
@export var max_instantiations_per_frame := 2

var target: Node3D
var data_dir := ""
var manifest := {}
var chunk_size := 250.0
var bounds := Rect2()
var chunks := {}        ## key -> Node3D
var lamp_heads := {}    ## key -> PackedVector4Array (x, y, z, range)
var initial_done := false

var _pending := {}      ## key -> WorkerThreadPool task id
var _results := {}      ## key -> Dictionary, filled by worker threads
var _mutex := Mutex.new()
var _check_timer := 0.0
var _initial_keys := {}
var _mats := {}


func load_manifest(dir: String) -> bool:
	var path := dir.path_join("manifest.json")
	if not FileAccess.file_exists(path):
		push_warning("No map data at %s (run tools/preprocess_osm.py)" % path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("chunks"):
		push_error("Invalid manifest %s" % path)
		return false
	manifest = parsed
	data_dir = dir
	chunk_size = float(manifest.get("chunk_size", 250.0))
	var b: Array = manifest.get("bounds", [0, 0, chunk_size, chunk_size])
	bounds = Rect2(b[0], b[1], b[2] - b[0], b[3] - b[1])
	_make_materials()
	return true


func spawn_transform() -> Dictionary:
	var s: Dictionary = manifest.get("spawn", {})
	return {"position": Vector3(float(s.get("x", 0.0)), 0.05, float(s.get("z", 0.0))),
			"yaw": deg_to_rad(float(s.get("yaw_deg", 0.0)))}


## Starts loading everything around `pos`; emits initial_load_done when it is all in.
func begin_initial_load(pos: Vector3) -> void:
	for key in _wanted_keys(pos, load_radius):
		_initial_keys[key] = true
		_start(key)
	if _initial_keys.is_empty():
		_finish_initial()


func _make_materials() -> void:
	var facade := ShaderMaterial.new()
	facade.shader = FACADE_SHADER
	facade.set_shader_parameter("noise_tex", NOISE_TEX)
	_mats["facade"] = facade
	var flat := ShaderMaterial.new()
	flat.shader = SNOW_SHADER
	flat.set_shader_parameter("noise_tex", NOISE_TEX)
	flat.set_shader_parameter("normal_tex", NORMAL_TEX)
	_mats["flat"] = flat
	var roof := StandardMaterial3D.new()
	roof.albedo_color = Color(0.78, 0.81, 0.88)
	roof.roughness = 0.95
	roof.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	_mats["roof"] = roof
	var decal := ShaderMaterial.new()
	decal.shader = DECAL_SHADER
	decal.set_shader_parameter("noise_tex", NOISE_TEX)
	decal.render_priority = -1
	_mats["decal"] = decal
	var cone := ShaderMaterial.new()
	cone.shader = CONE_SHADER
	_mats["cone"] = cone


func flat_material() -> ShaderMaterial:
	return _mats["flat"]


func _process(delta: float) -> void:
	_collect_results()
	if target == null or manifest.is_empty():
		return
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_timer = 0.3
		_update_wanted(target.global_position)


func _chunk_rect(key: String) -> Rect2:
	var p := key.split(",")
	return Rect2(int(p[0]) * chunk_size, int(p[1]) * chunk_size, chunk_size, chunk_size)


func _dist_to_rect(pos: Vector3, r: Rect2) -> float:
	var dx := maxf(maxf(r.position.x - pos.x, 0.0), pos.x - r.end.x)
	var dz := maxf(maxf(r.position.y - pos.z, 0.0), pos.z - r.end.y)
	return sqrt(dx * dx + dz * dz)


func _wanted_keys(pos: Vector3, radius: float) -> Array[String]:
	var out: Array[String] = []
	for key: String in manifest["chunks"]:
		if _dist_to_rect(pos, _chunk_rect(key)) <= radius:
			out.append(key)
	return out


func _update_wanted(pos: Vector3) -> void:
	for key in _wanted_keys(pos, load_radius):
		if not chunks.has(key) and not _pending.has(key):
			_start(key)
	for key: String in chunks.keys():
		if _dist_to_rect(pos, _chunk_rect(key)) > unload_radius:
			_remove(key)


func _start(key: String) -> void:
	var path := data_dir.path_join(String(manifest["chunks"][key]))
	_pending[key] = WorkerThreadPool.add_task(_work.bind(key, path), false, "load chunk " + key)


func _work(key: String, path: String) -> void:
	var d := Loader.load_and_build(path)
	_mutex.lock()
	_results[key] = d
	_mutex.unlock()


func _collect_results() -> void:
	_mutex.lock()
	var ready: Array = _results.keys()
	_mutex.unlock()
	var budget := max_instantiations_per_frame if initial_done else 1000
	for key: String in ready:
		if budget <= 0:
			break
		WorkerThreadPool.wait_for_task_completion(_pending[key])
		_pending.erase(key)
		_mutex.lock()
		var d: Dictionary = _results[key]
		_results.erase(key)
		_mutex.unlock()
		var still_wanted := target == null or _dist_to_rect(target.global_position, _chunk_rect(key)) <= unload_radius
		if d.has("error"):
			push_error("chunk %s: %s" % [key, d["error"]])
		elif still_wanted or not initial_done:
			_instantiate(key, d)
			budget -= 1
		if _initial_keys.erase(key) and _initial_keys.is_empty():
			_finish_initial()


func _finish_initial() -> void:
	if not initial_done:
		initial_done = true
		initial_load_done.emit()


func _remove(key: String) -> void:
	var node: Node = chunks[key]
	chunks.erase(key)
	lamp_heads.erase(key)
	node.queue_free()
	chunk_removed.emit(key)


func _instantiate(key: String, d: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Chunk_" + key.replace(",", "_").replace("-", "m")
	var rect := _chunk_rect(key)
	var light_rect := Vector4(rect.position.x, rect.position.y, 1.0 / rect.size.x, 1.0 / rect.size.y)
	var light_tex: Texture2D = null
	if d.has("lmap_image"):
		light_tex = ImageTexture.create_from_image(d["lmap_image"])

	if d.has("flat_arrays"):
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, d["flat_arrays"])
		var mat: ShaderMaterial = _mats["flat"].duplicate()
		mat.set_shader_parameter("light_map", light_tex)
		mat.set_shader_parameter("light_rect", light_rect)
		var mi := _mesh_instance("Flat", m, mat)
		mi.layers = LAYER_FLAT
		root.add_child(mi)

	if d.has("wall_arrays"):
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, d["wall_arrays"], [], {}, Loader.CUSTOM0_FLAGS)
		var facade: ShaderMaterial = _mats["facade"].duplicate()
		facade.set_shader_parameter("light_map", light_tex)
		facade.set_shader_parameter("light_rect", light_rect)
		m.surface_set_material(0, facade)
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, d["roof_arrays"])
		m.surface_set_material(1, _mats["roof"])
		root.add_child(_mesh_instance("Buildings", m, null))
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(d["collision_faces"])
		var body := StaticBody3D.new()
		body.name = "Collision"
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		root.add_child(body)

	if d.has("decal_arrays"):
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, d["decal_arrays"])
		var mi := _mesh_instance("Decals", m, _mats["decal"])
		mi.layers = LAYER_FLAT
		mi.visibility_range_end = 150.0
		root.add_child(mi)

	_add_multimesh(root, "StreetLamps", Props.street_lamp_mesh(), d["lamp_street"], 320.0)
	_add_multimesh(root, "ParkLamps", Props.park_lamp_mesh(), d["lamp_park"], 220.0)
	var cones := _add_multimesh(root, "LightCones", Props.cone_mesh(), d["lamp_cones"], 260.0)
	if cones:
		cones.material_override = _mats["cone"]
	_add_multimesh(root, "BareTrees", Props.bare_tree_mesh(), d["tree_bare"], 230.0)
	_add_multimesh(root, "Spruces", Props.spruce_mesh(), d["tree_spruce"], 260.0)

	add_child(root)
	chunks[key] = root
	lamp_heads[key] = d["lamp_heads"]
	root.set_meta("buildings", int(d.get("b_count", 0)))
	chunk_added.emit(key)


func _mesh_instance(n: String, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = mesh
	if mat:
		mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _add_multimesh(root: Node3D, n: String, mesh: Mesh, xforms: Array, vis_end: float) -> MultiMeshInstance3D:
	if xforms.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = n
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = vis_end
	mmi.visibility_range_end_margin = 20.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	root.add_child(mmi)
	return mmi


## Statistics for the debug overlay and tests.
func loaded_stats() -> Dictionary:
	var b := 0
	var lamps := 0
	for key: String in chunks:
		b += int(chunks[key].get_meta("buildings", 0))
		lamps += (lamp_heads[key] as PackedVector4Array).size()
	return {"chunks": chunks.size(), "pending": _pending.size(), "buildings": b, "lamps": lamps}


## Lamp heads near a point (for the pool of real lights).
func lamps_near(pos: Vector3, radius: float) -> PackedVector4Array:
	var out := PackedVector4Array()
	var r2 := radius * radius
	for key: String in lamp_heads:
		if _dist_to_rect(pos, _chunk_rect(key)) > radius:
			continue
		for h: Vector4 in lamp_heads[key]:
			var dx := h.x - pos.x
			var dz := h.z - pos.z
			if dx * dx + dz * dz <= r2:
				out.append(h)
	return out


func _exit_tree() -> void:
	for key: String in _pending:
		WorkerThreadPool.wait_for_task_completion(_pending[key])
	_pending.clear()
