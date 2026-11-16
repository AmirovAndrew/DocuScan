extends RefCounted
## Small procedural modelling kit for hand-built landmark models.
##
## All geometry goes into one surface (one draw call) with one material
## (landmark.gdshader). Vertex data:
##   COLOR.rgb = base colour of the element, COLOR.a = element id (0..1, random states)
##   UV        = local metres on the surface (patterns) or 0..1 across glass
##   UV2.x     = kind (see the K_* constants), UV2.y = local height in metres

enum { K_STUCCO, K_RUSTIC, K_TRIM, K_STONE, K_ROOF, K_GLASS, K_DOOR, K_RELIEF, K_METAL }

var v := PackedVector3Array()
var n := PackedVector3Array()
var c := PackedColorArray()
var uv := PackedVector2Array()
var uv2 := PackedVector2Array()
var idx := PackedInt32Array()

var color := Color(1, 1, 1, 0)
var kind := K_STUCCO


func tri_count() -> int:
	return idx.size() / 3


## Adds a quad a-b-c-d (any winding) facing `nrm`, with UVs per corner.
func quad(a: Vector3, b: Vector3, cc: Vector3, d: Vector3, nrm: Vector3,
		ua := Vector2(0, 0), ub := Vector2(1, 0), uc := Vector2(1, 1), ud := Vector2(0, 1)) -> void:
	var base := v.size()
	v.append_array([a, b, cc, d])
	n.append_array([nrm, nrm, nrm, nrm])
	uv.append_array([ua, ub, uc, ud])
	for p in [a, b, cc, d]:
		c.append(color)
		uv2.append(Vector2(kind, p.y))
	if (cc - a).cross(b - a).dot(nrm) >= 0.0:  # Godot front faces are clockwise
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	else:
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


func tri(a: Vector3, b: Vector3, cc: Vector3, nrm: Vector3, ua := Vector2.ZERO, ub := Vector2.ZERO, uc := Vector2.ZERO) -> void:
	var base := v.size()
	v.append_array([a, b, cc])
	n.append_array([nrm, nrm, nrm])
	uv.append_array([ua, ub, uc])
	for p in [a, b, cc]:
		c.append(color)
		uv2.append(Vector2(kind, p.y))
	if (cc - a).cross(b - a).dot(nrm) >= 0.0:
		idx.append_array([base, base + 1, base + 2])
	else:
		idx.append_array([base, base + 2, base + 1])


## Axis-aligned box in model space. `skip` names faces to leave out: "x-", "x+", "y-", "y+", "z-", "z+".
func box(mn: Vector3, mx: Vector3, skip: Array = []) -> void:
	var p := [Vector3(mn.x, mn.y, mn.z), Vector3(mx.x, mn.y, mn.z), Vector3(mx.x, mn.y, mx.z), Vector3(mn.x, mn.y, mx.z),
		Vector3(mn.x, mx.y, mn.z), Vector3(mx.x, mx.y, mn.z), Vector3(mx.x, mx.y, mx.z), Vector3(mn.x, mx.y, mx.z)]
	var sx := mx.x - mn.x
	var sy := mx.y - mn.y
	var sz := mx.z - mn.z
	if not skip.has("y+"):
		quad(p[4], p[5], p[6], p[7], Vector3.UP, Vector2(mn.x, mn.z), Vector2(mx.x, mn.z), Vector2(mx.x, mx.z), Vector2(mn.x, mx.z))
	if not skip.has("y-"):
		quad(p[0], p[1], p[2], p[3], Vector3.DOWN, Vector2(mn.x, mn.z), Vector2(mx.x, mn.z), Vector2(mx.x, mx.z), Vector2(mn.x, mx.z))
	if not skip.has("z-"):
		quad(p[0], p[1], p[5], p[4], Vector3.FORWARD, Vector2(mn.x, mn.y), Vector2(mx.x, mn.y), Vector2(mx.x, mx.y), Vector2(mn.x, mx.y))
	if not skip.has("z+"):
		quad(p[3], p[2], p[6], p[7], Vector3.BACK, Vector2(mn.x, mn.y), Vector2(mx.x, mn.y), Vector2(mx.x, mx.y), Vector2(mn.x, mx.y))
	if not skip.has("x-"):
		quad(p[0], p[3], p[7], p[4], Vector3.LEFT, Vector2(mn.z, mn.y), Vector2(mx.z, mn.y), Vector2(mx.z, mx.y), Vector2(mn.z, mx.y))
	if not skip.has("x+"):
		quad(p[1], p[2], p[6], p[5], Vector3.RIGHT, Vector2(mn.z, mn.y), Vector2(mx.z, mn.y), Vector2(mx.z, mx.y), Vector2(mn.z, mx.y))
	if sx < 0.0 or sy < 0.0 or sz < 0.0:
		push_warning("box with negative size")


## Vertical turned shape (column shaft, base, capital): profile = [[height, radius], ...].
func lathe(center: Vector3, profile: Array, sides: int) -> void:
	for i in profile.size() - 1:
		var h0: float = profile[i][0]
		var r0: float = profile[i][1]
		var h1: float = profile[i + 1][0]
		var r1: float = profile[i + 1][1]
		for s in sides:
			var a0 := TAU * s / sides
			var a1 := TAU * (s + 1) / sides
			var d0 := Vector3(cos(a0), 0, sin(a0))
			var d1 := Vector3(cos(a1), 0, sin(a1))
			var slope := (r0 - r1) / maxf(h1 - h0, 0.001)
			var nm := ((d0 + d1).normalized() + Vector3(0, slope, 0)).normalized()
			if absf(h1 - h0) < 1e-4:
				nm = Vector3.UP if r0 > r1 else Vector3.DOWN
			quad(center + d0 * r0 + Vector3(0, h0, 0), center + d1 * r0 + Vector3(0, h0, 0),
				center + d1 * r1 + Vector3(0, h1, 0), center + d0 * r1 + Vector3(0, h1, 0), nm,
				Vector2(float(s) / sides, h0), Vector2(float(s + 1) / sides, h0),
				Vector2(float(s + 1) / sides, h1), Vector2(float(s) / sides, h1))


func arrays() -> Array:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = v
	a[Mesh.ARRAY_NORMAL] = n
	a[Mesh.ARRAY_COLOR] = c
	a[Mesh.ARRAY_TEX_UV] = uv
	a[Mesh.ARRAY_TEX_UV2] = uv2
	a[Mesh.ARRAY_INDEX] = idx
	return a
