extends Node3D
## Level of detail for spruces.
##
## Every chunk draws all its spruces with the simple distant mesh in one MultiMesh.
## This node picks the spruces nearest to the player, hides them in their chunk's
## MultiMesh (zero-scale transform) and draws them with the detailed mesh instead, in
## one shared MultiMesh per shape variant. So all nearby detailed trees cost one or two
## draw calls, and distant ones stay cheap. Hysteresis avoids flicker at the boundary.

const Props := preload("res://scripts/city/props.gd")
const HIDDEN := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)

@export var near_radius := 45.0
@export var leave_radius := 52.0
@export var max_near := 48
@export var update_interval := 0.25

var streamer: Node3D  ## chunk_streamer.gd
var target: Node3D

var _near: Array[MultiMesh] = []
var _active := {}  ## "chunk:index" -> [chunk key, index]
var _timer := 0.0


func _ready() -> void:
	for v in Props.SPRUCE_VARIANTS:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = Props.spruce_near_mesh(v)
		mm.instance_count = max_near
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "NearSpruces%d" % v
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_near.append(mm)
	streamer.chunk_removed.connect(_on_chunk_removed)


func _process(delta: float) -> void:
	if target == null:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = update_interval
	update_now()


func update_now() -> void:
	var p := target.global_position
	var cand: Array = []
	for key: String in streamer.chunks:
		if streamer._dist_to_rect(p, streamer._chunk_rect(key)) > leave_radius:
			continue
		var xforms: Array = streamer.chunks[key].get_meta("spruce_xforms", [])
		for i in xforms.size():
			var o: Vector3 = xforms[i].origin
			var d2 := (o.x - p.x) * (o.x - p.x) + (o.z - p.z) * (o.z - p.z)
			var id := "%s:%d" % [key, i]
			var r := leave_radius if _active.has(id) else near_radius
			if d2 < r * r:
				cand.append([d2, key, i, id])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	if cand.size() > max_near:
		cand.resize(max_near)
	var next := {}
	for c: Array in cand:
		next[c[3]] = [c[1], c[2]]
	for id: String in _active:
		if not next.has(id):
			_set_far(_active[id], false)
	for id: String in next:
		if not _active.has(id):
			_set_far(next[id], true)
	_active = next

	var counts: Array[int] = []
	counts.resize(_near.size())
	counts.fill(0)
	for id: String in _active:
		var e: Array = _active[id]
		var v: int = int(e[1]) % _near.size()
		var xf: Transform3D = streamer.chunks[e[0]].get_meta("spruce_xforms")[e[1]]
		_near[v].set_instance_transform(counts[v], xf)
		counts[v] += 1
	var box := AABB(p - Vector3(leave_radius + 4.0, 2.0, leave_radius + 4.0),
		Vector3(2.0 * leave_radius + 8.0, 20.0, 2.0 * leave_radius + 8.0))
	for v in _near.size():
		_near[v].visible_instance_count = counts[v]
		_near[v].custom_aabb = box


func _set_far(entry: Array, hidden: bool) -> void:
	var key: String = entry[0]
	if not streamer.chunks.has(key):
		return
	var root: Node = streamer.chunks[key]
	var mm: MultiMesh = root.get_meta("spruce_far_mm", null)
	if mm == null:
		return
	var i: int = entry[1]
	mm.set_instance_transform(i, HIDDEN if hidden else root.get_meta("spruce_xforms")[i])


func _on_chunk_removed(key: String) -> void:
	for id: String in _active.keys():
		if id.begins_with(key + ":"):
			_active.erase(id)


func near_count() -> int:
	return _active.size()
