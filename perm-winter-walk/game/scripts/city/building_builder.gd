extends RefCounted
## Builds all buildings of one chunk: walls with parapets, plinths, cornices, belt
## courses, balconies / loggias and entrance canopies, plus roofs and collision faces.
##
## Windows, doors, shop fronts and signs are drawn by facade.gdshader, which uses the
## same window grid as this file (window_pitch(), balcony / entrance rules), so the 3D
## balconies sit exactly in front of the painted balcony doors.
##
## Vertex data for facade.gdshader:
##   UV      = (metres along the wall segment, metres above ground)
##   UV2     = (levels, roof height)
##   COLOR   = (facade colour rgb, building seed)
##   CUSTOM0 = (segment length, floor height, kind (+8 if landmark), share of windows lit)
##   CUSTOM1 = (segment id, style code, part, window pitch)
##             style code = style + 8 * (balcony column offset + 3 * has balconies)

enum { B_RESIDENTIAL, B_COMMERCIAL, B_PUBLIC, B_UTILITY, B_RELIGIOUS }
enum { S_PANEL, S_HISTORIC, S_BRICK, S_MODERN, S_UTILITY, S_RELIGIOUS }
enum { P_WALL, P_TRIM, P_PLINTH, P_BALCONY, P_GLASS, P_CANOPY }

const WALL_BOTTOM := -0.3
const COLLISION_TOP := 6.0
const CUSTOM_FLAGS := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)

## Facade colours seen in central Perm, per architectural style.
const PALETTE := {
	S_PANEL: [Color(0.62, 0.62, 0.6), Color(0.66, 0.62, 0.55), Color(0.7, 0.7, 0.68), Color(0.58, 0.6, 0.63),
		Color(0.64, 0.58, 0.5), Color(0.6, 0.57, 0.52)],
	S_HISTORIC: [Color(0.68, 0.52, 0.3), Color(0.66, 0.43, 0.34), Color(0.5, 0.6, 0.5), Color(0.74, 0.68, 0.55),
		Color(0.52, 0.6, 0.68), Color(0.7, 0.52, 0.5), Color(0.76, 0.64, 0.36)],
	S_BRICK: [Color(0.45, 0.22, 0.15), Color(0.34, 0.19, 0.13), Color(0.68, 0.66, 0.6), Color(0.62, 0.6, 0.55)],
	S_MODERN: [Color(0.2, 0.24, 0.3), Color(0.55, 0.52, 0.48), Color(0.35, 0.37, 0.4), Color(0.62, 0.6, 0.56)],
	S_UTILITY: [Color(0.4, 0.4, 0.42), Color(0.42, 0.34, 0.28), Color(0.36, 0.42, 0.38)],
	S_RELIGIOUS: [Color(0.84, 0.82, 0.77), Color(0.8, 0.74, 0.62)],
}

var v := PackedVector3Array()
var n := PackedVector3Array()
var uv := PackedVector2Array()
var uv2 := PackedVector2Array()
var col := PackedColorArray()
var c0 := PackedFloat32Array()
var c1 := PackedFloat32Array()
var idx := PackedInt32Array()
var roof_v := PackedVector3Array()
var roof_n := PackedVector3Array()
var roof_i := PackedInt32Array()
var faces := PackedVector3Array()
var building_count := 0

# Per-building / per-segment state written into every vertex.
var _col := Color.WHITE
var _shape := Vector2.ZERO
var _floor_h := 3.0
var _kind_code := 0.0
var _lit := 0.0
var _style := 0
var _style_code := 0.0
var _pitch := 3.0
var _seg_id := 0.0
var _seg_len := 1.0
var _seg_counter := 0


static func style_for(kind: int, levels: float, seed: float, landmark: bool) -> int:
	var r := fmod(seed * 13.7, 1.0)
	if kind == B_RELIGIOUS:
		return S_RELIGIOUS
	if kind == B_UTILITY:
		return S_UTILITY
	if landmark:
		return S_HISTORIC
	if kind == B_COMMERCIAL:
		return S_MODERN if r < 0.7 else S_HISTORIC
	if kind == B_PUBLIC:
		return S_HISTORIC if r < 0.7 else S_MODERN
	if levels >= 9.0:
		return S_PANEL if r < 0.85 else S_MODERN
	if levels >= 5.0:
		return S_PANEL if r < 0.55 else (S_BRICK if r < 0.8 else S_HISTORIC)
	return S_HISTORIC if r < 0.55 else (S_BRICK if r < 0.9 else S_PANEL)


## Must match window_pitch() in facade.gdshader.
static func window_pitch(style: int, seed: float) -> float:
	match style:
		S_PANEL:
			return 3.0 + seed * 0.5
		S_HISTORIC:
			return 2.7 + seed * 0.6
		S_BRICK:
			return 2.9 + seed * 0.4
		S_MODERN:
			return 2.6
		S_UTILITY:
			return 4.0
	return 3.6


static func has_balconies(style: int, seed: float) -> bool:
	return style == S_PANEL or (style == S_BRICK and seed > 0.55)


static func facade_color(style: int, seed: float) -> Color:
	var pal: Array = PALETTE[style]
	return pal[int(seed * 997.0) % pal.size()]


func add_building(pts: PackedFloat32Array, p0: int, p1: int, tris: PackedInt32Array, t0: int, t1: int,
		attrs: PackedFloat32Array, bi: int) -> void:
	var h := attrs[bi * 8]
	var levels := maxf(attrs[bi * 8 + 1], 1.0)
	var kind := int(attrs[bi * 8 + 3])
	var seed := attrs[bi * 8 + 4]
	var landmark := attrs[bi * 8 + 5] > 0.5
	if attrs[bi * 8 + 5] > 1.5:
		# Drawn by its own model (scripts/city/landmarks): only the walls' collision here.
		var ctop := minf(h, COLLISION_TOP)
		for k in p1 - p0:
			var a := Vector3(pts[(p0 + k) * 2], 0.0, pts[(p0 + k) * 2 + 1])
			var j := p0 + (k + 1) % (p1 - p0)
			var b := Vector3(pts[j * 2], 0.0, pts[j * 2 + 1])
			faces.append_array([a, b, b + Vector3(0, ctop, 0), a, b + Vector3(0, ctop, 0), a + Vector3(0, ctop, 0)])
		return
	_lit = attrs[bi * 8 + 7]
	_style = style_for(kind, levels, seed, landmark)
	_floor_h = clampf(h / levels, 2.6, 6.0)
	_pitch = window_pitch(_style, seed)
	var balcony_offset := floorf(seed * 3.0)
	_style_code = float(_style) + 8.0 * (balcony_offset + (3.0 if has_balconies(_style, seed) else 0.0))
	var tint := facade_color(_style, seed)
	_col = Color(tint.r, tint.g, tint.b, seed)
	_kind_code = float(kind) + (8.0 if landmark else 0.0)
	_shape = Vector2(levels, h)
	building_count += 1

	var count := p1 - p0
	var ring: Array[Vector2] = []
	for k in count:
		ring.append(Vector2(pts[(p0 + k) * 2], pts[(p0 + k) * 2 + 1]))
	# Outward miter vectors per vertex (ring is counter-clockwise in x/z: outside on the right).
	var miter: Array[Vector2] = []
	for k in count:
		var a := ring[(k - 1 + count) % count]
		var b := ring[k]
		var c := ring[(k + 1) % count]
		var n1 := _edge_normal(a, b)
		var n2 := _edge_normal(b, c)
		var m := (n1 + n2)
		if m.length_squared() < 1e-6:
			m = n2
		m = m.normalized()
		miter.append(m / maxf(m.dot(n2), 0.35))

	var parapet := 0.0
	match _style:
		S_PANEL:
			parapet = 0.7
		S_BRICK:
			parapet = 0.5
		S_MODERN:
			parapet = 1.0
		S_UTILITY:
			parapet = 0.25
		_:
			parapet = 0.15
	var top := h + parapet
	var plinth_h: float = {S_PANEL: 0.7, S_HISTORIC: 0.95, S_BRICK: 0.6, S_RELIGIOUS: 0.8}.get(_style, -1.0)
	# Shop fronts come down to about 0.4 m: keep the plinth below them (same rule as the shader).
	var shops := kind == B_COMMERCIAL or (kind == B_PUBLIC and _style == S_MODERN) \
		or (kind == B_RESIDENTIAL and seed > 0.72 and _style != S_PANEL)
	if shops and plinth_h > 0.0:
		plinth_h = 0.3
	var pitch := _pitch
	var ctop := minf(h, COLLISION_TOP)

	for k in count:
		var a2 := ring[k]
		var b2 := ring[(k + 1) % count]
		var e := b2 - a2
		var seg := e.length()
		if seg < 0.05:
			continue
		_seg_len = seg
		_seg_id = float(_seg_counter % 4096)
		_seg_counter += 1
		var t3 := Vector3(e.x, 0.0, e.y) / seg
		var n3 := Vector3(e.y, 0.0, -e.x) / seg
		var a3 := Vector3(a2.x, 0.0, a2.y)
		var b3 := Vector3(b2.x, 0.0, b2.y)
		var ma := Vector3(miter[k].x, 0.0, miter[k].y)
		var mb := Vector3(miter[(k + 1) % count].x, 0.0, miter[(k + 1) % count].y)

		# Wall (with parapet above the roof).
		_quad(a3 + Vector3(0, WALL_BOTTOM, 0), b3 + Vector3(0, WALL_BOTTOM, 0), b3 + Vector3(0, top, 0),
			a3 + Vector3(0, top, 0), n3, Vector2(0, WALL_BOTTOM), Vector2(seg, WALL_BOTTOM), Vector2(seg, top),
			Vector2(0, top), P_WALL)
		faces.append_array([a3, b3, b3 + Vector3(0, ctop, 0), a3, b3 + Vector3(0, ctop, 0), a3 + Vector3(0, ctop, 0)])

		if plinth_h > 0.0:
			_ledge(a3, b3, ma, mb, n3, seg, 0.07, WALL_BOTTOM, plinth_h, P_PLINTH, false)
		match _style:
			S_HISTORIC, S_RELIGIOUS:
				_ledge(a3, b3, ma, mb, n3, seg, 0.18, h - 0.8, h - 0.6, P_TRIM, true)
				_ledge(a3, b3, ma, mb, n3, seg, 0.42, h - 0.45, h - 0.05, P_TRIM, true)
				if levels >= 2.0:
					_ledge(a3, b3, ma, mb, n3, seg, 0.08, _floor_h - 0.06, _floor_h + 0.12, P_TRIM, true)
			S_BRICK:
				_ledge(a3, b3, ma, mb, n3, seg, 0.15, h - 0.3, h, P_TRIM, true)
				_ledge(a3, b3, ma, mb, n3, seg, 0.05, top - 0.1, top, P_TRIM, false)
			S_PANEL, S_MODERN:
				_ledge(a3, b3, ma, mb, n3, seg, 0.06, top - 0.12, top, P_TRIM, false)

		if has_balconies(_style, seed) and seg >= 10.0 and levels >= 3.0:
			_balconies(a3, t3, n3, seg, pitch, levels, seed)
		if kind == B_RESIDENTIAL and (_style == S_PANEL or _style == S_BRICK) and seg >= 14.0 \
				and int(_seg_id) % 2 == 0:
			_canopies(a3, t3, n3, seg, pitch)

	# Flat roof (snow) at roof height; triangles are already wound to face up.
	var rbase := roof_v.size()
	for k in count:
		roof_v.append(Vector3(ring[k].x, h, ring[k].y))
		roof_n.append(Vector3.UP)
	for t in range(t0, t1):
		roof_i.append(rbase + tris[t])


func _edge_normal(a: Vector2, b: Vector2) -> Vector2:
	var e := b - a
	var l := e.length()
	return Vector2(e.y, -e.x) / l if l > 1e-6 else Vector2.ZERO


## Adds a quad, wound to face `nrm` (Godot front faces are clockwise).
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, part: int) -> void:
	var base := v.size()
	v.append_array([a, b, c, d])
	n.append_array([nrm, nrm, nrm, nrm])
	uv.append_array([ua, ub, uc, ud])
	for q in 4:
		uv2.append(_shape)
		col.append(_col)
		c0.append_array([_seg_len, _floor_h, _kind_code, _lit])
		c1.append_array([_seg_id, _style_code, float(part), _pitch])
	if (c - a).cross(b - a).dot(nrm) >= 0.0:
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	else:
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


## A band sticking out of the wall by `depth` between y0 and y1 (front, top, optionally
## underside), mitred at the corners so bands run continuously around the building.
func _ledge(a: Vector3, b: Vector3, ma: Vector3, mb: Vector3, nrm: Vector3, seg: float, depth: float,
		y0: float, y1: float, part: int, underside: bool) -> void:
	var oa := a + ma * depth
	var ob := b + mb * depth
	var up := Vector3(0, 1, 0)
	_quad(oa + up * y0, ob + up * y0, ob + up * y1, oa + up * y1, nrm,
		Vector2(0, y0), Vector2(seg, y0), Vector2(seg, y1), Vector2(0, y1), part)
	_quad(a + up * y1, b + up * y1, ob + up * y1, oa + up * y1, Vector3.UP,
		Vector2(0, y1), Vector2(seg, y1), Vector2(seg, y1), Vector2(0, y1), part)
	if underside:
		_quad(a + up * y0, b + up * y0, ob + up * y0, oa + up * y0, Vector3.DOWN,
			Vector2(0, y0), Vector2(seg, y0), Vector2(seg, y0), Vector2(0, y0), part)


## A box-like element in front of the wall: `u0..u1` along it, `y0..y1`, `0..depth` out.
func _p(a: Vector3, t: Vector3, nrm: Vector3, u: float, y: float, out: float) -> Vector3:
	return a + t * u + nrm * out + Vector3(0, y, 0)


func _balconies(a: Vector3, t: Vector3, nrm: Vector3, seg: float, pitch: float, levels: float, seed: float) -> void:
	var n_cols := floorf(maxf(seg - 1.2, 0.0) / pitch)
	var margin := (seg - n_cols * pitch) * 0.5
	var offset := floorf(seed * 3.0)  # also encoded in the style code for the shader
	var depth := 1.1
	for c in int(n_cols):
		if absf(fmod(c + offset, 3.0) - 1.0) > 0.5:
			continue
		var uc := margin + (c + 0.5) * pitch
		var u0 := uc - 0.45 * pitch
		var u1 := uc + 0.45 * pitch
		for r in range(1, int(levels)):
			if float(r) >= levels - 0.5:
				break
			var y0 := r * _floor_h - 0.05
			var yp := y0 + 1.15
			var ytop := (r + 1) * _floor_h - 0.12
			var glazed := fmod(absf(sin(c * 12.9898 + r * 78.233 + _seg_id * 3.7)) * 43758.5453, 1.0) < 0.65
			# soffit, front parapet, side parapets
			_quad(_p(a, t, nrm, u0, y0, 0), _p(a, t, nrm, u1, y0, 0), _p(a, t, nrm, u1, y0, depth),
				_p(a, t, nrm, u0, y0, depth), Vector3.DOWN, Vector2(u0, y0), Vector2(u1, y0), Vector2(u1, y0),
				Vector2(u0, y0), P_BALCONY)
			_quad(_p(a, t, nrm, u0, y0, depth), _p(a, t, nrm, u1, y0, depth), _p(a, t, nrm, u1, yp, depth),
				_p(a, t, nrm, u0, yp, depth), nrm, Vector2(u0, y0), Vector2(u1, y0), Vector2(u1, yp),
				Vector2(u0, yp), P_BALCONY)
			for side in [0, 1]:
				var us: float = u0 if side == 0 else u1
				var sn := -t if side == 0 else t
				_quad(_p(a, t, nrm, us, y0, 0), _p(a, t, nrm, us, y0, depth), _p(a, t, nrm, us, yp, depth),
					_p(a, t, nrm, us, yp, 0), sn, Vector2(us, y0), Vector2(us + depth, y0),
					Vector2(us + depth, yp), Vector2(us, yp), P_BALCONY)
			if glazed:
				_quad(_p(a, t, nrm, u0, yp, depth), _p(a, t, nrm, u1, yp, depth), _p(a, t, nrm, u1, ytop, depth),
					_p(a, t, nrm, u0, ytop, depth), nrm, Vector2(u0, yp), Vector2(u1, yp), Vector2(u1, ytop),
					Vector2(u0, ytop), P_GLASS)
				for side in [0, 1]:
					var us: float = u0 if side == 0 else u1
					var sn := -t if side == 0 else t
					_quad(_p(a, t, nrm, us, yp, 0), _p(a, t, nrm, us, yp, depth), _p(a, t, nrm, us, ytop, depth),
						_p(a, t, nrm, us, ytop, 0), sn, Vector2(us, yp), Vector2(us + depth, yp),
						Vector2(us + depth, ytop), Vector2(us, ytop), P_GLASS)
				if float(r + 1) >= levels - 0.5:
					# The top loggia gets its own little roof, with snow on it.
					_quad(_p(a, t, nrm, u0, ytop, 0), _p(a, t, nrm, u1, ytop, 0), _p(a, t, nrm, u1, ytop, depth),
						_p(a, t, nrm, u0, ytop, depth), Vector3.UP, Vector2(u0, ytop), Vector2(u1, ytop),
						Vector2(u1, ytop), Vector2(u0, ytop), P_BALCONY)


func _canopies(a: Vector3, t: Vector3, nrm: Vector3, seg: float, pitch: float) -> void:
	var n_cols := floorf(maxf(seg - 1.2, 0.0) / pitch)
	var margin := (seg - n_cols * pitch) * 0.5
	var y0 := minf(_floor_h - 0.25, 2.65)
	var y1 := y0 + 0.14
	var depth := 1.25
	for c in int(n_cols):
		if absf(fmod(c, 4.0) - 1.0) > 0.5:
			continue
		var uc := margin + (c + 0.5) * pitch
		var u0 := uc - 1.0
		var u1 := uc + 1.0
		_quad(_p(a, t, nrm, u0, y0, 0), _p(a, t, nrm, u1, y0, 0), _p(a, t, nrm, u1, y0, depth),
			_p(a, t, nrm, u0, y0, depth), Vector3.DOWN, Vector2(u0, y0), Vector2(u1, y0), Vector2(u1, y0),
			Vector2(u0, y0), P_CANOPY)
		_quad(_p(a, t, nrm, u0, y0, depth), _p(a, t, nrm, u1, y0, depth), _p(a, t, nrm, u1, y1, depth),
			_p(a, t, nrm, u0, y1, depth), nrm, Vector2(u0, y0), Vector2(u1, y0), Vector2(u1, y1),
			Vector2(u0, y1), P_CANOPY)
		_quad(_p(a, t, nrm, u0, y1, 0), _p(a, t, nrm, u1, y1, 0), _p(a, t, nrm, u1, y1, depth),
			_p(a, t, nrm, u0, y1, depth), Vector3.UP, Vector2(u0, y1), Vector2(u1, y1), Vector2(u1, y1),
			Vector2(u0, y1), P_CANOPY)
		for side in [0, 1]:
			var us: float = u0 if side == 0 else u1
			var sn := -t if side == 0 else t
			_quad(_p(a, t, nrm, us, y0, 0), _p(a, t, nrm, us, y0, depth), _p(a, t, nrm, us, y1, depth),
				_p(a, t, nrm, us, y1, 0), sn, Vector2(us, y0), Vector2(us + depth, y0), Vector2(us + depth, y1),
				Vector2(us, y1), P_CANOPY)


func wall_arrays() -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


func roof_arrays() -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = roof_v
	arrays[Mesh.ARRAY_NORMAL] = roof_n
	arrays[Mesh.ARRAY_INDEX] = roof_i
	return arrays
