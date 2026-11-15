extends RefCounted
## Procedural low-poly meshes and shared materials for street furniture and trees.
## Built once and shared by every chunk through MultiMesh instancing.

const LAMP_STREET_HEAD := Vector3(0.0, 6.95, -1.45)  # luminaire position in lamp space
const LAMP_PARK_HEAD := Vector3(0.0, 3.95, 0.0)

static var _cache := {}


static func street_lamp_mesh() -> ArrayMesh:
	if _cache.has("street_lamp"):
		return _cache["street_lamp"]
	var metal := _Builder.new()
	metal.cylinder(Vector3(0, 0, 0), 0.14, 0.11, 0.6, 6)          # base
	metal.cylinder(Vector3(0, 0.6, 0), 0.085, 0.06, 6.55, 6)      # pole
	metal.box(Vector3(0, 7.1, -0.7), Vector3(0.07, 0.07, 1.45))   # arm
	metal.box(Vector3(0, 7.05, -1.45), Vector3(0.26, 0.13, 0.62)) # cobra head
	var bulb := _Builder.new()
	bulb.quad_down(Vector3(0, 6.98, -1.45), Vector2(0.18, 0.46))
	var mesh := ArrayMesh.new()
	metal.commit(mesh, metal_material())
	bulb.commit(mesh, bulb_material())
	_cache["street_lamp"] = mesh
	return mesh


static func park_lamp_mesh() -> ArrayMesh:
	if _cache.has("park_lamp"):
		return _cache["park_lamp"]
	var metal := _Builder.new()
	metal.cylinder(Vector3(0, 0, 0), 0.1, 0.08, 0.4, 6)
	metal.cylinder(Vector3(0, 0.4, 0), 0.055, 0.045, 3.35, 6)
	metal.box(Vector3(0, 4.27, 0), Vector3(0.36, 0.06, 0.36))     # cap
	var bulb := _Builder.new()
	bulb.box(Vector3(0, 3.98, 0), Vector3(0.3, 0.52, 0.3))        # lantern glass
	var mesh := ArrayMesh.new()
	metal.commit(mesh, metal_material())
	bulb.commit(mesh, bulb_material())
	_cache["park_lamp"] = mesh
	return mesh


## Unit cone: apex at the origin, base radius 1 at y = -1, open at the bottom.
static func cone_mesh() -> ArrayMesh:
	if _cache.has("cone"):
		return _cache["cone"]
	var b := _Builder.new()
	var sides := 14
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := Vector3(cos(a0), -1.0, sin(a0))
		var p1 := Vector3(cos(a1), -1.0, sin(a1))
		var n0 := Vector3(cos(a0), 1.0, sin(a0)).normalized()
		var n1 := Vector3(cos(a1), 1.0, sin(a1)).normalized()
		b.tri_n(Vector3.ZERO, p1, p0, (n0 + n1).normalized(), n1, n0)
	var mesh := ArrayMesh.new()
	b.commit(mesh, null)
	_cache["cone"] = mesh
	return mesh


## Bare deciduous tree (lime / birch in winter): tapered trunk and a few upturned limbs.
static func bare_tree_mesh() -> ArrayMesh:
	if _cache.has("bare_tree"):
		return _cache["bare_tree"]
	var b := _Builder.new()
	var bark := Color(0.09, 0.075, 0.065)
	var snowy := Color(0.62, 0.65, 0.72)
	b.color_up = snowy
	b.color = bark
	b.cylinder(Vector3.ZERO, 0.17, 0.09, 5.2, 5)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 7:
		var h := rng.randf_range(2.2, 4.6)
		var ang := TAU * i / 7.0 + rng.randf_range(-0.3, 0.3)
		var out := rng.randf_range(1.4, 2.6)
		var up := rng.randf_range(1.6, 3.0)
		var start := Vector3(0, h, 0)
		var end := start + Vector3(cos(ang) * out, up, sin(ang) * out)
		b.limb(start, end, 0.07, 0.025, 4)
		# one fork per limb
		var mid := start.lerp(end, 0.6)
		var fork := mid + Vector3(cos(ang + 0.9) * out * 0.45, up * 0.5, sin(ang + 0.9) * out * 0.45)
		b.limb(mid, fork, 0.035, 0.012, 3)
	b.limb(Vector3(0, 5.0, 0), Vector3(0.2, 7.0, -0.1), 0.06, 0.02, 4)
	var mesh := ArrayMesh.new()
	b.commit(mesh, tree_material())
	_cache["bare_tree"] = mesh
	return mesh


## Spruce with snow on the upper faces of its tiers.
static func spruce_mesh() -> ArrayMesh:
	if _cache.has("spruce"):
		return _cache["spruce"]
	var b := _Builder.new()
	b.color = Color(0.07, 0.05, 0.04)
	b.color_up = b.color
	b.cylinder(Vector3.ZERO, 0.15, 0.1, 1.2, 5)
	b.color = Color(0.03, 0.075, 0.05)
	b.color_up = Color(0.7, 0.74, 0.8)
	# [base height, tier height, radius]: narrow, steep tiers like a real Picea abies.
	var tiers := [[0.7, 3.4, 2.1], [2.5, 3.0, 1.7], [4.2, 2.6, 1.3], [5.7, 2.2, 0.9], [7.0, 1.8, 0.5]]
	for t: Array in tiers:
		b.cone_solid(Vector3(0, t[0], 0), t[1], t[2], 8)
	var mesh := ArrayMesh.new()
	b.commit(mesh, tree_material())
	_cache["spruce"] = mesh
	return mesh


static func metal_material() -> StandardMaterial3D:
	if not _cache.has("metal_mat"):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.16, 0.17, 0.19)
		m.roughness = 0.6
		m.metallic = 0.4
		_cache["metal_mat"] = m
	return _cache["metal_mat"]


static func bulb_material() -> StandardMaterial3D:
	if not _cache.has("bulb_mat"):
		# Shaded with a black albedo so only the emission shows; unshaded materials
		# ignore emission and would never get bright enough to bloom.
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.0, 0.0, 0.0)
		m.roughness = 1.0
		m.emission_enabled = true
		m.emission = Color(1.0, 0.74, 0.45)
		m.emission_energy_multiplier = 6.0
		_cache["bulb_mat"] = m
	return _cache["bulb_mat"]


static func tree_material() -> StandardMaterial3D:
	if not _cache.has("tree_mat"):
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 1.0
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		_cache["tree_mat"] = m
	return _cache["tree_mat"]


## Tiny flat-shaded mesh builder (one surface).
class _Builder:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var color := Color(1, 1, 1)
	var color_up := Color(1, 1, 1)  ## used on faces pointing upwards (snow)

	func _col(n: Vector3) -> Color:
		return color.lerp(color_up, smoothstep(0.35, 0.8, n.y))

	func tri(a: Vector3, b: Vector3, c: Vector3) -> void:
		var n := (c - a).cross(b - a).normalized()
		tri_n(a, b, c, n, n, n)

	func tri_n(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
		verts.append_array([a, b, c])
		norms.append_array([na, nb, nc])
		cols.append_array([_col(na), _col(nb), _col(nc)])

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
		# a-b-c-d clockwise seen from the front (Godot front faces are clockwise)
		tri(a, b, c)
		tri(a, c, d)

	func quad_down(center: Vector3, size: Vector2) -> void:
		var hx := size.x * 0.5
		var hz := size.y * 0.5
		var a := center + Vector3(-hx, 0, -hz)
		var b := center + Vector3(hx, 0, -hz)
		var c := center + Vector3(hx, 0, hz)
		var d := center + Vector3(-hx, 0, hz)
		quad(d, c, b, a)  # facing down

	func box(center: Vector3, size: Vector3) -> void:
		var h := size * 0.5
		var p := [
			center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
			center + Vector3(h.x, -h.y, h.z), center + Vector3(-h.x, -h.y, h.z),
			center + Vector3(-h.x, h.y, -h.z), center + Vector3(h.x, h.y, -h.z),
			center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z)]
		quad(p[4], p[5], p[6], p[7])  # top
		quad(p[3], p[2], p[1], p[0])  # bottom
		quad(p[7], p[6], p[2], p[3])  # +z
		quad(p[5], p[4], p[0], p[1])  # -z
		quad(p[6], p[5], p[1], p[2])  # +x
		quad(p[4], p[7], p[3], p[0])  # -x

	func cylinder(base: Vector3, r0: float, r1: float, h: float, sides: int) -> void:
		limb(base, base + Vector3(0, h, 0), r0, r1, sides)

	func limb(a: Vector3, b: Vector3, r0: float, r1: float, sides: int) -> void:
		var axis := (b - a).normalized()
		var side := axis.cross(Vector3.FORWARD if absf(axis.y) > 0.9 else Vector3.UP).normalized()
		var side2 := axis.cross(side)
		for i in sides:
			var a0 := TAU * i / sides
			var a1 := TAU * (i + 1) / sides
			var d0 := side * cos(a0) + side2 * sin(a0)
			var d1 := side * cos(a1) + side2 * sin(a1)
			var p0 := a + d0 * r0
			var p1 := a + d1 * r0
			var q0 := b + d0 * r1
			var q1 := b + d1 * r1
			var n0 := d0
			var n1 := d1
			tri_n(p0, q0, q1, n0, n0, n1)
			tri_n(p0, q1, p1, n0, n1, n1)
		# fix winding so faces point outwards
		var start := verts.size() - sides * 6
		for i in range(start, verts.size(), 3):
			var face_n := (verts[i + 2] - verts[i]).cross(verts[i + 1] - verts[i])
			if face_n.dot(norms[i]) < 0.0:
				var t := verts[i + 1]
				verts[i + 1] = verts[i + 2]
				verts[i + 2] = t
				var tn := norms[i + 1]
				norms[i + 1] = norms[i + 2]
				norms[i + 2] = tn
				var tc := cols[i + 1]
				cols[i + 1] = cols[i + 2]
				cols[i + 2] = tc

	func cone_solid(base: Vector3, h: float, r: float, sides: int) -> void:
		var apex := base + Vector3(0, h, 0)
		for i in sides:
			var a0 := TAU * i / sides
			var a1 := TAU * (i + 1) / sides
			var p0 := base + Vector3(cos(a0) * r, 0, sin(a0) * r)
			var p1 := base + Vector3(cos(a1) * r, 0, sin(a1) * r)
			var n := (p1 - apex).cross(p0 - apex).normalized()
			if n.y < 0.0:
				n = -n
			tri_n(apex, p0, p1, n, n, n)
			var nb := Vector3.DOWN
			tri_n(base, p1, p0, nb, nb, nb)

	func commit(mesh: ArrayMesh, mat: Material) -> void:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_COLOR] = cols
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if mat:
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
