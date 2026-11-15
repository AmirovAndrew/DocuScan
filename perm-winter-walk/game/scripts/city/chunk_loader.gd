extends RefCounted
## Reads one PWC1 chunk file (written by tools/preprocess_osm.py, format in
## data/FORMAT.md) and turns it into plain mesh arrays and transforms.
##
## Runs on a WorkerThreadPool thread, so it must not touch the scene tree. The
## streamer creates the nodes from the returned Dictionary on the main thread.

const Props := preload("res://scripts/city/props.gd")
const BuildingBuilder := preload("res://scripts/city/building_builder.gd")

const CUSTOM0_FLAGS := BuildingBuilder.CUSTOM_FLAGS

enum { B_RESIDENTIAL, B_COMMERCIAL, B_PUBLIC, B_UTILITY, B_RELIGIOUS }

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


static func _build_buildings(d: Dictionary) -> void:
	if not d.has("b_count"):
		return
	var attrs: PackedFloat32Array = d["b_attrs"]
	var poff: PackedInt32Array = d["b_poff"]
	var toff: PackedInt32Array = d["b_toff"]
	var pts: PackedFloat32Array = d["b_pts"]
	var tris: PackedInt32Array = d["b_tris"]
	var bb := BuildingBuilder.new()
	for bi in int(d["b_count"]):
		bb.add_building(pts, poff[bi], poff[bi + 1], tris, toff[bi], toff[bi + 1], attrs, bi)
	if bb.v.is_empty():
		return
	d["wall_arrays"] = bb.wall_arrays()
	d["roof_arrays"] = bb.roof_arrays()
	d["collision_faces"] = bb.faces


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
			if t[i * 4 + 3] > 0.5:
				var w := 0.85 + 0.3 * fmod(absf(x * 3.17 + z * 1.93), 1.0)  # slimmer or fuller crowns
				spruce.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s * w, s, s * w)), Vector3(x, 0.0, z)))
			else:
				bare.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s)), Vector3(x, 0.0, z)))
	d["tree_bare"] = bare
	d["tree_spruce"] = spruce
