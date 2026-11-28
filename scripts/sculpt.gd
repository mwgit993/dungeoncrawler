class_name Sculpt
extends RefCounted

## Builds the smooth character meshes out of soft primitives, with the colours painted into the
## vertices. Each body part (one rigid piece on a rig joint) is one Sculpt:
##
##   var s: Sculpt = Sculpt.new()
##   s.blob(Vector3(0, 0.4, 0), Vector3(0.6, 0.45, 0.4), METAL, 0.6)   # rounded torso
##   s.tube([Vector3.ZERO, Vector3(0, -0.5, 0.05)], [0.16, 0.13], DARK)  # a limb
##   mesh_instance.mesh = s.mesh()
##
## blob() is a superellipsoid: roundness 1.0 is an ellipsoid, lower values square it off towards a
## rounded box (0.3 is quite boxy). tube() runs a smooth tube with round caps through points.
## Primitives may overlap; the character shader's outline pass draws a line where they meet.
## Vertex colours are authored in sRGB like every other Color in the game (the shader converts).

const SHADE: float = 0.22  # how much darker the bottom of a blob is than its top

var _verts: PackedVector3Array = PackedVector3Array()
var _norms: PackedVector3Array = PackedVector3Array()
var _cols: PackedColorArray = PackedColorArray()
var _idx: PackedInt32Array = PackedInt32Array()

static var _cache: Dictionary = {}


## Returns the mesh cached under key, building it with build (a Callable returning a Sculpt) the
## first time. Every enemy of a kind shares one set of meshes.
static func cached(key: String, build: Callable) -> ArrayMesh:
	if not _cache.has(key):
		var s: Sculpt = build.call()
		_cache[key] = s.mesh()
	return _cache[key]


static func _spow(x: float, e: float) -> float:
	return signf(x) * pow(absf(x), e)


## A superellipsoid at center with the given radii. taper > 0 widens the top and narrows the
## bottom (a hunched back, a cone-ish fist). rot_deg rotates it like rotation_degrees.
func blob(center: Vector3, radii: Vector3, color: Color, roundness: float = 1.0,
		rot_deg: Vector3 = Vector3.ZERO, taper: float = 0.0, rings: int = 8, segments: int = 14) -> Sculpt:
	var basis: Basis = Basis.from_euler(rot_deg * (PI / 180.0))
	var e: float = clampf(roundness, 0.15, 1.5)
	var base: int = _verts.size()
	var pts: PackedVector3Array = PackedVector3Array()
	var tints: PackedFloat32Array = PackedFloat32Array()
	# Bottom pole, rings from bottom to top, top pole.
	for i: int in range(rings + 2):
		var u: float = -PI * 0.5 + PI * float(i) / float(rings + 1)
		var cu: float = _spow(cos(u), e)
		var su: float = _spow(sin(u), e)
		var count: int = 1 if i == 0 or i == rings + 1 else segments
		for j: int in range(count):
			var v: float = TAU * float(j) / float(segments)
			var p: Vector3 = Vector3(radii.x * cu * _spow(sin(v), e), radii.y * su, radii.z * cu * _spow(cos(v), e))
			if i == 0 or i == rings + 1:
				p = Vector3(0.0, radii.y * su, 0.0)
			var yn: float = su  # -1 at the bottom, 1 at the top
			var widen: float = 1.0 + taper * yn
			p.x *= widen
			p.z *= widen
			pts.append(basis * p + center)
			tints.append(1.0 - SHADE * (1.0 - (yn + 1.0) * 0.5))
	for k: int in range(pts.size()):
		_verts.append(pts[k])
		_norms.append(Vector3.ZERO)
		_cols.append(Color(color.r * tints[k], color.g * tints[k], color.b * tints[k], 1.0))
	var top: int = base + 1 + rings * segments
	for j: int in range(segments):
		var j2: int = (j + 1) % segments
		# Bottom fan.
		_tri(base, base + 1 + j2, base + 1 + j, center)
		# Top fan.
		var r0: int = base + 1 + (rings - 1) * segments
		_tri(top, r0 + j, r0 + j2, center)
	for i: int in range(rings - 1):
		var a: int = base + 1 + i * segments
		var b: int = a + segments
		for j: int in range(segments):
			var j2: int = (j + 1) % segments
			_quad(a + j, a + j2, b + j2, b + j, center)
	return self


## A smooth tube through points (at least 2), radius per point, with rounded ends.
func tube(points: Array[Vector3], radii: Array[float], color: Color, sides: int = 9, steps: int = 3) -> Sculpt:
	# Catmull-Rom resample so a 3-point limb bends smoothly.
	var path: PackedVector3Array = PackedVector3Array()
	var rad: PackedFloat32Array = PackedFloat32Array()
	var n: int = points.size()
	for i: int in range(n - 1):
		var p0: Vector3 = points[maxi(i - 1, 0)]
		var p1: Vector3 = points[i]
		var p2: Vector3 = points[i + 1]
		var p3: Vector3 = points[mini(i + 2, n - 1)]
		var sub: int = steps if n > 2 else 1
		for s: int in range(sub):
			var t: float = float(s) / float(sub)
			path.append(_catmull(p0, p1, p2, p3, t))
			rad.append(lerpf(radii[i], radii[i + 1], t))
	path.append(points[n - 1])
	rad.append(radii[n - 1])
	# Round caps: extra rings that close in over each end.
	var start_dir: Vector3 = (path[0] - path[1]).normalized()
	var end_dir: Vector3 = (path[path.size() - 1] - path[path.size() - 2]).normalized()
	var ring_pos: PackedVector3Array = PackedVector3Array()
	var ring_rad: PackedFloat32Array = PackedFloat32Array()
	var cap: Array[float] = [0.92, 0.7]
	var r_first: float = rad[0]
	ring_pos.append(path[0] + start_dir * r_first * 0.98)
	ring_rad.append(0.0)
	for a: float in cap:
		ring_pos.append(path[0] + start_dir * r_first * sqrt(1.0 - a * a))
		ring_rad.append(r_first * a)
	for i: int in range(path.size()):
		ring_pos.append(path[i])
		ring_rad.append(rad[i])
	var r_last: float = rad[rad.size() - 1]
	for k: int in range(cap.size() - 1, -1, -1):
		var a2: float = cap[k]
		ring_pos.append(path[path.size() - 1] + end_dir * r_last * sqrt(1.0 - a2 * a2))
		ring_rad.append(r_last * a2)
	ring_pos.append(path[path.size() - 1] + end_dir * r_last * 0.98)
	ring_rad.append(0.0)
	# Parallel-transport frames so the tube doesn't twist.
	var base: int = _verts.size()
	var tangent: Vector3 = (path[1] - path[0]).normalized()
	var side: Vector3 = tangent.cross(Vector3.UP if absf(tangent.y) < 0.9 else Vector3.RIGHT).normalized()
	var rows: int = ring_pos.size()
	for i: int in range(rows):
		var t_next: Vector3 = ring_pos[mini(i + 1, rows - 1)] - ring_pos[maxi(i - 1, 0)]
		if t_next.length() > 0.0001:
			var t_dir: Vector3 = t_next.normalized()
			side = (side - t_dir * side.dot(t_dir)).normalized()
			tangent = t_dir
		var up: Vector3 = tangent.cross(side).normalized()
		for j: int in range(sides):
			var ang: float = TAU * float(j) / float(sides)
			_verts.append(ring_pos[i] + (side * cos(ang) + up * sin(ang)) * ring_rad[i])
			_norms.append(Vector3.ZERO)
			_cols.append(color)
	for i: int in range(rows - 1):
		var a: int = base + i * sides
		var b: int = a + sides
		var axis: Vector3 = (ring_pos[i] + ring_pos[i + 1]) * 0.5
		if i == 0:
			axis = ring_pos[1]
		elif i == rows - 2:
			axis = ring_pos[rows - 2]
		for j: int in range(sides):
			var j2: int = (j + 1) % sides
			_quad(a + j, b + j, b + j2, a + j2, axis)
	return self


func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


## Adds a triangle facing away from inside (Godot's front faces wind clockwise).
func _tri(a: int, b: int, c: int, inside: Vector3) -> void:
	var fn: Vector3 = (_verts[c] - _verts[a]).cross(_verts[b] - _verts[a])
	var mid: Vector3 = (_verts[a] + _verts[b] + _verts[c]) / 3.0
	_idx.append(a)
	if fn.dot(mid - inside) < 0.0:
		_idx.append(c)
		_idx.append(b)
	else:
		_idx.append(b)
		_idx.append(c)


func _quad(a: int, b: int, c: int, d: int, inside: Vector3) -> void:
	_tri(a, b, c, inside)
	_tri(a, c, d, inside)


func mesh() -> ArrayMesh:
	# Smooth normals from the faces around each vertex. Godot's front faces wind clockwise.
	var norms: PackedVector3Array = _norms.duplicate()
	for i: int in range(0, _idx.size(), 3):
		var a: int = _idx[i]
		var b: int = _idx[i + 1]
		var c: int = _idx[i + 2]
		var fn: Vector3 = (_verts[c] - _verts[a]).cross(_verts[b] - _verts[a])
		norms[a] += fn
		norms[b] += fn
		norms[c] += fn
	for k: int in range(norms.size()):
		norms[k] = norms[k].normalized() if norms[k].length() > 0.000001 else Vector3.UP
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_INDEX] = _idx
	var m: ArrayMesh = ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
