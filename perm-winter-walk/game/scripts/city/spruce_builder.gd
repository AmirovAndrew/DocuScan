extends RefCounted
## Procedural Norway spruce (Picea abies) with snow.
##
## The tree is a tapered trunk carrying whorls of branches placed by the golden angle.
## Each branch is a drooping "frond": its centre line rises a little, sags, then turns
## its tip up again (typical of the lower branches of a Norway spruce); its section is
## a tent, because the side branchlets hang down. Upper branches point upwards. The
## top and underside have separate vertices, so the smooth top normals are not bent by
## the underside.
##
## Vertex data used by spruce.gdshader:
##   COLOR.rgb = per-branch tint (around 1.0), COLOR.a = snow cover (0..1)
##   UV        = metres across / along the branch (needle texture)
##   UV2.x     = 1 on the trunk (bark), 0 on foliage; UV2.y = 0..1 along the branch (sway)

const HEIGHT := 9.5
const RADIUS := 2.5

var _v := PackedVector3Array()
var _n := PackedVector3Array()
var _c := PackedColorArray()
var _uv := PackedVector2Array()
var _uv2 := PackedVector2Array()
var _i := PackedInt32Array()
# Fringe: hanging twig cards along the branch edges (near mesh only), alpha-tested.
var _fv := PackedVector3Array()
var _fn := PackedVector3Array()
var _fc := PackedColorArray()
var _fuv := PackedVector2Array()
var _fuv2 := PackedVector2Array()
var _fi := PackedInt32Array()
var _with_fringe := false
var _rng := RandomNumberGenerator.new()


## detail 0: near mesh (~2.3k triangles); detail 1: distant mesh (~300 triangles).
## variant changes the random shape and how low the branches start.
## Use a fresh builder per mesh: SpruceBuilder.new().make(...)
func make(detail: int, variant: int, material: Material, fringe_material: Material = null) -> ArrayMesh:
	_rng.seed = 7919 * (variant + 1) + 31 * detail
	var near := detail == 0
	_with_fringe = near
	var segs := 4 if near else 2
	_trunk(near)
	var first_whorl := 0.3 if variant % 2 == 0 else 1.1   # park trees often lose their lowest branches
	var y := first_whorl
	var whorl := 0
	while y < HEIGHT - 0.6:
		var t := (y - first_whorl) / (HEIGHT - first_whorl)
		var count := int(round(lerpf(6.0, 3.0, t))) if near else int(round(lerpf(6.0, 4.0, t)))
		var base_angle := whorl * 2.39996 + _rng.randf_range(-0.2, 0.2)
		var crown := RADIUS * pow(1.0 - t, 0.85)
		for k in count:
			if near and t < 0.85 and _rng.randf() < 0.1:
				continue  # a missing branch breaks the too-perfect outline
			var ang := base_angle + TAU * k / count + _rng.randf_range(-0.3, 0.3)
			var length := crown * _rng.randf_range(0.75, 1.2) + 0.3
			var droop := lerpf(1.15, -0.5, pow(t, 0.75)) * _rng.randf_range(0.8, 1.2)
			_frond(Vector3(0, y + _rng.randf_range(-0.1, 0.1), 0), ang, length, droop, segs)
		var step := (_rng.randf_range(0.34, 0.58) if near else 0.9) * (1.0 - 0.35 * t)
		if near and t < 0.8:
			# Short branches between the whorls fill the gaps, as on a real tree.
			for k in _rng.randi_range(1, 2):
				var ang := _rng.randf_range(0.0, TAU)
				var length := crown * _rng.randf_range(0.4, 0.65) + 0.2
				_frond(Vector3(0, y + step * _rng.randf_range(0.35, 0.7), 0), ang, length,
					lerpf(0.9, 0.0, t) * _rng.randf_range(0.7, 1.1), 2)
		y += step
		whorl += 1
	# Leading shoot at the top.
	for k in 3:
		_frond(Vector3(0, HEIGHT - 0.55, 0), TAU * k / 3.0 + 0.4, 0.45, -0.9, segs)
	_spike(Vector3(0, HEIGHT - 0.7, 0), HEIGHT + 0.35, 0.05)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _v
	arrays[Mesh.ARRAY_NORMAL] = _n
	arrays[Mesh.ARRAY_COLOR] = _c
	arrays[Mesh.ARRAY_TEX_UV] = _uv
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2
	arrays[Mesh.ARRAY_INDEX] = _i
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	if _with_fringe and not _fi.is_empty():
		var fa := []
		fa.resize(Mesh.ARRAY_MAX)
		fa[Mesh.ARRAY_VERTEX] = _fv
		fa[Mesh.ARRAY_NORMAL] = _fn
		fa[Mesh.ARRAY_COLOR] = _fc
		fa[Mesh.ARRAY_TEX_UV] = _fuv
		fa[Mesh.ARRAY_TEX_UV2] = _fuv2
		fa[Mesh.ARRAY_INDEX] = _fi
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fa)
		mesh.surface_set_material(1, fringe_material)
	return mesh


func triangle_count() -> int:
	return (_i.size() + _fi.size()) / 3


func _add(p: Vector3, uv: Vector2, col: Color, uv2: Vector2) -> int:
	_v.append(p)
	_n.append(Vector3.ZERO)
	_c.append(col)
	_uv.append(uv)
	_uv2.append(uv2)
	return _v.size() - 1


## Adds a triangle wound so that it faces `facing`, and accumulates smooth normals.
func _tri(a: int, b: int, c: int, facing: Vector3) -> void:
	var pa := _v[a]
	var fn := (_v[c] - pa).cross(_v[b] - pa)  # Godot front face: clockwise
	if fn.dot(facing) < 0.0:
		var t := b
		b = c
		c = t
		fn = -fn
	_i.append_array([a, b, c])
	_n[a] += fn
	_n[b] += fn
	_n[c] += fn


func _finish_normals(from: int) -> void:
	for k in range(from, _n.size()):
		_n[k] = _n[k].normalized() if _n[k].length_squared() > 0.0 else Vector3.UP


func _trunk(near: bool) -> void:
	var start := _v.size()
	var sides := 7 if near else 5
	var rings := 4 if near else 2
	var bark := Color(0.16, 0.11, 0.08, 0.0)
	for r in rings + 1:
		var f := float(r) / rings
		var y := HEIGHT * 0.92 * f
		var rad := lerpf(0.2, 0.03, f)
		for s in sides + 1:
			var a := TAU * s / sides
			_add(Vector3(cos(a) * rad, y, sin(a) * rad), Vector2(float(s) / sides * 0.6, y), bark, Vector2(1, 0))
	for r in rings:
		for s in sides:
			var a := start + r * (sides + 1) + s
			var b := a + 1
			var c := a + sides + 1
			var d := c + 1
			var out := Vector3(cos(TAU * (s + 0.5) / sides), 0, sin(TAU * (s + 0.5) / sides))
			_tri(a, b, d, out)
			_tri(a, d, c, out)
	_finish_normals(start)


func _spike(base: Vector3, top_y: float, r: float) -> void:
	var start := _v.size()
	var col := Color(0.55, 0.75, 0.6, 0.2)
	var tip := _add(Vector3(0, top_y, 0), Vector2(0, 0), col, Vector2(0, 1))
	var ring: Array[int] = []
	for s in 4:
		var a := TAU * s / 4.0
		ring.append(_add(base + Vector3(cos(a) * r, 0, sin(a) * r), Vector2(s * 0.1, 0.5), col, Vector2(0, 0.5)))
	for s in 4:
		var a := TAU * (s + 0.5) / 4.0
		_tri(tip, ring[s], ring[(s + 1) % 4], Vector3(cos(a), 0.3, sin(a)))
	_finish_normals(start)


func _frond(base: Vector3, ang: float, length: float, droop: float, segs: int) -> void:
	var start := _v.size()
	var dir := Vector3(cos(ang), 0.0, sin(ang))
	var side := Vector3(-dir.z, 0.0, dir.x)
	var g := _rng.randf_range(0.82, 1.18)
	var tint := Color(g * _rng.randf_range(0.9, 1.1), g, g * _rng.randf_range(0.9, 1.1), 0.0)
	var snow_amount := _rng.randf_range(0.55, 1.1)
	var top: Array[PackedInt32Array] = []
	var bottom: Array[PackedInt32Array] = []
	for k in segs + 1:
		var s := float(k) / segs
		var r := length * s
		# Rises slightly, sags to about a third of its length at 3/4, then the tip turns up.
		var dy := length * 0.12 * s
		if droop >= 0.0:
			dy += length * droop * (-2.15 * s * s + 1.85 * s * s * s)
		else:
			dy += length * -droop * 0.75 * s
		var jitter := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.05 * length * s
		var c := base + dir * r + Vector3(0, dy, 0) + jitter
		var hw := length * (0.27 * (1.0 - 0.8 * s) + 0.03) + 0.04
		var hang := hw * 0.62
		c.y = maxf(c.y, hang + 0.06)  # the lowest branches rest on the snow, not under it
		var l := c + side * hw - Vector3(0, hang, 0)
		var rr := c - side * hw - Vector3(0, hang, 0)
		var col := tint
		var sway := Vector2(0, s)
		var along := r / 0.6
		top.append(PackedInt32Array([
			_add(l, Vector2(-hw / 0.6, along), col, sway),
			_add(c, Vector2(0, along), col, sway),
			_add(rr, Vector2(hw / 0.6, along), col, sway)]))
		var under := Color(tint.r * 0.85, tint.g * 0.85, tint.b * 0.85, 0.0)
		bottom.append(PackedInt32Array([
			_add(l - Vector3(0, 0.02, 0), Vector2(-hw / 0.6, along), under, sway),
			_add(rr - Vector3(0, 0.02, 0), Vector2(hw / 0.6, along), under, sway)]))
	for k in segs:
		var a: PackedInt32Array = top[k]
		var b: PackedInt32Array = top[k + 1]
		var up_l := (Vector3.UP + side * 0.6).normalized()
		var up_r := (Vector3.UP - side * 0.6).normalized()
		_tri(a[0], a[1], b[1], up_l)
		_tri(a[0], b[1], b[0], up_l)
		_tri(a[1], a[2], b[2], up_r)
		_tri(a[1], b[2], b[1], up_r)
		var u: PackedInt32Array = bottom[k]
		var w: PackedInt32Array = bottom[k + 1]
		_tri(u[0], u[1], w[1], Vector3.DOWN)
		_tri(u[0], w[1], w[0], Vector3.DOWN)
	_finish_normals(start)
	# Snow: along the upward-facing ridge, more towards the outer part of the branch; the
	# edges stay mostly green so the outline reads as needles, not as a snow board.
	for k in segs + 1:
		var s := float(k) / segs
		var row: PackedInt32Array = top[k]
		for j in 3:
			var vi := row[j]
			var up := smoothstep(0.25, 0.85, _n[vi].y)
			var outer := 0.4 + 0.6 * s
			var ridge := 1.0 if j == 1 else 0.3
			var cc := _c[vi]
			cc.a = clampf(up * outer * ridge * snow_amount, 0.0, 1.0)
			_c[vi] = cc
	if _with_fringe:
		_fringe(top, side, tint, segs, length)


## Hanging twigs along both edges of a branch: a card strip per side, tilted outwards.
func _fringe(top: Array[PackedInt32Array], side: Vector3, tint: Color, segs: int, length: float) -> void:
	for edge in [0, 2]:
		var out := side if edge == 0 else -side
		var drop := (out * 0.45 + Vector3.DOWN).normalized()
		var base := _fv.size()
		for k in segs + 1:
			var s := float(k) / segs
			var row: PackedInt32Array = top[k]
			var e := _v[row[edge]]
			var c := _v[row[1]]
			var flen := (length * 0.16 * (1.0 - 0.6 * s) + 0.1) * _rng.randf_range(0.8, 1.2)
			var top_p := e.lerp(c, 0.12)
			var n := (out * 0.6 + Vector3.UP * 0.5).normalized()
			var u := length * s / 0.45
			var col := Color(tint.r, tint.g, tint.b, 0.0)
			for q in 2:
				var p := top_p if q == 0 else top_p + drop * flen
				_fv.append(p)
				_fn.append(n)
				_fc.append(col)
				_fuv.append(Vector2(u, float(q)))
				_fuv2.append(Vector2(0, s))
		for k in segs:
			var a := base + k * 2
			_fi.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
