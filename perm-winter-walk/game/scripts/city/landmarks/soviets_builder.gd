extends RefCounted
## House of Soviets (Дом Советов), Lenina 51: the Perm Krai government and Legislative
## Assembly, opened in 1973, closing the Esplanade from the east with its long facade.
##
## A ten-storey "horizontal skyscraper" on a rectangular plan. Its grey look is set by
## glass and thin lines of light marble: ribbon windows over grey spandrel bands, slender
## marble fins and floor lines. A long recessed loggia runs the length of the facade at
## the 7th floor (the "slot"), and a huge chased emblem of the RSFSR hangs on the facade. The
## ground floor is glazed behind square pillars; stepped granite terraces with wide stairs
## lead down to a square with a fountain in front.
##
## Local frame as in opera_builder.gd: x along the facade, z from the facade (0) to the back.

const Kit := preload("res://scripts/city/landmarks/mesh_kit.gd")

const MARBLE := Color(0.86, 0.86, 0.84)
const GREY := Color(0.46, 0.47, 0.48)
const GRANITE := Color(0.33, 0.32, 0.32)
const ROOF := Color(0.3, 0.31, 0.32)

const GROUND_H := 5.0
const FLOOR_H := 3.3
const SLOT_FLOOR := 7

var k := Kit.new()
var _rng := RandomNumberGenerator.new()


func build(lm: Dictionary) -> Dictionary:
	_rng.seed = 1973
	var fr: Dictionary = lm.get("frame", {})
	var w: float = fr.get("width", 110.0)
	var l: float = fr.get("length", 25.0)
	var levels := int(lm.get("levels", 10) if lm.get("levels") != null else 10)
	levels = clampi(levels, 4, 30)
	var hw := w * 0.5
	var top := GROUND_H + (levels - 1) * FLOOR_H

	_terraces(hw)
	_ground_floor(hw)
	_facade(Vector3(-hw, 0, 0), Vector3.RIGHT, Vector3.FORWARD, w, levels, true)
	_facade(Vector3(hw, 0, l), Vector3.LEFT, Vector3.BACK, w, levels, false)
	_end_wall(Vector3(-hw, 0, l), Vector3.FORWARD, Vector3.LEFT, l, top)
	_end_wall(Vector3(hw, 0, 0), Vector3.BACK, Vector3.RIGHT, l, top)
	# Back of the ground floor and its ends (the front is glazed, see _ground_floor).
	_mat(Kit.K_STUCCO, GREY)
	k.wall(Vector3(hw, 0, l), Vector3(-hw, 0, l), 0.0, GROUND_H, Vector3.BACK)

	# Roof: parapet with a marble cap, machine rooms, a flagpole with the flag of Russia.
	_mat(Kit.K_ROOF, ROOF)
	k.quad(Vector3(-hw, top, 0), Vector3(hw, top, 0), Vector3(hw, top, l), Vector3(-hw, top, l), Vector3.UP)
	_mat(Kit.K_MARBLE, MARBLE)
	k.box(Vector3(-hw - 0.2, top, -0.2), Vector3(hw + 0.2, top + 1.0, 0.3), ["y-"])
	k.box(Vector3(-hw - 0.2, top, l - 0.3), Vector3(hw + 0.2, top + 1.0, l + 0.2), ["y-"])
	k.box(Vector3(-hw - 0.2, top, 0.3), Vector3(-hw + 0.3, top + 1.0, l - 0.3), ["y-"])
	k.box(Vector3(hw - 0.3, top, 0.3), Vector3(hw + 0.2, top + 1.0, l - 0.3), ["y-"])
	_mat(Kit.K_STUCCO, GREY)
	k.box(Vector3(-12.0, top, l * 0.3), Vector3(-4.0, top + 3.2, l * 0.75), ["y-"])
	k.box(Vector3(6.0, top, l * 0.3), Vector3(13.0, top + 3.2, l * 0.75), ["y-"])
	_flag(Vector3(0.0, top, 2.5))  # near the front so it shows over the parapet

	_fountain(Vector3(0, 0, -32.0))
	var o: Array = fr.get("origin", [lm.get("x", 0.0), lm.get("z", 0.0)])
	var u: Array = fr.get("u", [1.0, 0.0])
	var v: Array = fr.get("v", [0.0, 1.0])
	return {"arrays": k.arrays(), "colliders": k.colliders,
			"transform": Transform3D(Basis(Vector3(u[0], 0, u[1]), Vector3.UP, Vector3(v[0], 0, v[1])), Vector3(o[0], 0, o[1])),
			"front": -Vector3(v[0], 0, v[1]), "triangles": k.tri_count()}


func _mat(kind: int, c: Color) -> void:
	k.kind = kind
	k.color = Color(c.r, c.g, c.b, _rng.randf())


func box2(a: Vector3, b: Vector3, skip: Array = []) -> void:
	k.box(a.min(b), a.max(b), skip)


## Two stepped granite terraces with wide central stairs and low parapets.
func _terraces(hw: float) -> void:
	var t1 := [-18.0, -9.0, 0.6]   # z0, z1, height
	var t2 := [-9.0, 0.0, 1.2]
	var thw := minf(hw * 0.85, 48.0)
	_mat(Kit.K_STONE, GRANITE)
	for t: Array in [t1, t2]:
		k.box(Vector3(-thw, 0.0, t[0]), Vector3(thw, t[2], t[1]), ["y-"])
		k.collide_box(Vector3(-thw, 0.0, t[0]), Vector3(thw, t[2], t[1]))
	var shw := 14.0
	for s: Array in [[t1[0], 0.0, 0.6], [t2[0], 0.6, 0.6]]:
		var z_top: float = s[0]
		var y0: float = s[1]
		var rise: float = s[2]
		var n := 4
		for i in n:
			var zs := z_top - 0.5 * (n - i)
			k.box(Vector3(-shw, y0, zs), Vector3(shw, y0 + rise * (i + 1) / n, z_top), ["y-", "z+"])
		k.collide_ramp(-shw, shw, z_top - 0.5 * n, z_top, y0, rise)
	# parapets along the terrace fronts, broken by the stairs
	_mat(Kit.K_MARBLE, MARBLE)
	for t: Array in [t1, t2]:
		for side: float in [-1.0, 1.0]:
			var x_in: float = side * shw
			var x_out: float = side * thw
			box2(Vector3(x_in, t[2], t[0]), Vector3(x_out, t[2] + 0.55, t[0] + 0.4))


func _ground_floor(hw: float) -> void:
	_mat(Kit.K_GLASSWALL, Color(0.75, 0.6, 0))
	var gz := 3.0
	k.quad(Vector3(-hw, 0, gz), Vector3(hw, 0, gz), Vector3(hw, GROUND_H, gz), Vector3(-hw, GROUND_H, gz), Vector3.FORWARD,
		Vector2(-hw, 0), Vector2(hw, 0), Vector2(hw, GROUND_H), Vector2(-hw, GROUND_H))
	_mat(Kit.K_MARBLE, MARBLE)
	var n := int(hw * 2.0 / 6.0)
	for i in n + 1:
		var x := -hw + hw * 2.0 * float(i) / n
		k.box(Vector3(x - 0.45, 0, -0.45), Vector3(x + 0.45, GROUND_H, 0.45), ["y-", "y+"])
	# soffit of the floors above
	_mat(Kit.K_STUCCO, GREY)
	k.quad(Vector3(-hw, GROUND_H, -0.05), Vector3(hw, GROUND_H, -0.05), Vector3(hw, GROUND_H, gz), Vector3(-hw, GROUND_H, gz), Vector3.DOWN)
	# ground-floor ends
	k.wall(Vector3(-hw, 0, 0), Vector3(-hw, 0, gz), 0.0, GROUND_H, Vector3.LEFT)
	k.wall(Vector3(hw, 0, 0), Vector3(hw, 0, gz), 0.0, GROUND_H, Vector3.RIGHT)


## Long facade: grey spandrels, ribbon windows, marble floor lines and fins; the front one
## also gets the 7th-floor loggia and the state emblem.
func _facade(o: Vector3, dir: Vector3, out: Vector3, length: float, levels: int, front: bool) -> void:
	var p := func(s: float, y: float, d: float) -> Vector3: return o + dir * s + Vector3(0, y, 0) + out * d
	var top := GROUND_H + (levels - 1) * FLOOR_H
	var emblem_s0 := length * 0.5 - 5.5
	var emblem_s1 := length * 0.5 + 5.5
	var emblem_y0 := GROUND_H + (SLOT_FLOOR - 1) * FLOOR_H if front else 1e9  # floors above the slot
	for f in range(1, levels):
		var y0 := GROUND_H + (f - 1) * FLOOR_H
		var y_sill := y0 + 1.0
		var y1 := y0 + FLOOR_H
		var floor_no := f + 1
		if front and floor_no == SLOT_FLOOR:
			_loggia(p, length, y0, y1, out, dir)
			continue
		var segs: Array = [[0.0, length]]
		if front and y0 >= emblem_y0:
			segs = [[0.0, emblem_s0], [emblem_s1, length]]
		for sg: Array in segs:
			var s0: float = sg[0]
			var s1: float = sg[1]
			_mat(Kit.K_STUCCO, GREY)
			k.quad(p.call(s0, y0, 0.0), p.call(s1, y0, 0.0), p.call(s1, y_sill, 0.0), p.call(s0, y_sill, 0.0), out,
				Vector2(s0, y0), Vector2(s1, y0), Vector2(s1, y_sill), Vector2(s0, y_sill))
			_mat(Kit.K_GLASSWALL, Color(0.3, _rng.randf(), 0))  # offices: about a third lit at night
			k.quad(p.call(s0, y_sill, -0.12), p.call(s1, y_sill, -0.12), p.call(s1, y1, -0.12), p.call(s0, y1, -0.12), out,
				Vector2(s0, y_sill), Vector2(s1, y_sill), Vector2(s1, y1 + 0.0), Vector2(s0, y1))
			# marble sill line (snow on it)
			_mat(Kit.K_MARBLE, MARBLE)
			box2(p.call(s0, y_sill - 0.14, 0.0), p.call(s1, y_sill, 0.16))
	# slender marble fins over the whole height of the upper floors
	_mat(Kit.K_MARBLE, MARBLE)
	var n := int(length / 3.0)
	for i in n + 1:
		var s := length * float(i) / n
		if front and s > emblem_s0 - 0.5 and s < emblem_s1 + 0.5:
			box2(p.call(s - 0.1, GROUND_H, 0.0), p.call(s + 0.1, emblem_y0, 0.28))
			continue
		box2(p.call(s - 0.1, GROUND_H, 0.0), p.call(s + 0.1, top, 0.28))
	# the gap on the facade line behind the fins at the loggia floor is filled by _loggia
	if front:
		_emblem_panel(p, emblem_s0, emblem_s1, emblem_y0, top, out)


## The 7th-floor "slot": a loggia recessed 2.4 m along the whole facade.
func _loggia(p: Callable, length: float, y0: float, y1: float, out: Vector3, dir: Vector3) -> void:
	var depth := 2.4
	_mat(Kit.K_GLASSWALL, Color(0.5, 0.4, 0))
	k.quad(p.call(0.0, y0, -depth), p.call(length, y0, -depth), p.call(length, y1, -depth), p.call(0.0, y1, -depth), out,
		Vector2(0, y0), Vector2(length, y0), Vector2(length, y1), Vector2(0, y1))
	_mat(Kit.K_STUCCO, GREY)
	k.quad(p.call(0.0, y0, 0.0), p.call(length, y0, 0.0), p.call(length, y0, -depth), p.call(0.0, y0, -depth), Vector3.UP)
	k.quad(p.call(0.0, y1, 0.0), p.call(length, y1, 0.0), p.call(length, y1, -depth), p.call(0.0, y1, -depth), Vector3.DOWN)
	k.quad(p.call(0.0, y0, 0.0), p.call(0.0, y0, -depth), p.call(0.0, y1, -depth), p.call(0.0, y1, 0.0), dir)
	k.quad(p.call(length, y0, 0.0), p.call(length, y0, -depth), p.call(length, y1, -depth), p.call(length, y1, 0.0), -dir)
	# a low marble balustrade wall along the loggia
	_mat(Kit.K_MARBLE, MARBLE)
	box2(p.call(0.0, y0, 0.0), p.call(length, y0 + 1.0, 0.22))


## Marble panel with the emblem of the RSFSR in chased, gilded metal.
func _emblem_panel(p: Callable, s0: float, s1: float, y0: float, top: float, out: Vector3) -> void:
	_mat(Kit.K_MARBLE, MARBLE)
	box2(p.call(s0, y0, 0.0), p.call(s1, top, 0.35))
	_mat(Kit.K_GOLD, Color(0.8, 0.6, 0.3))
	var centre: Vector3 = p.call((s0 + s1) * 0.5, (y0 + top) * 0.5 - 0.3, 0.35)
	var r := minf((s1 - s0) * 0.21, (top - y0) * 0.22)
	# mesh_kit.emblem faces -z in model space; this facade's normal is `out`.
	if out.is_equal_approx(Vector3.FORWARD):
		k.emblem(centre, r, true)  # the RSFSR emblem, chased in metal


func _end_wall(o: Vector3, dir: Vector3, out: Vector3, length: float, top: float) -> void:
	_mat(Kit.K_STUCCO, GREY)
	k.wall(o, o + dir * length, GROUND_H, top, out)
	_mat(Kit.K_MARBLE, MARBLE)
	box2(o + Vector3(0, GROUND_H, 0), o + dir * 0.8 + out * 0.2 + Vector3(0, top, 0))
	box2(o + dir * (length - 0.8) + Vector3(0, GROUND_H, 0), o + dir * length + out * 0.2 + Vector3(0, top, 0))


func _flag(base: Vector3) -> void:
	_mat(Kit.K_METAL, Color(0.6, 0.6, 0.62))
	k.lathe(base, [[0.0, 0.14], [10.0, 0.07], [10.15, 0.12], [10.3, 0.0]], 8)
	var w := 4.5
	var h := 3.0
	var x0 := base.x + 0.08
	var colors := [Color(0.9, 0.9, 0.9), Color(0.05, 0.25, 0.65), Color(0.8, 0.1, 0.12)]
	for i in 3:
		_mat(Kit.K_TRIM, colors[i])
		var ya := base.y + 9.8 - h * (i + 1) / 3.0
		var yb := ya + h / 3.0
		for nrm: Vector3 in [Vector3.FORWARD, Vector3.BACK]:
			k.quad(Vector3(x0, ya, base.z), Vector3(x0 + w, ya, base.z), Vector3(x0 + w, yb, base.z), Vector3(x0, yb, base.z), nrm)


func _fountain(c: Vector3) -> void:
	_mat(Kit.K_STONE, GRANITE)
	var r := 8.0
	k.lathe(c, [[0.0, r + 0.3], [0.7, r + 0.3], [0.7, r - 0.3], [0.35, r - 0.3], [0.35, 0.0]], 40)
	_mat(Kit.K_MARBLE, MARBLE)
	k.lathe(c + Vector3(0, 0.35, 0), [[0.0, 0.9], [0.5, 0.9], [0.5, 0.5], [1.6, 0.4], [1.7, 1.6], [1.9, 1.6], [1.9, 0.0]], 20)
	k.collide_cylinder(c, r + 0.3, 0.7)
