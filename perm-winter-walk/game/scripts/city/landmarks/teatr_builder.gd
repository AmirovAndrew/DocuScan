extends RefCounted
## Perm Academic Theatre (Teatr-Teatr), Lenina 53: the early-1980s building at the west
## end of the Esplanade.
##
## Late-Soviet modernism in white marble: a long box running east-west, split into the
## ceremonial front (facing the Esplanade) and a lower service block at the back. The front
## has a broad granite porch with wide steps and a parapet carrying six wrought-copper
## lanterns, an arcade of square marble pillars under a deep marble attic, and behind it
## the glazed two-level foyer. The fly tower rises over the middle; a fountain stands on the
## square in front of the entrance. It was first faced with white marble, later with
## porcelain stoneware; the 2020s reconstruction brings the marble back.
##
## Local frame as in opera_builder.gd: x across, z from the main facade (0) to the back.

const Kit := preload("res://scripts/city/landmarks/mesh_kit.gd")

const MARBLE := Color(0.88, 0.87, 0.84)
const GRANITE := Color(0.36, 0.34, 0.34)
const SERVICE := Color(0.58, 0.55, 0.5)
const ROOF := Color(0.32, 0.33, 0.34)
const METAL := Color(0.12, 0.1, 0.08)

var k := Kit.new()
var _rng := RandomNumberGenerator.new()


func build(lm: Dictionary) -> Dictionary:
	_rng.seed = 1981
	var fr: Dictionary = lm.get("frame", {})
	var w: float = fr.get("width", 60.0)
	var l: float = fr.get("length", 100.0)
	var hw := w * 0.5
	var front_d := clampf(l * 0.42, 20.0, 45.0)   # ceremonial part
	var h1 := 17.0                                 # its height
	var porch_hw := minf(hw - 3.0, 30.0)
	var arc_hw := porch_hw - 2.5
	var porch_y := 1.2
	var attic_y := 13.5
	var foyer_z := 7.0

	_porch(porch_hw, porch_y)
	_arcade(arc_hw, porch_y, attic_y, h1, foyer_z)
	# blank marble pylons either side of the arcade, on the facade line
	_mat(Kit.K_MARBLE, MARBLE)
	k.box(Vector3(-hw, 0.0, 0.0), Vector3(-arc_hw - 0.6, h1, 1.0), ["y-", "z+"])
	k.box(Vector3(arc_hw + 0.6, 0.0, 0.0), Vector3(hw, h1, 1.0), ["y-", "z+"])
	# side walls of the ceremonial block, with tall narrow window slits
	for side: float in [-1.0, 1.0]:
		var x := side * hw
		var out := Vector3(side, 0, 0)
		_mat(Kit.K_MARBLE, MARBLE)
		k.wall(Vector3(x, 0, 0), Vector3(x, 0, front_d), 0.0, h1, out)
		for i in 3:
			var zc := front_d * (i + 1) / 4.0
			_mat(Kit.K_GLASS, Color(0.6, _rng.randf(), 0, _rng.randf()))
			k.quad(Vector3(x + side * 0.03, 2.0, zc - 0.7), Vector3(x + side * 0.03, 2.0, zc + 0.7),
				Vector3(x + side * 0.03, 12.0, zc + 0.7), Vector3(x + side * 0.03, 12.0, zc - 0.7), out)
	_flat_roof(Vector3(-hw, h1, 0.0), Vector3(hw, h1, front_d), Kit.K_MARBLE, MARBLE)

	# Fly tower over the stage.
	var fw := minf(w * 0.3, 17.0)
	var fz0 := front_d - 4.0
	var fz1 := minf(fz0 + l * 0.3, l - 4.0)
	_mat(Kit.K_MARBLE, MARBLE)
	k.box(Vector3(-fw, 0.0, fz0), Vector3(fw, 28.0, fz1), ["y-", "y+"])
	_flat_roof(Vector3(-fw, 28.0, fz0), Vector3(fw, 28.0, fz1), Kit.K_MARBLE, MARBLE)

	# Service block at the back: plain plaster, three floors of windows.
	var sh := 12.5
	_mat(Kit.K_STUCCO, SERVICE)
	k.wall(Vector3(-hw, 0, front_d), Vector3(-hw, 0, l), 0.0, sh, Vector3.LEFT)
	k.wall(Vector3(hw, 0, front_d), Vector3(hw, 0, l), 0.0, sh, Vector3.RIGHT)
	k.wall(Vector3(-hw, 0, l), Vector3(hw, 0, l), 0.0, sh, Vector3.BACK)
	_window_rows(Vector3(-hw, 0, front_d), Vector3.BACK, Vector3.LEFT, l - front_d, sh)
	_window_rows(Vector3(hw, 0, front_d), Vector3.BACK, Vector3.RIGHT, l - front_d, sh)
	_window_rows(Vector3(-hw, 0, l), Vector3.RIGHT, Vector3.BACK, w, sh)
	# the step between the two blocks
	_mat(Kit.K_MARBLE, MARBLE)
	k.wall(Vector3(-hw, 0, front_d), Vector3(hw, 0, front_d), sh, h1, Vector3.BACK)
	_flat_roof(Vector3(-hw, sh, front_d), Vector3(hw, sh, l), Kit.K_STUCCO, SERVICE)

	_fountain(Vector3(0, 0, -30.0))
	var o: Array = fr.get("origin", [lm.get("x", 0.0), lm.get("z", 0.0)])
	var u: Array = fr.get("u", [1.0, 0.0])
	var v: Array = fr.get("v", [0.0, 1.0])
	return {"arrays": k.arrays(), "colliders": k.colliders,
			"transform": Transform3D(Basis(Vector3(u[0], 0, u[1]), Vector3.UP, Vector3(v[0], 0, v[1])), Vector3(o[0], 0, o[1])),
			"front": -Vector3(v[0], 0, v[1]), "triangles": k.tri_count()}


func _mat(kind: int, c: Color) -> void:
	k.kind = kind
	k.color = Color(c.r, c.g, c.b, _rng.randf())


## Flat roof with a marble/plaster parapet cap around it.
func _flat_roof(mn: Vector3, mx: Vector3, kind: int, c: Color) -> void:
	_mat(Kit.K_ROOF, ROOF)
	k.quad(Vector3(mn.x, mn.y, mn.z), Vector3(mx.x, mn.y, mn.z), Vector3(mx.x, mn.y, mx.z), Vector3(mn.x, mn.y, mx.z), Vector3.UP)
	_mat(kind, c)
	var y := mn.y
	k.box(Vector3(mn.x - 0.15, y, mn.z - 0.15), Vector3(mx.x + 0.15, y + 0.6, mn.z + 0.35), ["y-"])
	k.box(Vector3(mn.x - 0.15, y, mx.z - 0.35), Vector3(mx.x + 0.15, y + 0.6, mx.z + 0.15), ["y-"])
	k.box(Vector3(mn.x - 0.15, y, mn.z), Vector3(mn.x + 0.35, y + 0.6, mx.z), ["y-"])
	k.box(Vector3(mx.x - 0.35, y, mn.z), Vector3(mx.x + 0.15, y + 0.6, mx.z), ["y-"])


func _porch(phw: float, py: float) -> void:
	var z0 := -9.0
	_mat(Kit.K_STONE, GRANITE)
	k.box(Vector3(-phw, 0.0, z0), Vector3(phw, py, 7.5), ["y-"])
	k.collide_box(Vector3(-phw, 0.0, z0), Vector3(phw, py, 0.0))
	# six broad steps across the front
	var steps := 6
	var rise := py / steps
	for i in steps:
		var zs := z0 - 0.55 * (steps - i)
		k.box(Vector3(-phw + 1.0, 0.0, zs), Vector3(phw - 1.0, rise * (i + 1), z0), ["y-", "z+"])
	k.collide_ramp(-phw + 1.0, phw - 1.0, z0 - 0.55 * steps, z0, 0.0, py)
	# marble parapets along the sides of the porch, carrying the lanterns
	_mat(Kit.K_MARBLE, MARBLE)
	for side: float in [-1.0, 1.0]:
		var x0 := side * phw - (0.7 if side > 0.0 else 0.0)
		k.box(Vector3(x0, py, z0), Vector3(x0 + 0.7, py + 0.95, 0.0), [])
		k.collide_box(Vector3(x0, 0.0, z0), Vector3(x0 + 0.7, py + 0.95, 0.0))
		for j in 3:
			_lantern(Vector3(x0 + 0.35, py + 0.95, z0 + 1.5 + j * 3.0))


## Wrought-copper lantern: pedestal, post, glowing lantern, cap and a little figure.
func _lantern(base: Vector3) -> void:
	_mat(Kit.K_MARBLE, MARBLE)
	k.box(base + Vector3(-0.3, 0, -0.3), base + Vector3(0.3, 0.55, 0.3), ["y-"])
	_mat(Kit.K_METAL, METAL)
	k.lathe(base + Vector3(0, 0.55, 0), [[0.0, 0.12], [0.15, 0.08], [1.6, 0.06], [1.75, 0.16], [1.8, 0.0]], 8)
	var lb := base + Vector3(0, 2.35, 0)
	_mat(Kit.K_LANTERN, Color(1, 1, 1))
	var s := 0.28
	var hgt := 0.85
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		var b := TAU * (i + 1) / 4.0 + PI * 0.25
		var p0 := lb + Vector3(cos(a), 0, sin(a)) * s * 1.414
		var p1 := lb + Vector3(cos(b), 0, sin(b)) * s * 1.414
		var nrm := Vector3(cos((a + b) * 0.5), 0, sin((a + b) * 0.5))
		k.quad(p0, p1, p1 + Vector3(0, hgt, 0), p0 + Vector3(0, hgt, 0), nrm,
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	_mat(Kit.K_METAL, METAL)
	k.lathe(lb + Vector3(0, hgt, 0), [[0.0, 0.42], [0.08, 0.42], [0.45, 0.12], [0.55, 0.1], [0.75, 0.16], [0.95, 0.0]], 8)
	k.box(lb + Vector3(-0.33, -0.08, -0.33), lb + Vector3(0.33, 0.0, 0.33), [])


func _arcade(ahw: float, py: float, attic_y: float, top: float, foyer_z: float) -> void:
	# Two-level glazed foyer behind the pillars.
	_mat(Kit.K_GLASSWALL, Color(0.9, 0.3, 0))
	k.quad(Vector3(-ahw, py, foyer_z), Vector3(ahw, py, foyer_z), Vector3(ahw, attic_y, foyer_z), Vector3(-ahw, attic_y, foyer_z),
		Vector3.FORWARD, Vector2(-ahw, py), Vector2(ahw, py), Vector2(ahw, attic_y), Vector2(-ahw, attic_y))
	_mat(Kit.K_MARBLE, MARBLE)
	k.box(Vector3(-ahw, 7.0, foyer_z - 0.5), Vector3(ahw, 7.6, foyer_z), ["z+"])        # upper foyer floor edge
	# Square marble pillars of the arcade.
	var n := maxi(int(round(ahw * 2.0 / 6.5)) + 1, 3)
	for i in n:
		var x := -ahw + 2.0 * ahw * float(i) / (n - 1)
		k.box(Vector3(x - 0.6, py, -0.6), Vector3(x + 0.6, attic_y, 0.6), ["y-", "y+"])
	# Deep marble attic over the arcade (its underside is the arcade ceiling).
	k.box(Vector3(-ahw - 1.2, attic_y, -0.8), Vector3(ahw + 1.2, top, foyer_z), ["z+"])
	# a thin shadow line under the attic's crown
	k.box(Vector3(-ahw - 1.4, top - 0.9, -1.0), Vector3(ahw + 1.4, top - 0.6, -0.8), ["z+"])


func _window_rows(o: Vector3, dir: Vector3, out: Vector3, length: float, h: float) -> void:
	var floors := 3
	var fh := (h - 1.0) / floors
	var n := int((length - 2.0) / 3.6)
	var margin := (length - n * 3.6) * 0.5
	for f in floors:
		for i in n:
			var s := margin + (i + 0.5) * 3.6
			var y0 := 0.9 + f * fh + 0.9
			_mat(Kit.K_GLASS, Color(0.35, _rng.randf(), 0, _rng.randf()))
			var p := o + dir * s + out * 0.03
			k.quad(p - dir * 0.75 + Vector3(0, y0, 0), p + dir * 0.75 + Vector3(0, y0, 0),
				p + dir * 0.75 + Vector3(0, y0 + 1.8, 0), p - dir * 0.75 + Vector3(0, y0 + 1.8, 0), out,
				Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
			_mat(Kit.K_STONE, Color(0.55, 0.54, 0.52))
			var sp := o + dir * s
			box2(sp - dir * 0.85 + Vector3(0, y0 - 0.1, 0), sp + dir * 0.85 + out * 0.15 + Vector3(0, y0, 0))


## Box from two opposite corners given in any order.
func box2(a: Vector3, b: Vector3) -> void:
	k.box(a.min(b), a.max(b), [])


func _fountain(c: Vector3) -> void:
	_mat(Kit.K_STONE, GRANITE)
	var r := 7.5
	k.lathe(c, [[0.0, r + 0.3], [0.75, r + 0.3], [0.75, r - 0.3], [0.4, r - 0.3], [0.4, 1.4], [0.4, 0.0]], 40)
	_mat(Kit.K_MARBLE, MARBLE)
	k.lathe(c + Vector3(0, 0.4, 0), [[0.0, 1.2], [0.9, 1.0], [0.9, 0.7], [2.4, 0.45], [2.6, 0.9], [2.8, 0.0]], 16)
	k.collide_cylinder(c, r + 0.3, 0.75)
