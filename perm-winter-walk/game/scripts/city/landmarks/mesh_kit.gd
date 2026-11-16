extends RefCounted
## Small procedural modelling kit for hand-built landmark models.
##
## All geometry goes into one surface (one draw call) with one material
## (landmark.gdshader). Vertex data:
##   COLOR.rgb = base colour of the element, COLOR.a = element id (0..1, random states)
##   UV        = local metres on the surface (patterns) or 0..1 across glass
##   UV2.x     = kind (see the K_* constants), UV2.y = local height in metres

enum { K_STUCCO, K_RUSTIC, K_TRIM, K_STONE, K_ROOF, K_GLASS, K_DOOR, K_RELIEF, K_METAL,
	K_MARBLE, K_GLASSWALL, K_GOLD, K_LANTERN }

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
			# Normal perpendicular to the profile tangent (dr, dh): outward when the profile
			# goes up, inward when it comes down (inner wall of a basin), up on inward steps.
			var n2 := Vector2(h1 - h0, -(r1 - r0)).normalized()
			if n2.length_squared() < 1e-8:
				continue
			var nm := ((d0 + d1).normalized() * n2.x + Vector3(0, n2.y, 0)).normalized()
			quad(center + d0 * r0 + Vector3(0, h0, 0), center + d1 * r0 + Vector3(0, h0, 0),
				center + d1 * r1 + Vector3(0, h1, 0), center + d0 * r1 + Vector3(0, h1, 0), nm,
				Vector2(float(s) / sides, h0), Vector2(float(s + 1) / sides, h0),
				Vector2(float(s + 1) / sides, h1), Vector2(float(s) / sides, h1))


## Vertical wall rectangle from a to b (both at y = 0) between y0 and y1, facing nrm; UV in metres.
func wall(a: Vector3, b: Vector3, y0: float, y1: float, nrm: Vector3) -> void:
	var l := a.distance_to(b)
	quad(a + Vector3(0, y0, 0), b + Vector3(0, y0, 0), b + Vector3(0, y1, 0), a + Vector3(0, y1, 0), nrm,
		Vector2(0, y0), Vector2(l, y0), Vector2(l, y1), Vector2(0, y1))


## Stylised Soviet state emblem facing -z: wreath of ears, ribbon and star around either a
## globe (USSR) or a rising sun under a hammer and sickle (RSFSR).
## centre = middle of the motif on the wall surface (z), r = motif radius.
func emblem(centre: Vector3, r: float, rsfsr := false) -> void:
	var cx := centre.x
	var cy := centre.y
	var z := centre.z
	if rsfsr:
		_rising_sun(centre, r)
	else:
		var segs := 16
		for i in segs:
			var a0 := TAU * i / segs
			var a1 := TAU * (i + 1) / segs
			var p0 := Vector3(cx + cos(a0) * r, cy + sin(a0) * r, z)
			var p1 := Vector3(cx + cos(a1) * r, cy + sin(a1) * r, z)
			var q0 := Vector3(cx + cos(a0) * r * 0.6, cy + sin(a0) * r * 0.6, z - r * 0.23)
			var q1 := Vector3(cx + cos(a1) * r * 0.6, cy + sin(a1) * r * 0.6, z - r * 0.23)
			var mid := (Vector3(cos(a0), sin(a0), 0) + Vector3(cos(a1), sin(a1), 0)).normalized()
			quad(p0, p1, q1, q0, (mid + Vector3(0, 0, -1.2)).normalized())
			tri(q0, q1, Vector3(cx, cy, z - r * 0.32), Vector3.FORWARD)
	for side: float in [-1.0, 1.0]:
		for j in 9:
			var a := deg_to_rad(-70.0 + j * 18.0)
			var rr := r * (1.37 + 0.05 * sin(j * 1.7))
			var ex: float = cx + side * cos(a) * rr
			var ey: float = cy + sin(a) * rr
			box(Vector3(ex - r * 0.15, ey - r * 0.21, z - r * 0.21), Vector3(ex + r * 0.15, ey + r * 0.21, z), ["z+"])
	box(Vector3(cx - r * 1.16, cy - r * 1.68, z - r * 0.16), Vector3(cx + r * 1.16, cy - r * 1.32, z), ["z+"])
	var sc := Vector3(cx, cy + r * 1.8, z - r * 0.19)
	for i in 5:
		var a0 := PI * 0.5 + TAU * i / 5.0
		var tip := sc + Vector3(cos(a0), sin(a0), 0) * r * 0.44
		var in1 := sc + Vector3(cos(a0 + TAU / 10.0), sin(a0 + TAU / 10.0), 0) * r * 0.18
		var in2 := sc + Vector3(cos(a0 - TAU / 10.0), sin(a0 - TAU / 10.0), 0) * r * 0.18
		tri(sc, in2, tip, Vector3.FORWARD)
		tri(sc, tip, in1, Vector3.FORWARD)


## RSFSR motif: a half sun with rays rising from the bottom, a crossed hammer and sickle.
func _rising_sun(centre: Vector3, r: float) -> void:
	var c := centre + Vector3(0, -r * 0.55, 0)
	var segs := 10
	for i in segs:  # half disc of the sun
		var a0 := PI * i / segs
		var a1 := PI * (i + 1) / segs
		tri(c + Vector3(0, 0, -r * 0.08), c + Vector3(cos(a0), sin(a0), 0) * r * 0.42 + Vector3(0, 0, -r * 0.08),
			c + Vector3(cos(a1), sin(a1), 0) * r * 0.42 + Vector3(0, 0, -r * 0.08), Vector3.FORWARD)
	for i in 13:  # rays
		var a := PI * (i + 0.5) / 13.0
		var d := Vector3(cos(a), sin(a), 0)
		var side := Vector3(-d.y, d.x, 0)
		var r1 := r * (1.02 if i % 2 == 0 else 0.86)
		tri(c + d * r * 0.5 + side * r * 0.06 + Vector3(0, 0, -r * 0.05),
			c + d * r * 0.5 - side * r * 0.06 + Vector3(0, 0, -r * 0.05),
			c + d * r1 + Vector3(0, 0, -r * 0.05), Vector3.FORWARD)
	var m := Vector2(centre.x, centre.y + r * 0.1)
	var zf := centre.z - r * 0.14
	# hammer: handle from lower left to upper right, head across its end
	bar(m + Vector2(-0.5, -0.5) * r, m + Vector2(0.32, 0.32) * r, r * 0.1, zf, r * 0.1)
	bar(m + Vector2(0.14, 0.52) * r, m + Vector2(0.52, 0.14) * r, r * 0.17, zf - r * 0.02, r * 0.12)
	# sickle: blade arcing over the top and round to the left, handle to the lower right
	var sc := m + Vector2(-0.02, 0.06) * r
	var steps := 9
	var prev := sc + Vector2(cos(deg_to_rad(40.0)), sin(deg_to_rad(40.0))) * r * 0.5
	for i in range(1, steps + 1):
		var a := deg_to_rad(40.0 + 230.0 * i / steps)
		var p := sc + Vector2(cos(a), sin(a)) * r * 0.5
		bar(prev, p, r * (0.05 + 0.07 * i / steps), zf - r * 0.04, r * 0.08)
		prev = p
	bar(prev, prev + Vector2(0.3, -0.26) * r, r * 0.11, zf - r * 0.04, r * 0.09)


## A flat bar in the wall plane (facing -z) from a to b, w wide, standing `depth` out of z.
func bar(a: Vector2, b: Vector2, w: float, z: float, depth: float) -> void:
	var d := (b - a).normalized()
	var o := Vector2(-d.y, d.x) * w * 0.5
	var pts: Array[Vector2] = [a + o, b + o, b - o, a - o]
	var f: Array[Vector3] = []
	var bk: Array[Vector3] = []
	for p: Vector2 in pts:
		f.append(Vector3(p.x, p.y, z))
		bk.append(Vector3(p.x, p.y, z + depth))
	quad(f[0], f[1], f[2], f[3], Vector3.FORWARD)
	for i in 4:
		var j := (i + 1) % 4
		var e := pts[j] - pts[i]
		var nrm := Vector3(e.y, -e.x, 0).normalized()
		var mid := (pts[i] + pts[j]) * 0.5 - (a + b) * 0.5
		if nrm.dot(Vector3(mid.x, mid.y, 0)) < 0.0:
			nrm = -nrm
		quad(f[i], f[j], bk[j], bk[i], nrm)


## Colliders for the streamer to build (model space): boxes, ramps (stairs) and cylinders.
var colliders: Array[Dictionary] = []


func collide_box(mn: Vector3, mx: Vector3) -> void:
	colliders.append({"type": "box", "min": mn, "max": mx})


## A wedge from height 0 at z0 to height h at z1 (stairs as a walkable slope), x0..x1 wide.
func collide_ramp(x0: float, x1: float, z0: float, z1: float, y0: float, h: float) -> void:
	colliders.append({"type": "convex", "points": PackedVector3Array([
		Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x0, y0, z1), Vector3(x1, y0, z1),
		Vector3(x0, y0 + h, z1), Vector3(x1, y0 + h, z1)])})


func collide_cylinder(centre: Vector3, radius: float, height: float) -> void:
	colliders.append({"type": "cylinder", "centre": centre, "radius": radius, "height": height})


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
