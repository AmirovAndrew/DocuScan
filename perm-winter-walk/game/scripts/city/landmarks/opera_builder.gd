extends RefCounted
## Perm Opera and Ballet Theatre (Tchaikovsky Theatre), built as a dedicated model.
##
## Massing comes from the OpenStreetMap building:parts in the manifest (see
## tools/preprocess_osm.py, landmark_model): an 18 m main body with a hipped roof, the
## 23 m auditorium whose gabled roof ends in the pediment of the main facade, and the
## 26 m stage house. The main facade faces the Theatre Garden.
##
## Local frame: x = across the building, y = up, z = from the main facade (z = 0, the
## front of the portico) to the back. The facade faces -z. Everything is real geometry
## in one surface: rusticated ground floor with arched doors, steps, a loggia with a
## colonnade and balustrade, entablature and pediment with a relief, window openings
## with reveals, surrounds, sills and sandriks, giant pilasters, cornices, roofs.

const Kit := preload("res://scripts/city/landmarks/mesh_kit.gd")

# ---- appearance (tuned against photographs; easy to adjust)
const WALL_COLOR := Color(0.80, 0.69, 0.50)     # warm cream / pale ochre stucco
const TRIM_COLOR := Color(0.90, 0.88, 0.82)     # white trims, columns, cornices
const STONE_COLOR := Color(0.42, 0.41, 0.40)    # granite plinth and steps
const ROOF_COLOR := Color(0.30, 0.34, 0.33)     # painted sheet metal (mostly under snow)
const COLUMNS := 6
const BAY := 3.6

var k := Kit.new()
var _rng := RandomNumberGenerator.new()


## Returns {"arrays": mesh arrays, "transform": Transform3D, "front": Vector3, "triangles": int}.
func build(lm: Dictionary) -> Dictionary:
	_rng.seed = 18780
	var fr: Dictionary = lm.get("frame", {})
	var width: float = fr.get("width", 41.8)
	var length: float = fr.get("length", 66.5)
	var hall := _part_box(lm, "gabled", 23.0, Rect2(-10.6, 0.0, 21.3, 33.0), true)
	var stage := _part_box(lm, "gabled", 26.0, Rect2(-12.4, 33.0, 24.8, 18.6), false)
	var body_h := 18.0
	for p: Dictionary in lm.get("parts", []):
		if String(p.get("roof", "")) == "hipped" and p.get("height") != null:
			body_h = float(p["height"])
	var pw: float = hall["rect"].size.x          # portico / hall width
	var pc: float = hall["rect"].get_center().x  # its centre across the building
	var pd := _portico_depth(lm)                 # how far the portico stands out of the body
	var eave := body_h - 2.4                     # main cornice top
	var half_w := width * 0.5

	_steps(pc, pw)
	_portico(pc, pw, pd, eave, float(hall["h"]))
	# Wings either side of the portico, the long sides and the back.
	var floors := _floors(eave)
	_facade(Vector3(-half_w, 0, pd), Vector3.RIGHT, Vector3.FORWARD, (pc - pw * 0.5) + half_w, floors, true, 0.0)
	_facade(Vector3(pc + pw * 0.5, 0, pd), Vector3.RIGHT, Vector3.FORWARD, half_w - (pc + pw * 0.5), floors, true, 0.0)
	_facade(Vector3(half_w, 0, pd), Vector3.BACK, Vector3.RIGHT, length - pd, floors, true, 0.0)
	_facade(Vector3(-half_w, 0, length), Vector3.FORWARD, Vector3.LEFT, length - pd, floors, true, 0.0)
	_facade(Vector3(half_w, 0, length), Vector3.LEFT, Vector3.BACK, width, _floors(eave, true), false, 0.0)
	_main_cornice(width, length, pd, eave, pc, pw)
	_body_roof(width, length, pd, eave, body_h)
	_hall_roof(hall, pd, eave)
	_stage_house(stage, eave)

	var o: Array = fr.get("origin", [lm.get("x", 0.0), lm.get("z", 0.0)])
	var u: Array = fr.get("u", [1.0, 0.0])
	var vv: Array = fr.get("v", [0.0, 1.0])
	var basis := Basis(Vector3(u[0], 0, u[1]), Vector3.UP, Vector3(vv[0], 0, vv[1]))
	return {"arrays": k.arrays(), "colliders": k.colliders, "transform": Transform3D(basis, Vector3(o[0], 0, o[1])),
			"front": -Vector3(vv[0], 0, vv[1]), "triangles": k.tri_count()}


# ------------------------------------------------------------------ data helpers
func _part_box(lm: Dictionary, roof: String, h_default: float, rect_default: Rect2, front: bool) -> Dictionary:
	var best := {}
	for p: Dictionary in lm.get("parts", []):
		if String(p.get("roof", "")) != roof:
			continue
		var mn := Vector2(1e9, 1e9)
		var mx := Vector2(-1e9, -1e9)
		for q: Array in p["pts"]:
			mn = mn.min(Vector2(q[0], q[1]))
			mx = mx.max(Vector2(q[0], q[1]))
		var r := Rect2(mn, mx - mn)
		# the hall starts at the facade; the stage house is the one further back
		if best.is_empty() or (front and r.position.y < best["rect"].position.y) \
				or (not front and r.position.y > best["rect"].position.y):
			best = {"rect": r, "h": float(p.get("height", h_default))}
	if best.is_empty():
		best = {"rect": rect_default, "h": h_default}
	return best


func _portico_depth(lm: Dictionary) -> float:
	# The footprint's front corners outside the portico give the line of the wings.
	var d := 3.0
	for q: Array in lm.get("footprint", []):
		if absf(q[0]) > 15.0 and q[1] < 10.0:
			d = q[1]
	return clampf(d, 1.5, 6.0)


func _floors(eave: float, plain := false) -> Array:
	var g := 5.6        # ground floor (rusticated)
	var f2 := 10.8      # second floor top
	var top := eave - 0.6
	return [
		{"y0": 0.0, "y1": g, "rustic": true,
		 "win": {"w": 1.7, "bottom": 1.25, "h": 3.0, "arch": not plain, "surround": false, "sill": true,
				 "sandrik": 0, "lit": 0.45, "depth": 0.45}},
		{"y0": g, "y1": f2, "rustic": false,
		 "win": {"w": 1.6, "bottom": 0.95, "h": 3.25, "arch": false, "surround": true, "sill": true,
				 "sandrik": 0 if plain else 2, "lit": 0.55, "depth": 0.4}},
		{"y0": f2, "y1": top, "rustic": false,
		 "win": {"w": 1.5, "bottom": 0.75, "h": 2.35, "arch": false, "surround": true, "sill": true,
				 "sandrik": 0 if plain else 1, "lit": 0.4, "depth": 0.4}},
	]


# ------------------------------------------------------------------ walls with openings
## A wall: point(s, y, d) = origin + dir * s + up * y + out * d.
func _pt(o: Vector3, dir: Vector3, out: Vector3, s: float, y: float, d := 0.0) -> Vector3:
	return o + dir * s + Vector3(0, y, 0) + out * d


func _wq(o: Vector3, dir: Vector3, out: Vector3, s0: float, s1: float, y0: float, y1: float, d := 0.0) -> void:
	if s1 - s0 < 1e-3 or y1 - y0 < 1e-3:
		return
	k.quad(_pt(o, dir, out, s0, y0, d), _pt(o, dir, out, s1, y0, d), _pt(o, dir, out, s1, y1, d),
		_pt(o, dir, out, s0, y1, d), out, Vector2(s0, y0), Vector2(s1, y0), Vector2(s1, y1), Vector2(s0, y1))


## A box sticking out of a wall: s0..s1 along, y0..y1 up, d0..d1 out. Faces: front, top, bottom, ends.
func _wbox(o: Vector3, dir: Vector3, out: Vector3, s0: float, s1: float, y0: float, y1: float, d0: float, d1: float,
		top := true, bottom := true, ends := true) -> void:
	var p := func(s: float, y: float, d: float) -> Vector3: return _pt(o, dir, out, s, y, d)
	k.quad(p.call(s0, y0, d1), p.call(s1, y0, d1), p.call(s1, y1, d1), p.call(s0, y1, d1), out,
		Vector2(s0, y0), Vector2(s1, y0), Vector2(s1, y1), Vector2(s0, y1))
	if top:
		k.quad(p.call(s0, y1, d0), p.call(s1, y1, d0), p.call(s1, y1, d1), p.call(s0, y1, d1), Vector3.UP,
			Vector2(s0, d0), Vector2(s1, d0), Vector2(s1, d1), Vector2(s0, d1))
	if bottom:
		k.quad(p.call(s0, y0, d0), p.call(s1, y0, d0), p.call(s1, y0, d1), p.call(s0, y0, d1), Vector3.DOWN,
			Vector2(s0, d0), Vector2(s1, d0), Vector2(s1, d1), Vector2(s0, d1))
	if ends:
		k.quad(p.call(s0, y0, d0), p.call(s0, y0, d1), p.call(s0, y1, d1), p.call(s0, y1, d0), -dir,
			Vector2(d0, y0), Vector2(d1, y0), Vector2(d1, y1), Vector2(d0, y1))
		k.quad(p.call(s1, y0, d0), p.call(s1, y0, d1), p.call(s1, y1, d1), p.call(s1, y1, d0), dir,
			Vector2(d0, y0), Vector2(d1, y0), Vector2(d1, y1), Vector2(d0, y1))


## Window or door opening with reveals and glass; arch = semicircular head.
func _opening(o: Vector3, dir: Vector3, out: Vector3, s0: float, s1: float, y0: float, y1: float, arch: bool,
		depth: float, glass_kind: int, lit: float) -> void:
	var r := (s1 - s0) * 0.5
	var sc := (s0 + s1) * 0.5
	var spring := y1 - r if arch else y1
	var wall_kind := k.kind
	var wall_col := k.color
	var p := func(s: float, y: float, d: float) -> Vector3: return _pt(o, dir, out, s, y, d)
	# reveals, in the wall's own colour
	k.quad(p.call(s0, y0, 0), p.call(s0, y0, -depth), p.call(s0, spring, -depth), p.call(s0, spring, 0), dir)
	k.quad(p.call(s1, y0, 0), p.call(s1, y0, -depth), p.call(s1, spring, -depth), p.call(s1, spring, 0), -dir)
	k.quad(p.call(s0, y0, 0), p.call(s1, y0, 0), p.call(s1, y0, -depth), p.call(s0, y0, -depth), Vector3.UP)
	var arc: Array[Vector2] = []
	if arch:
		var segs := 8
		for i in segs + 1:
			var a := PI * (1.0 - float(i) / segs)
			arc.append(Vector2(sc + cos(a) * r, spring + sin(a) * r))
		for i in segs:
			var mid := (arc[i] + arc[i + 1]) * 0.5
			var inward := (Vector2(sc, spring) - mid).normalized()
			var nm := dir * inward.x + Vector3.UP * inward.y
			k.quad(p.call(arc[i].x, arc[i].y, 0), p.call(arc[i + 1].x, arc[i + 1].y, 0),
				p.call(arc[i + 1].x, arc[i + 1].y, -depth), p.call(arc[i].x, arc[i].y, -depth), nm)
	else:
		k.quad(p.call(s0, y1, 0), p.call(s1, y1, 0), p.call(s1, y1, -depth), p.call(s0, y1, -depth), Vector3.DOWN)
	# glass: COLOR = (chance of being lit, warmth, 0, window id)
	k.kind = glass_kind
	k.color = Color(lit, _rng.randf(), 0.0, _rng.randf())
	var h := y1 - y0
	var guv := func(s: float, y: float) -> Vector2: return Vector2((s - s0) / (s1 - s0), (y - y0) / h)
	k.quad(p.call(s0, y0, -depth), p.call(s1, y0, -depth), p.call(s1, spring, -depth), p.call(s0, spring, -depth), out,
		guv.call(s0, y0), guv.call(s1, y0), guv.call(s1, spring), guv.call(s0, spring))
	if arch:
		var cpt: Vector3 = p.call(sc, spring, -depth)
		for i in arc.size() - 1:
			k.tri(cpt, p.call(arc[i].x, arc[i].y, -depth), p.call(arc[i + 1].x, arc[i + 1].y, -depth), out,
				guv.call(sc, spring), guv.call(arc[i].x, arc[i].y), guv.call(arc[i + 1].x, arc[i + 1].y))
	k.kind = wall_kind
	k.color = wall_col


## Wall area of one bay/floor cell with the window hole cut out.
func _cell_with_hole(o: Vector3, dir: Vector3, out: Vector3, s0: float, s1: float, y0: float, y1: float,
		ws0: float, ws1: float, wy0: float, wy1: float, arch: bool) -> void:
	_wq(o, dir, out, s0, ws0, y0, y1)
	_wq(o, dir, out, ws1, s1, y0, y1)
	_wq(o, dir, out, ws0, ws1, y0, wy0)
	if not arch:
		_wq(o, dir, out, ws0, ws1, wy1, y1)
		return
	var r := (ws1 - ws0) * 0.5
	var sc := (ws0 + ws1) * 0.5
	var spring := wy1 - r
	var segs := 8
	var corner_l: Vector3 = _pt(o, dir, out, ws0, wy1)
	var corner_r: Vector3 = _pt(o, dir, out, ws1, wy1)
	for i in segs:
		var a0 := PI * (1.0 - float(i) / segs)
		var a1 := PI * (1.0 - float(i + 1) / segs)
		var q0 := _pt(o, dir, out, sc + cos(a0) * r, spring + sin(a0) * r)
		var q1 := _pt(o, dir, out, sc + cos(a1) * r, spring + sin(a1) * r)
		var corner := corner_l if i < segs / 2 else corner_r
		k.tri(corner, q0, q1, out)
	_wq(o, dir, out, ws0, ws1, wy1, y1)


## Window dressing: surround (наличник), sill with snow, sandrik (1 straight, 2 triangular).
func _dressing(o: Vector3, dir: Vector3, out: Vector3, ws0: float, ws1: float, wy0: float, wy1: float, win: Dictionary) -> void:
	var keep_kind := k.kind
	var keep_col := k.color
	k.kind = Kit.K_TRIM
	k.color = Color(TRIM_COLOR.r, TRIM_COLOR.g, TRIM_COLOR.b, 0)
	var fw := 0.15
	if win.get("surround", false) and not win.get("arch", false):
		_wbox(o, dir, out, ws0 - fw, ws0, wy0, wy1, 0.0, 0.07, false, false, true)
		_wbox(o, dir, out, ws1, ws1 + fw, wy0, wy1, 0.0, 0.07, false, false, true)
		_wbox(o, dir, out, ws0 - fw, ws1 + fw, wy1, wy1 + fw, 0.0, 0.07, true, true, true)
	if win.get("arch", false):
		_wbox(o, dir, out, (ws0 + ws1) * 0.5 - 0.18, (ws0 + ws1) * 0.5 + 0.18, wy1 - 0.05, wy1 + 0.4, 0.0, 0.12)  # keystone
	if win.get("sill", false):
		_wbox(o, dir, out, ws0 - 0.14, ws1 + 0.14, wy0 - 0.13, wy0, 0.0, 0.17)
	var top := wy1 + (fw if win.get("surround", false) else 0.0)
	match int(win.get("sandrik", 0)):
		1:
			_wbox(o, dir, out, ws0 - 0.3, ws1 + 0.3, top + 0.1, top + 0.32, 0.0, 0.24)
		2:
			var s0 := ws0 - 0.32
			var s1 := ws1 + 0.32
			var yb := top + 0.1
			var apex := yb + 0.75
			var sc := (s0 + s1) * 0.5
			_wbox(o, dir, out, s0, s1, yb, yb + 0.14, 0.0, 0.22, false, true, true)
			# tympanum and the two raking cornices
			k.tri(_pt(o, dir, out, s0 + 0.15, yb + 0.14, 0.06), _pt(o, dir, out, s1 - 0.15, yb + 0.14, 0.06),
				_pt(o, dir, out, sc, apex - 0.12, 0.06), out)
			for side in [-1.0, 1.0]:
				var se: float = s0 if side < 0.0 else s1
				var a := _pt(o, dir, out, se, yb + 0.14, 0.0)
				var b := _pt(o, dir, out, sc, apex, 0.0)
				var a2 := _pt(o, dir, out, se, yb + 0.14, 0.24)
				var b2 := _pt(o, dir, out, sc, apex, 0.24)
				var slope_n := (b - a).normalized().cross(out)
				if slope_n.y < 0.0:
					slope_n = -slope_n
				var lift := Vector3(0, 0.14, 0)
				k.quad(a2, b2, b2 + lift, a2 + lift, out)                            # front face
				k.quad(a + lift, b + lift, b2 + lift, a2 + lift, slope_n)           # top (snow)
	k.kind = keep_kind
	k.color = keep_col


## A classical facade: floors of window bays, cut-out openings, dressing, pilasters.
func _facade(o: Vector3, dir: Vector3, out: Vector3, length: float, floors: Array, pilasters: bool, _skip: float) -> void:
	if length < 2.0:
		return
	var n_bays := maxi(int(floor((length - 1.4) / BAY)), 0)
	var margin := (length - n_bays * BAY) * 0.5
	for f: Dictionary in floors:
		var y0: float = f["y0"]
		var y1: float = f["y1"]
		var rustic: bool = f.get("rustic", false)
		k.kind = Kit.K_RUSTIC if rustic else Kit.K_STUCCO
		k.color = Color(WALL_COLOR.r, WALL_COLOR.g, WALL_COLOR.b, 0)
		_wq(o, dir, out, 0.0, margin, y0, y1)
		_wq(o, dir, out, length - margin, length, y0, y1)
		var win: Dictionary = f["win"]
		for b in n_bays:
			var s0 := margin + b * BAY
			var s1 := s0 + BAY
			var sc := s0 + BAY * 0.5
			var w: float = win["w"]
			var ws0 := sc - w * 0.5
			var ws1 := sc + w * 0.5
			var wy0: float = y0 + float(win["bottom"])
			var wy1: float = wy0 + float(win["h"])
			_cell_with_hole(o, dir, out, s0, s1, y0, y1, ws0, ws1, wy0, wy1, win["arch"])
			_opening(o, dir, out, ws0, ws1, wy0, wy1, win["arch"], win["depth"], Kit.K_GLASS, win["lit"])
			_dressing(o, dir, out, ws0, ws1, wy0, wy1, win)
	# granite plinth along the foot of the wall
	k.kind = Kit.K_STONE
	k.color = Color(STONE_COLOR.r, STONE_COLOR.g, STONE_COLOR.b, 0)
	_wbox(o, dir, out, -0.1, length + 0.1, -0.2, 0.75, 0.0, 0.12, true, false, false)
	# belt course between the rusticated ground floor and the upper floors
	k.kind = Kit.K_TRIM
	k.color = Color(TRIM_COLOR.r, TRIM_COLOR.g, TRIM_COLOR.b, 0)
	var g: float = floors[0]["y1"]
	_wbox(o, dir, out, -0.15, length + 0.15, g - 0.12, g + 0.22, 0.0, 0.2)
	if pilasters and n_bays > 0:
		var top: float = floors[floors.size() - 1]["y1"]
		for b in n_bays + 1:
			var s := margin + b * BAY
			_wbox(o, dir, out, s - 0.36, s + 0.36, g + 0.22, top - 0.35, 0.0, 0.14, false, false, true)    # shaft
			_wbox(o, dir, out, s - 0.46, s + 0.46, top - 0.35, top - 0.1, 0.0, 0.2)                          # capital
			_wbox(o, dir, out, s - 0.44, s + 0.44, g + 0.22, g + 0.55, 0.0, 0.18, true, false, true)          # base


# ------------------------------------------------------------------ main facade
func _steps(pc: float, pw: float) -> void:
	k.kind = Kit.K_STONE
	k.color = Color(STONE_COLOR.r, STONE_COLOR.g, STONE_COLOR.b, 0)
	var n := 4
	for i in n:
		var z0 := -2.6 + 0.65 * i
		k.box(Vector3(pc - pw * 0.5 - 0.9, 0.0, z0), Vector3(pc + pw * 0.5 + 0.9, 0.18 * (i + 1), 0.05), ["y-", "z+"])
	k.collide_ramp(pc - pw * 0.5 - 0.9, pc + pw * 0.5 + 0.9, -2.6, 0.0, 0.0, 0.72)


func _portico(pc: float, pw: float, pd: float, eave: float, hall_h: float) -> void:
	var x0 := pc - pw * 0.5
	var x1 := pc + pw * 0.5
	var g := 5.6
	var col_top := eave + 0.7       # entablature starts here
	var ent_top := col_top + 1.9    # top of the cornice = base of the pediment
	var apex := hall_h - 0.25
	var wall := Color(WALL_COLOR.r, WALL_COLOR.g, WALL_COLOR.b, 0)
	var trim := Color(TRIM_COLOR.r, TRIM_COLOR.g, TRIM_COLOR.b, 0)

	# Ground floor of the portico: rusticated wall with five arched doors.
	var o := Vector3(x0, 0, 0)
	k.kind = Kit.K_RUSTIC
	k.color = wall
	var n_doors := 5
	var bay := pw / n_doors
	for b in n_doors:
		var s0 := b * bay
		var sc := s0 + bay * 0.5
		var ws0 := sc - 1.1
		var ws1 := sc + 1.1
		_cell_with_hole(o, Vector3.RIGHT, Vector3.FORWARD, s0, s0 + bay, 0.0, g, ws0, ws1, 0.72, 4.75, true)
		_opening(o, Vector3.RIGHT, Vector3.FORWARD, ws0, ws1, 0.72, 4.75, true, 0.6, Kit.K_DOOR, 1.0)
		k.kind = Kit.K_TRIM
		k.color = trim
		_wbox(o, Vector3.RIGHT, Vector3.FORWARD, sc - 0.2, sc + 0.2, 4.7, 5.15, 0.0, 0.14)  # keystone
		k.kind = Kit.K_RUSTIC
		k.color = wall
	# sides of the portico block
	k.kind = Kit.K_RUSTIC
	_wq(Vector3(x0, 0, pd), Vector3.FORWARD, Vector3.LEFT, 0.0, pd, 0.0, g)
	_wq(Vector3(x1, 0, 0), Vector3.BACK, Vector3.RIGHT, 0.0, pd, 0.0, g)

	# Loggia floor, back wall with the foyer windows, side piers, ceiling.
	k.kind = Kit.K_STONE
	k.color = Color(STONE_COLOR.r, STONE_COLOR.g, STONE_COLOR.b, 0)
	k.box(Vector3(x0, g - 0.25, -0.05), Vector3(x1, g, pd), ["y-", "z+"])
	k.kind = Kit.K_STUCCO
	k.color = wall
	var lo := Vector3(x0, 0, pd)
	for b in n_doors:
		var s0 := b * bay
		var sc := s0 + bay * 0.5
		_cell_with_hole(lo, Vector3.RIGHT, Vector3.FORWARD, s0, s0 + bay, g, g + 5.4, sc - 0.95, sc + 0.95, g + 0.6, g + 5.0, true)
		_opening(lo, Vector3.RIGHT, Vector3.FORWARD, sc - 0.95, sc + 0.95, g + 0.6, g + 5.0, true, 0.35, Kit.K_GLASS, 0.95)
		_cell_with_hole(lo, Vector3.RIGHT, Vector3.FORWARD, s0, s0 + bay, g + 5.4, col_top, sc - 0.85, sc + 0.85, g + 6.1, g + 8.5, false)
		_opening(lo, Vector3.RIGHT, Vector3.FORWARD, sc - 0.85, sc + 0.85, g + 6.1, g + 8.5, false, 0.3, Kit.K_GLASS, 0.85)
		_dressing(lo, Vector3.RIGHT, Vector3.FORWARD, sc - 0.85, sc + 0.85, g + 6.1, g + 8.5,
			{"surround": true, "sill": true, "sandrik": 0})
	var pier := 0.7
	k.box(Vector3(x0, g, 0.0), Vector3(x0 + pier, col_top, pd), ["y-", "y+"])
	k.box(Vector3(x1 - pier, g, 0.0), Vector3(x1, col_top, pd), ["y-", "y+"])
	k.quad(Vector3(x0, col_top, 0), Vector3(x1, col_top, 0), Vector3(x1, col_top, pd), Vector3(x0, col_top, pd), Vector3.DOWN)

	# Colonnade: bases, shafts with entasis, Corinthian-like capitals.
	k.kind = Kit.K_TRIM
	k.color = trim
	var zc := 0.55
	var span := pw - 2.0 * pier - 1.4
	var cols := COLUMNS
	var col_x: Array[float] = []
	for i in cols:
		col_x.append(x0 + pier + 0.7 + span * float(i) / (cols - 1))
	for cx in col_x:
		var base_y := g
		k.box(Vector3(cx - 0.62, base_y, zc - 0.62), Vector3(cx + 0.62, base_y + 0.5, zc + 0.62), ["y-"])  # pedestal
		var shaft_h := col_top - 0.95 - (base_y + 0.85)
		var prof: Array = [[0.5, 0.58], [0.62, 0.58], [0.68, 0.52], [0.85, 0.5]]
		for j in range(1, 9):
			var t := float(j) / 8.0
			var ent := 0.5 - 0.09 * t * t + 0.02 * sin(t * PI)  # entasis
			prof.append([0.85 + shaft_h * t, ent])
		var cap0: float = 0.85 + shaft_h
		prof.append_array([[cap0, 0.46], [cap0 + 0.12, 0.5], [cap0 + 0.55, 0.58], [cap0 + 0.8, 0.72], [cap0 + 0.8, 0.0]])
		k.lathe(Vector3(cx, base_y, zc), prof, 14)
		k.box(Vector3(cx - 0.78, col_top - 0.15, zc - 0.78), Vector3(cx + 0.78, col_top, zc + 0.78), ["y+"])  # abacus
	# Balustrade between the columns.
	for i in cols - 1:
		var a := col_x[i] + 0.62
		var b2 := col_x[i + 1] - 0.62
		k.box(Vector3(a, g, zc - 0.28), Vector3(b2, g + 0.18, zc + 0.28), ["y-"])
		k.box(Vector3(a, g + 0.95, zc - 0.3), Vector3(b2, g + 1.12, zc + 0.3), [])
		var nb := int((b2 - a) / 0.32)
		for j in nb:
			var bx := a + (j + 0.5) * (b2 - a) / nb
			k.lathe(Vector3(bx, g + 0.18, zc), [[0.0, 0.07], [0.08, 0.1], [0.3, 0.12], [0.5, 0.06], [0.7, 0.07], [0.77, 0.09]], 6)

	# Entablature (architrave, frieze, cornice) with returns along the sides.
	var tiers := [[col_top, col_top + 0.6, -0.05], [col_top + 0.6, col_top + 1.25, -0.02],
		[col_top + 1.25, col_top + 1.5, 0.25], [col_top + 1.5, ent_top, 0.6]]
	for t: Array in tiers:
		var d: float = t[2]
		k.box(Vector3(x0 - maxf(d, 0.0) - 0.1, t[0], -maxf(d, 0.0) - 0.05), Vector3(x1 + maxf(d, 0.0) + 0.1, t[1], pd + 0.2), ["z+"])
	# dentils under the crowning cornice
	var nd := int((pw + 1.0) / 0.36)
	for i in nd:
		var dx := x0 - 0.3 + (i + 0.5) * (pw + 0.6) / nd
		k.box(Vector3(dx - 0.09, col_top + 1.33, -0.3), Vector3(dx + 0.09, col_top + 1.5, -0.05), ["y+", "z+"])

	# Pediment: recessed tympanum, raking cornices, relief.
	var px0 := x0 - 0.7
	var px1 := x1 + 0.7
	k.kind = Kit.K_STUCCO
	k.color = wall
	k.tri(Vector3(x0, ent_top, 0.35), Vector3(x1, ent_top, 0.35), Vector3(pc, apex - 0.5, 0.35), Vector3.FORWARD)
	k.kind = Kit.K_TRIM
	k.color = trim
	for side in [-1.0, 1.0]:
		var ex: float = px0 if side < 0.0 else px1
		var a := Vector3(ex, ent_top, -0.65)
		var b := Vector3(pc, apex, -0.65)
		var a_back := Vector3(ex, ent_top, pd + 0.2)
		var b_back := Vector3(pc, apex, pd + 0.2)
		var lift := Vector3(0, 0.55, 0)
		var slope := (b - a).normalized()
		var top_n := Vector3(-side * absf(slope.y), absf(slope.x), 0).normalized()
		k.quad(a, b, b + lift, a + lift, Vector3.FORWARD)                       # front of the raking cornice
		k.quad(a + lift, b + lift, b_back + lift, a_back + lift, top_n)        # its top, under the roof
		k.quad(a, b, b_back, a_back, -top_n)                                   # soffit
	_relief(pc, ent_top, apex)


## Stylised State Emblem of the USSR in the tympanum (globe, wreath of ears, ribbon, star).
func _relief(pc: float, ent_top: float, apex: float) -> void:
	k.kind = Kit.K_RELIEF
	k.color = Color(TRIM_COLOR.r, TRIM_COLOR.g, TRIM_COLOR.b, 0)
	var cy := ent_top + (apex - ent_top) * 0.42
	var z := 0.35
	var r := 0.95
	# globe: a shallow faceted dome
	var segs := 16
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var p0 := Vector3(pc + cos(a0) * r, cy + sin(a0) * r, z)
		var p1 := Vector3(pc + cos(a1) * r, cy + sin(a1) * r, z)
		var q0 := Vector3(pc + cos(a0) * r * 0.6, cy + sin(a0) * r * 0.6, z - 0.22)
		var q1 := Vector3(pc + cos(a1) * r * 0.6, cy + sin(a1) * r * 0.6, z - 0.22)
		var mid := (Vector3(cos(a0), sin(a0), 0) + Vector3(cos(a1), sin(a1), 0)).normalized()
		k.quad(p0, p1, q1, q0, (mid + Vector3(0, 0, -1.2)).normalized())
		k.tri(q0, q1, Vector3(pc, cy, z - 0.3), Vector3.FORWARD)
	# wreath: ears of wheat up both sides
	for side in [-1.0, 1.0]:
		for j in 9:
			var a := deg_to_rad(-70.0 + j * 18.0)
			var rr := r + 0.35 + 0.05 * sin(j * 1.7)
			var ex: float = pc + float(side) * cos(a) * rr
			var ey: float = cy + sin(a) * rr
			k.box(Vector3(ex - 0.14, ey - 0.2, z - 0.2), Vector3(ex + 0.14, ey + 0.2, z), ["z+"])
	# ribbon at the bottom and the star at the top
	k.box(Vector3(pc - 1.1, cy - r - 0.65, z - 0.15), Vector3(pc + 1.1, cy - r - 0.3, z), ["z+"])
	var sc := Vector3(pc, cy + r + 0.75, z - 0.18)
	for i in 5:
		var a0 := PI * 0.5 + TAU * i / 5.0
		var a1 := a0 + TAU / 10.0
		var a2 := a0 - TAU / 10.0
		var tip := sc + Vector3(cos(a0), sin(a0), 0) * 0.42
		var in1 := sc + Vector3(cos(a1), sin(a1), 0) * 0.17
		var in2 := sc + Vector3(cos(a2), sin(a2), 0) * 0.17
		k.tri(sc, in2, tip, Vector3.FORWARD)
		k.tri(sc, tip, in1, Vector3.FORWARD)


# ------------------------------------------------------------------ cornice and roofs
func _main_cornice(width: float, length: float, pd: float, eave: float, pc: float, pw: float) -> void:
	k.kind = Kit.K_TRIM
	k.color = Color(TRIM_COLOR.r, TRIM_COLOR.g, TRIM_COLOR.b, 0)
	var hw := width * 0.5
	var tiers := [[eave - 0.6, eave - 0.25, 0.25], [eave - 0.25, eave, 0.6]]
	for t: Array in tiers:
		var d: float = t[2]
		var y0: float = t[0]
		var y1: float = t[1]
		# long sides and back
		k.box(Vector3(hw, y0, pd - d), Vector3(hw + d, y1, length + d), ["x-"])
		k.box(Vector3(-hw - d, y0, pd - d), Vector3(-hw, y1, length + d), ["x+"])
		k.box(Vector3(-hw - d, y0, length), Vector3(hw + d, y1, length + d), ["z-"])
		# front of the wings, either side of the portico
		k.box(Vector3(-hw - d, y0, pd - d), Vector3(pc - pw * 0.5, y1, pd), ["z+"])
		k.box(Vector3(pc + pw * 0.5, y0, pd - d), Vector3(hw + d, y1, pd), ["z+"])


func _body_roof(width: float, length: float, pd: float, eave: float, top: float) -> void:
	k.kind = Kit.K_ROOF
	k.color = Color(ROOF_COLOR.r, ROOF_COLOR.g, ROOF_COLOR.b, 0)
	var o := 0.6
	var inset := 5.0
	var a := [Vector3(-width * 0.5 - o, eave, pd - o), Vector3(width * 0.5 + o, eave, pd - o),
		Vector3(width * 0.5 + o, eave, length + o), Vector3(-width * 0.5 - o, eave, length + o)]
	var b := [Vector3(-width * 0.5 + inset, top, pd + inset), Vector3(width * 0.5 - inset, top, pd + inset),
		Vector3(width * 0.5 - inset, top, length - inset), Vector3(-width * 0.5 + inset, top, length - inset)]
	for i in 4:
		var j := (i + 1) % 4
		var ai: Vector3 = a[i]
		var aj: Vector3 = a[j]
		var bi: Vector3 = b[i]
		var bj: Vector3 = b[j]
		var inward: Vector3 = (bi + bj) * 0.5 - (ai + aj) * 0.5
		var nm: Vector3 = Vector3(-inward.x, 0, -inward.z).normalized() * (top - eave) + Vector3(0, inset, 0)
		var run: float = ai.distance_to(aj)
		k.quad(ai, aj, bj, bi, nm.normalized(), Vector2(0, 0), Vector2(run, 0), Vector2(run, 5), Vector2(0, 5))
	k.quad(b[0] as Vector3, b[1] as Vector3, b[2] as Vector3, b[3] as Vector3, Vector3.UP)
	# eaves soffit
	for i in 4:
		var j := (i + 1) % 4
		var ai: Vector3 = a[i]
		var aj: Vector3 = a[j]
		k.quad(ai, aj, aj + Vector3(0, -0.02, 0), ai + Vector3(0, -0.02, 0), Vector3.DOWN)


func _hall_roof(hall: Dictionary, pd: float, eave: float) -> void:
	var r: Rect2 = hall["rect"]
	var x0 := r.position.x
	var x1 := r.end.x
	var z1 := r.end.y
	var ridge := float(hall["h"]) - 0.2
	var ent_top := eave + 0.7 + 1.9
	var wall := Color(WALL_COLOR.r, WALL_COLOR.g, WALL_COLOR.b, 0)
	# side walls of the auditorium above the main roof, behind the portico
	k.kind = Kit.K_STUCCO
	k.color = wall
	k.quad(Vector3(x0, eave - 1.0, pd), Vector3(x0, eave - 1.0, z1), Vector3(x0, ent_top, z1), Vector3(x0, ent_top, pd), Vector3.LEFT,
		Vector2(pd, eave), Vector2(z1, eave), Vector2(z1, ent_top), Vector2(pd, ent_top))
	k.quad(Vector3(x1, eave - 1.0, pd), Vector3(x1, eave - 1.0, z1), Vector3(x1, ent_top, z1), Vector3(x1, ent_top, pd), Vector3.RIGHT,
		Vector2(pd, eave), Vector2(z1, eave), Vector2(z1, ent_top), Vector2(pd, ent_top))
	k.tri(Vector3(x0, ent_top, z1), Vector3(x1, ent_top, z1), Vector3((x0 + x1) * 0.5, ridge, z1), Vector3.BACK)
	k.quad(Vector3(x0, eave - 1.0, z1), Vector3(x1, eave - 1.0, z1), Vector3(x1, ent_top, z1), Vector3(x0, ent_top, z1), Vector3.BACK)
	# gabled roof, overhanging the pediment
	k.kind = Kit.K_ROOF
	k.color = Color(ROOF_COLOR.r, ROOF_COLOR.g, ROOF_COLOR.b, 0)
	var xc := (x0 + x1) * 0.5
	var zf := -0.7
	var ov := 0.75
	var slope_l := Vector3(-(ridge - ent_top), (xc - x0 + ov), 0).normalized()
	var slope_r := Vector3(ridge - ent_top, (x1 + ov - xc), 0).normalized()
	k.quad(Vector3(x0 - ov, ent_top + 0.55, zf), Vector3(x0 - ov, ent_top + 0.55, z1), Vector3(xc, ridge + 0.55, z1), Vector3(xc, ridge + 0.55, zf), slope_l,
		Vector2(zf, 0), Vector2(z1, 0), Vector2(z1, 11), Vector2(zf, 11))
	k.quad(Vector3(x1 + ov, ent_top + 0.55, zf), Vector3(x1 + ov, ent_top + 0.55, z1), Vector3(xc, ridge + 0.55, z1), Vector3(xc, ridge + 0.55, zf), slope_r,
		Vector2(zf, 0), Vector2(z1, 0), Vector2(z1, 11), Vector2(zf, 11))


func _stage_house(stage: Dictionary, eave: float) -> void:
	var r: Rect2 = stage["rect"]
	var x0 := r.position.x
	var x1 := r.end.x
	var z0 := r.position.y
	var z1 := r.end.y
	var top := float(stage["h"])
	var wall_top := top - 3.2
	var wall := Color(WALL_COLOR.r, WALL_COLOR.g, WALL_COLOR.b, 0)
	k.kind = Kit.K_STUCCO
	k.color = wall
	var y0 := eave - 1.0
	k.box(Vector3(x0, y0, z0), Vector3(x1, wall_top, z1), ["y-", "y+"])
	# a few small windows high on the long sides of the stage house
	for side in [0, 1]:
		var xs: float = x0 if side == 0 else x1
		var out := Vector3.LEFT if side == 0 else Vector3.RIGHT
		for i in 3:
			var zc := z0 + (z1 - z0) * (i + 1) / 4.0
			k.kind = Kit.K_GLASS
			k.color = Color(0.15, 0.5, 0, _rng.randf())
			var zz0 := zc - 0.6
			var zz1 := zc + 0.6
			k.quad(Vector3(xs + out.x * 0.02, wall_top - 3.2, zz0), Vector3(xs + out.x * 0.02, wall_top - 3.2, zz1),
				Vector3(xs + out.x * 0.02, wall_top - 1.6, zz1), Vector3(xs + out.x * 0.02, wall_top - 1.6, zz0), out,
				Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	k.kind = Kit.K_TRIM
	k.color = Color(TRIM_COLOR.r, TRIM_COLOR.g, TRIM_COLOR.b, 0)
	k.box(Vector3(x0 - 0.35, wall_top - 0.4, z0 - 0.35), Vector3(x1 + 0.35, wall_top, z1 + 0.35), ["y-"])
	# gabled roof, ridge across the building, gables at the sides
	var zc := (z0 + z1) * 0.5
	k.kind = Kit.K_STUCCO
	k.color = wall
	k.tri(Vector3(x0, wall_top, z0), Vector3(x0, wall_top, z1), Vector3(x0, top - 0.3, zc), Vector3.LEFT)
	k.tri(Vector3(x1, wall_top, z0), Vector3(x1, wall_top, z1), Vector3(x1, top - 0.3, zc), Vector3.RIGHT)
	k.kind = Kit.K_ROOF
	k.color = Color(ROOF_COLOR.r, ROOF_COLOR.g, ROOF_COLOR.b, 0)
	var ov := 0.5
	var n_front := Vector3(0, zc - z0 + ov, -(top - wall_top)).normalized()
	var n_back := Vector3(0, z1 + ov - zc, top - wall_top).normalized()
	k.quad(Vector3(x0 - ov, wall_top - 0.1, z0 - ov), Vector3(x1 + ov, wall_top - 0.1, z0 - ov), Vector3(x1 + ov, top, zc), Vector3(x0 - ov, top, zc), n_front,
		Vector2(x0, 0), Vector2(x1, 0), Vector2(x1, 10), Vector2(x0, 10))
	k.quad(Vector3(x0 - ov, wall_top - 0.1, z1 + ov), Vector3(x1 + ov, wall_top - 0.1, z1 + ov), Vector3(x1 + ov, top, zc), Vector3(x0 - ov, top, zc), n_back,
		Vector2(x0, 0), Vector2(x1, 0), Vector2(x1, 10), Vector2(x0, 10))
