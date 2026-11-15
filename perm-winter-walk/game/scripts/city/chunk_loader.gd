extends RefCounted
## Reads one PWC1 chunk file (written by tools/preprocess_osm.py, format in
## data/FORMAT.md) and turns it into plain mesh arrays and transforms.
##
## Runs on a WorkerThreadPool thread, so it must not touch the scene tree. The
## streamer creates the nodes from the returned Dictionary on the main thread.

const Props := preload("res://scripts/city/props.gd")

const WALL_BOTTOM := -0.3
const COLLISION_TOP := 6.0
const CUSTOM0_FLAGS := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)

enum { B_RESIDENTIAL, B_COMMERCIAL, B_PUBLIC, B_UTILITY, B_RELIGIOUS }

## Facade colours seen in central Perm: Soviet panel greys and beiges, ochre and salmon
## stucco, dark brick, a few pale green and blue-grey fronts.
const PALETTE := {
	B_RESIDENTIAL: [
		Color(0.55, 0.5, 0.42), Color(0.48, 0.48, 0.5), Color(0.62, 0.54, 0.34), Color(0.42, 0.24, 0.18),
		Color(0.66, 0.65, 0.62), Color(0.45, 0.5, 0.56), Color(0.6, 0.42, 0.34), Color(0.5, 0.57, 0.5)],
	B_COMMERCIAL: [Color(0.3, 0.34, 0.4), Color(0.5, 0.5, 0.52), Color(0.42, 0.38, 0.35), Color(0.58, 0.55, 0.5)],
	B_PUBLIC: [Color(0.68, 0.6, 0.42), Color(0.7, 0.68, 0.62), Color(0.55, 0.62, 0.6), Color(0.66, 0.5, 0.4)],
	B_UTILITY: [Color(0.36, 0.36, 0.38), Color(0.4, 0.33, 0.28), Color(0.45, 0.45, 0.43)],
	B_RELIGIOUS: [Color(0.82, 0.8, 0.74), Color(0.78, 0.72, 0.6)],
}

## Snow-bank cross-section: (offset across in m, height in m).
const BANK_PROFILE := [Vector2(-0.85, 0.0), Vector2(-0.45, 0.3), Vector2(0.0, 0.44), Vector2(0.45, 0.3), Vector2(0.85, 0.0)]


static func load_and_build(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 24:
		return {"error": "cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	var d := parse(bytes)
	if d.has("error"):
		return d
	_build_buildings(d)
	_build_flat(d)
	_build_decals(d)
	_build_props(d)
	if d.has("lmap_png"):
		var img := Image.new()
		if img.load_png_from_buffer(d["lmap_png"]) == OK:
			d["lmap_image"] = img
		d.erase("lmap_png")
	return d


static func parse(b: PackedByteArray) -> Dictionary:
	if b.slice(0, 4).get_string_from_ascii() != "PWC1":
		return {"error": "not a PWC1 chunk"}
	if b.decode_u32(4) != 1:
		return {"error": "unsupported chunk version %d" % b.decode_u32(4)}
	var d := {"cx": b.decode_s32(8), "cz": b.decode_s32(12), "size": b.decode_float(16)}
	var nsec := b.decode_u32(20)
	var off := 24
	for i in nsec:
		var tag := b.slice(off, off + 4).get_string_from_ascii()
		var ln := b.decode_u32(off + 4)
		var p := b.slice(off + 8, off + 8 + ln)
		off += 8 + ln
		match tag:
			"BLDG":
				var n := p.decode_u32(0)
				var npts := p.decode_u32(4)
				var ntri := p.decode_u32(8)
				var o := 12
				d["b_count"] = n
				d["b_attrs"] = p.slice(o, o + n * 32).to_float32_array()
				o += n * 32
				d["b_poff"] = p.slice(o, o + (n + 1) * 4).to_int32_array()
				o += (n + 1) * 4
				d["b_toff"] = p.slice(o, o + (n + 1) * 4).to_int32_array()
				o += (n + 1) * 4
				d["b_pts"] = p.slice(o, o + npts * 8).to_float32_array()
				o += npts * 8
				d["b_tris"] = p.slice(o, o + ntri * 4).to_int32_array()
			"FLAT", "DECL":
				var nv := p.decode_u32(0)
				var ni := p.decode_u32(4)
				var k := 1 if tag == "FLAT" else 4
				var o := 8
				d[tag + "_pos"] = p.slice(o, o + nv * 8).to_float32_array()
				o += nv * 8
				d[tag + "_attr"] = p.slice(o, o + nv * 4 * k).to_float32_array()
				o += nv * 4 * k
				d[tag + "_idx"] = p.slice(o, o + ni * 4).to_int32_array()
			"BANK":
				var nl := p.decode_u32(0)
				var npts := p.decode_u32(4)
				d["bank_offs"] = p.slice(8, 8 + (nl + 1) * 4).to_int32_array()
				d["bank_pts"] = p.slice(8 + (nl + 1) * 4, 8 + (nl + 1) * 4 + npts * 8).to_float32_array()
			"LAMP", "TREE":
				var n := p.decode_u32(0)
				d[tag] = p.slice(4, 4 + n * 16).to_float32_array()
			"LMAP":
				var png_len := p.decode_u32(4)
				d["lmap_png"] = p.slice(8, 8 + png_len)
	return d


static func facade_color(kind: int, seed: float) -> Color:
	var pal: Array = PALETTE.get(kind, PALETTE[B_RESIDENTIAL])
	return pal[int(seed * 997.0) % pal.size()]


static func _build_buildings(d: Dictionary) -> void:
	if not d.has("b_count"):
		return
	var attrs: PackedFloat32Array = d["b_attrs"]
	var poff: PackedInt32Array = d["b_poff"]
	var toff: PackedInt32Array = d["b_toff"]
	var pts: PackedFloat32Array = d["b_pts"]
	var tris: PackedInt32Array = d["b_tris"]
	var wv := PackedVector3Array()
	var wn := PackedVector3Array()
	var wuv := PackedVector2Array()
	var wuv2 := PackedVector2Array()
	var wc := PackedColorArray()
	var wcu := PackedFloat32Array()
	var wseg := PackedFloat32Array()  # exact per-segment id for the window random state
	var wi := PackedInt32Array()
	var rv := PackedVector3Array()
	var rn := PackedVector3Array()
	var ri := PackedInt32Array()
	var faces := PackedVector3Array()
	for bi in int(d["b_count"]):
		var h := attrs[bi * 8]
		var levels := maxf(attrs[bi * 8 + 1], 1.0)
		var kind := int(attrs[bi * 8 + 3])
		var seed := attrs[bi * 8 + 4]
		var landmark := attrs[bi * 8 + 5]
		var lit := attrs[bi * 8 + 7]
		var floor_h := clampf(h / levels, 2.6, 6.0)
		var tint := facade_color(kind, seed)
		var col := Color(tint.r, tint.g, tint.b, seed)
		var kind_code := float(kind) + (8.0 if landmark > 0.5 else 0.0)
		var p0 := poff[bi]
		var p1 := poff[bi + 1]
		var count := p1 - p0
		var ctop := minf(h, COLLISION_TOP)
		for k in count:
			var j := p0 + k
			var j2 := p0 + (k + 1) % count
			var a := Vector2(pts[j * 2], pts[j * 2 + 1])
			var b := Vector2(pts[j2 * 2], pts[j2 * 2 + 1])
			var e := b - a
			var seg := e.length()
			if seg < 0.05:
				continue
			# Rings are counter-clockwise in (x, z): the outward normal is on the right.
			var n := Vector3(e.y, 0.0, -e.x) / seg
			var base := wv.size()
			var a0 := Vector3(a.x, WALL_BOTTOM, a.y)
			var b0 := Vector3(b.x, WALL_BOTTOM, b.y)
			var b1 := Vector3(b.x, h, b.y)
			var a1 := Vector3(a.x, h, a.y)
			wv.append_array([a0, b0, b1, a1])
			wn.append_array([n, n, n, n])
			wuv.append_array([Vector2(0, WALL_BOTTOM), Vector2(seg, WALL_BOTTOM), Vector2(seg, h), Vector2(0, h)])
			var shape := Vector2(levels, h)
			wuv2.append_array([shape, shape, shape, shape])
			wc.append_array([col, col, col, col])
			var seg_id := float(wseg.size() / 4 % 4096)
			for q in 4:
				wcu.append_array([seg, floor_h, kind_code, lit])
				wseg.append(seg_id)
			wi.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
			var ca := Vector3(a.x, 0.0, a.y)
			var cb := Vector3(b.x, 0.0, b.y)
			var cb1 := Vector3(b.x, ctop, b.y)
			var ca1 := Vector3(a.x, ctop, a.y)
			faces.append_array([ca, cb, cb1, ca, cb1, ca1])
		var rbase := rv.size()
		for k in count:
			var j := p0 + k
			rv.append(Vector3(pts[j * 2], h, pts[j * 2 + 1]))
			rn.append(Vector3.UP)
		for t in range(toff[bi], toff[bi + 1]):
			ri.append(rbase + tris[t])
	if wv.is_empty():
		return
	var walls := []
	walls.resize(Mesh.ARRAY_MAX)
	walls[Mesh.ARRAY_VERTEX] = wv
	walls[Mesh.ARRAY_NORMAL] = wn
	walls[Mesh.ARRAY_TEX_UV] = wuv
	walls[Mesh.ARRAY_TEX_UV2] = wuv2
	walls[Mesh.ARRAY_COLOR] = wc
	walls[Mesh.ARRAY_CUSTOM0] = wcu
	walls[Mesh.ARRAY_CUSTOM1] = wseg
	walls[Mesh.ARRAY_INDEX] = wi
	d["wall_arrays"] = walls
	var roofs := []
	roofs.resize(Mesh.ARRAY_MAX)
	roofs[Mesh.ARRAY_VERTEX] = rv
	roofs[Mesh.ARRAY_NORMAL] = rn
	roofs[Mesh.ARRAY_INDEX] = ri
	d["roof_arrays"] = roofs
	d["collision_faces"] = faces


static func _build_flat(d: Dictionary) -> void:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	if d.has("FLAT_pos"):
		var pos: PackedFloat32Array = d["FLAT_pos"]
		var kinds: PackedFloat32Array = d["FLAT_attr"]
		var nv := kinds.size()
		v.resize(nv)
		n.resize(nv)
		c.resize(nv)
		for i in nv:
			v[i] = Vector3(pos[i * 2], 0.0, pos[i * 2 + 1])
			n[i] = Vector3.UP
			c[i] = Color(kinds[i] / 8.0, 0.0, 0.0, 1.0)
		idx = d["FLAT_idx"]
	if d.has("bank_offs"):
		_build_banks(d["bank_offs"], d["bank_pts"], v, n, c, idx)
	if v.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_COLOR] = c
	arrays[Mesh.ARRAY_INDEX] = idx
	d["flat_arrays"] = arrays


## Extrudes the snow-bank profile along each polyline, resampled every 1.5 m with a
## little height noise so banks look shovelled rather than machined.
static func _build_banks(offs: PackedInt32Array, pts: PackedFloat32Array, v: PackedVector3Array,
		n: PackedVector3Array, c: PackedColorArray, idx: PackedInt32Array) -> void:
	var ground := Color(0.0, 0.0, 0.0, 1.0)
	var np := BANK_PROFILE.size()
	for li in offs.size() - 1:
		var line := PackedVector2Array()
		for j in range(offs[li], offs[li + 1]):
			line.append(Vector2(pts[j * 2], pts[j * 2 + 1]))
		var samples := _resample(line, 1.5)
		if samples.size() < 2:
			continue
		var base := v.size()
		for si in samples.size():
			var p := samples[si]
			var t := (samples[mini(si + 1, samples.size() - 1)] - samples[maxi(si - 1, 0)]).normalized()
			var left := Vector2(-t.y, t.x)
			var amp := 0.75 + 0.5 * (0.5 + 0.5 * sin(p.x * 0.37 + p.y * 0.21) * cos(p.y * 0.29 - p.x * 0.13))
			var end_fade := minf(1.0, minf(si, samples.size() - 1 - si) * 0.5)
			amp *= end_fade
			for pj in np:
				var o: Vector2 = BANK_PROFILE[pj]
				var y := o.y * amp
				var q := p + left * o.x
				v.append(Vector3(q.x, y, q.y))
				var prev: Vector2 = BANK_PROFILE[maxi(pj - 1, 0)]
				var next: Vector2 = BANK_PROFILE[mini(pj + 1, np - 1)]
				var slope := (next.y - prev.y) * amp / maxf(next.x - prev.x, 0.01)
				n.append(Vector3(-slope * left.x, 1.0, -slope * left.y).normalized())
				c.append(ground)
		for si in samples.size() - 1:
			for pj in np - 1:
				var a := base + si * np + pj
				var b := a + np
				# counter-clockwise in (x, z) seen from above = Godot front face
				idx.append_array([a, b, b + 1, a, b + 1, a + 1])


static func _resample(line: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if line.size() < 2:
		return out
	out.append(line[0])
	var carry := 0.0
	for i in line.size() - 1:
		var a := line[i]
		var b := line[i + 1]
		var seg := a.distance_to(b)
		var d := step - carry
		while d <= seg:
			out.append(a.lerp(b, d / seg))
			d += step
		carry = seg - (d - step)
	if out[out.size() - 1].distance_to(line[line.size() - 1]) > 0.3:
		out.append(line[line.size() - 1])
	return out


static func _build_decals(d: Dictionary) -> void:
	if not d.has("DECL_pos"):
		return
	var pos: PackedFloat32Array = d["DECL_pos"]
	var attr: PackedFloat32Array = d["DECL_attr"]
	var nv := pos.size() / 2
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	v.resize(nv)
	n.resize(nv)
	uv.resize(nv)
	uv2.resize(nv)
	for i in nv:
		v[i] = Vector3(pos[i * 2], 0.025, pos[i * 2 + 1])
		n[i] = Vector3.UP
		uv[i] = Vector2(attr[i * 4], attr[i * 4 + 1])
		uv2[i] = Vector2(attr[i * 4 + 2], attr[i * 4 + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = d["DECL_idx"]
	d["decal_arrays"] = arrays


static func _build_props(d: Dictionary) -> void:
	var street: Array[Transform3D] = []
	var park: Array[Transform3D] = []
	var cones: Array[Transform3D] = []
	var heads := PackedVector4Array()  # x, y, z, range
	if d.has("LAMP"):
		var l: PackedFloat32Array = d["LAMP"]
		for i in l.size() / 4:
			var pos := Vector3(l[i * 4], 0.0, l[i * 4 + 1])
			var basis := Basis(Vector3.UP, l[i * 4 + 2])
			var is_park := l[i * 4 + 3] > 1.5
			var xf := Transform3D(basis, pos)
			var head: Vector3
			var r: float
			if is_park:
				park.append(xf)
				head = pos + Props.LAMP_PARK_HEAD
				r = 2.1
			else:
				street.append(xf)
				head = pos + basis * Props.LAMP_STREET_HEAD
				r = 3.1
			cones.append(Transform3D(Basis.from_scale(Vector3(r, head.y - 0.02, r)), head - Vector3(0, 0.08, 0)))
			heads.append(Vector4(head.x, head.y, head.z, 14.0 if not is_park else 9.0))
	d["lamp_street"] = street
	d["lamp_park"] = park
	d["lamp_cones"] = cones
	d["lamp_heads"] = heads
	var bare: Array[Transform3D] = []
	var spruce: Array[Transform3D] = []
	if d.has("TREE"):
		var t: PackedFloat32Array = d["TREE"]
		for i in t.size() / 4:
			var x := t[i * 4]
			var z := t[i * 4 + 1]
			var s := t[i * 4 + 2]
			var yaw := fmod(absf(x * 12.9898 + z * 78.233) * 43.7585, TAU)
			var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s)), Vector3(x, 0.0, z))
			if t[i * 4 + 3] > 0.5:
				spruce.append(xf)
			else:
				bare.append(xf)
	d["tree_bare"] = bare
	d["tree_spruce"] = spruce
