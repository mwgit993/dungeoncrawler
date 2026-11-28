class_name Fx
extends Node3D

## Short-lived effects: sparks, debris, explosions, shockwave rings, blade slash trails, floating
## damage numbers.
## Each call makes one Fx node that animates its own little particles and frees itself.

const MAX_LIFE: float = 1.2

var _parts: Array[MeshInstance3D] = []
var _vel: Array[Vector3] = []
var _life: Array[float] = []
var _max_life: Array[float] = []
var _grav: float = 0.0
var _ring: MeshInstance3D = null
var _ring_mat: StandardMaterial3D = null
var _ring_r: float = 1.0
var _spin: float = 0.0        # the ring turns this fast (radians a second), for slash trails
var _delay: float = 0.0       # the ring shows up this long after the effect starts
var _label: Label3D = null
var _light: OmniLight3D = null
var _t: float = 0.0
var _ttl: float = 0.5


## Plays an effect the host sent (online co-op), in this machine's current level.
static func replay(parent: Node3D, kind: String, a: Array) -> void:
	match kind:
		"sparks":
			sparks(parent, a[0], a[1], int(a[2]), float(a[3]))
		"debris":
			debris(parent, a[0], a[1], int(a[2]))
		"explosion":
			explosion(parent, a[0], a[1], float(a[2]))
		"shockwave":
			shockwave(parent, a[0], a[1], float(a[2]))
		"number":
			number(parent, a[0], String(a[1]), a[2])
		"afterimage":
			afterimage(parent, a[0], a[1])
		"zap":
			zap(parent, a[0], a[1])
		"slash":
			slash(parent, a[0], a[1], float(a[2]), float(a[3]), a[4], float(a[5]))


static func _make(parent: Node3D, pos: Vector3, ttl: float) -> Fx:
	var fx: Fx = Fx.new()
	fx.position = pos
	fx._ttl = ttl
	parent.add_child(fx)
	return fx


func _add(mesh: Mesh, mat: Material, vel: Vector3, life: float, offset: Vector3 = Vector3.ZERO) -> void:
	var mi: MeshInstance3D = Art.part(self, mesh, mat, offset)
	_parts.append(mi)
	_vel.append(vel)
	_life.append(life)
	_max_life.append(life)


static func sparks(parent: Node3D, pos: Vector3, color: Color, count: int, speed: float) -> void:
	Net.ev("fx", ["sparks", [pos, color, count, speed]])
	var fx: Fx = _make(parent, pos, 0.35)
	fx._grav = 9.0
	var m: StandardMaterial3D = Art.mat(color, 2.5)
	for i: int in range(count):
		var v: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(0.2, 1.2), randf_range(-1.0, 1.0)).normalized() * speed * randf_range(0.5, 1.0)
		fx._add(Art.box(Vector3(0.08, 0.08, 0.08)), m, v, randf_range(0.15, 0.32))


static func debris(parent: Node3D, pos: Vector3, color: Color, count: int) -> void:
	Net.ev("fx", ["debris", [pos, color, count]])
	var fx: Fx = _make(parent, pos, 0.9)
	fx._grav = 16.0
	var m: StandardMaterial3D = Art.mat(color)
	var m2: StandardMaterial3D = Art.mat(color.darkened(0.4))
	for i: int in range(count):
		var v: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(0.8, 1.6), randf_range(-1.0, 1.0)) * randf_range(2.5, 5.5)
		var s: float = randf_range(0.1, 0.24)
		fx._add(Art.box(Vector3(s, s, s)), m if i % 2 == 0 else m2, v, randf_range(0.5, 0.85))


static func explosion(parent: Node3D, pos: Vector3, color: Color, size: float) -> void:
	Net.ev("fx", ["explosion", [pos, color, size]])
	var fx: Fx = _make(parent, pos, 0.6)
	fx._ring_mat = Art.alpha_mat(Color(1.0, 0.85, 0.5, 0.85), true)
	fx._ring = Art.part(fx, Art.ball(0.5, 8), fx._ring_mat, Vector3.ZERO)
	fx._ring_r = size * 1.6
	fx._light = OmniLight3D.new()
	fx._light.light_color = color.lerp(Color(1.0, 0.7, 0.3), 0.5)
	fx._light.light_energy = 3.0
	fx._light.omni_range = size * 4.0
	fx.add_child(fx._light)
	sparks(parent, pos, color.lerp(Color(1.0, 0.8, 0.4), 0.5), 12, 6.0)


static func shockwave(parent: Node3D, pos: Vector3, color: Color, radius: float) -> void:
	Net.ev("fx", ["shockwave", [pos, color, radius]])
	var fx: Fx = _make(parent, pos + Vector3(0.0, 0.1, 0.0), 0.35)
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.85
	torus.outer_radius = 1.0
	torus.rings = 20
	torus.ring_segments = 3
	fx._ring_mat = Art.alpha_mat(Color(color.r, color.g, color.b, 0.9), true)
	fx._ring = Art.part(fx, torus, fx._ring_mat, Vector3.ZERO)
	fx._ring_r = radius
	fx._ring.scale = Vector3(0.2, 1.0, 0.2)
	fx._grav = 10.0
	var m: StandardMaterial3D = Art.mat(color, 1.5)
	for i: int in range(10):
		var a: float = TAU * float(i) / 10.0
		var d: Vector3 = Vector3(cos(a), 0.0, sin(a))
		fx._add(Art.box(Vector3(0.12, 0.12, 0.12)), m, d * radius * 2.6 + Vector3(0.0, 3.0, 0.0), 0.3)


static func number(parent: Node3D, pos: Vector3, text: String, color: Color) -> void:
	Net.ev("fx", ["number", [pos, text, color]])
	var fx: Fx = _make(parent, pos + Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)), 0.7)
	var l: Label3D = Label3D.new()
	l.text = text
	if Art.font != null:
		l.font = Art.font
	l.font_size = 8
	l.pixel_size = 0.045
	l.modulate = color
	l.outline_size = 3
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	fx.add_child(l)
	fx._label = l


static func afterimage(parent: Node3D, pos: Vector3, color: Color) -> void:
	Net.ev("fx", ["afterimage", [pos, color]])
	var fx: Fx = _make(parent, pos, 0.25)
	fx._ring_mat = Art.alpha_mat(Color(color.r, color.g, color.b, 0.5), true)
	fx._ring = Art.part(fx, Art.cylinder(0.6, 0.6, 1.8, 8), fx._ring_mat, Vector3(0.0, 0.9, 0.0))
	fx._ring_r = -1.0


static func zap(parent: Node3D, a: Vector3, b: Vector3) -> void:
	Net.ev("fx", ["zap", [a, b]])
	var fx: Fx = _make(parent, a, 0.18)
	var m: StandardMaterial3D = Art.mat(Color(0.5, 0.9, 1.0), 3.0)
	var steps: int = maxi(int(a.distance_to(b) / 0.4), 2)
	for i: int in range(steps + 1):
		var p: Vector3 = (b - a) * (float(i) / float(steps))
		if i > 0 and i < steps:
			p += Vector3(randf_range(-0.2, 0.2), randf_range(-0.2, 0.2), randf_range(-0.2, 0.2))
		fx._add(Art.box(Vector3(0.1, 0.1, 0.1)), m, Vector3.ZERO, 0.18, p)


## A blade's swoosh: a glowing flat arc at arm height around pos, centred on dir, from the bot out
## to the blade's reach. sweep 1 swings from the -x side of dir to the +x side, -1 the other way;
## the trail is brightest where the blade ended up and fades back along the swing.
static func slash(parent: Node3D, pos: Vector3, dir: Vector3, radius: float, arc_deg: float, color: Color,
		sweep: float) -> void:
	Net.ev("fx", ["slash", [pos, dir, radius, arc_deg, color, sweep]])
	var fx: Fx = _make(parent, pos, 0.3)
	fx._delay = 0.05  # appears as the arm sweeps through (GorillaRig.slash)
	var half: float = deg_to_rad(arc_deg) * 0.5
	var segs: int = 18
	var verts: PackedVector3Array = PackedVector3Array()
	var cols: PackedColorArray = PackedColorArray()
	var flat: Vector3 = Vector3(dir.x, 0.0, dir.z).normalized()
	if flat == Vector3.ZERO:
		flat = Vector3.FORWARD
	# A crescent: clear on the inside, brightest just inside the blade's reach.
	var bands: Array[Vector2] = [Vector2(0.45, 0.0), Vector2(0.88, 0.55), Vector2(1.0, 1.0)]
	for i: int in range(segs + 1):
		var k: float = float(i) / float(segs)
		var d: Vector3 = flat.rotated(Vector3.UP, lerpf(-half, half, k) * sweep)
		var lead: float = lerpf(0.3, 1.0, k)
		for b: Vector2 in bands:
			verts.append(d * radius * b.x + Vector3(0.0, 1.05, 0.0))
			cols.append(Color(lead * b.y, lead * b.y, lead * b.y, 1.0))
	var idx: PackedInt32Array = PackedInt32Array()
	for q: int in range(segs):
		for band: int in range(2):
			var a0: int = q * 3 + band
			var a1: int = a0 + 3
			idx.append_array([a0, a0 + 1, a1, a0 + 1, a1 + 1, a1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Added on top of the floor (so it glows and never darkens it); the vertex colours fade it out
	# toward the inside and the trailing end.
	var c: Color = color.lerp(Color.WHITE, 0.4)
	fx._ring_mat = Art.alpha_mat(Color(c.r, c.g, c.b, 0.85), true)
	fx._ring_mat.vertex_color_use_as_albedo = true
	fx._ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fx._ring = Art.part(fx, mesh, fx._ring_mat, Vector3.ZERO)
	fx._ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx._ring_r = -1.0
	fx._spin = 2.2 * sweep


func _process(delta: float) -> void:
	_t += delta
	for i: int in range(_parts.size()):
		var mi: MeshInstance3D = _parts[i]
		if not mi.visible:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			mi.visible = false
			continue
		_vel[i].y -= _grav * delta
		mi.position += _vel[i] * delta
		if mi.position.y < 0.05 - position.y:
			mi.position.y = 0.05 - position.y
			_vel[i] = Vector3(_vel[i].x * 0.4, absf(_vel[i].y) * 0.3, _vel[i].z * 0.4)
		var k: float = _life[i] / _max_life[i]
		mi.scale = Vector3.ONE * clampf(k * 1.5, 0.0, 1.0)
	var f: float = clampf(_t / _ttl, 0.0, 1.0)
	if _ring != null:
		var rf: float = clampf((_t - _delay) / maxf(_ttl - _delay, 0.001), 0.0, 1.0)
		_ring.visible = _t >= _delay
		_ring.rotation.y += _spin * delta
		if _ring_r > 0.0:
			var s: float = lerpf(0.2, _ring_r, 1.0 - pow(1.0 - rf, 3.0))
			_ring.scale = Vector3(s, 1.0 if _ring.mesh is TorusMesh else s, s)
		_ring_mat.albedo_color.a = (1.0 - rf) * 0.85
	if _label != null:
		_label.position.y = f * 0.9
		_label.modulate.a = 1.0 - maxf(f - 0.5, 0.0) * 2.0
	if _light != null:
		_light.light_energy = 3.0 * (1.0 - f)
	if _t >= _ttl:
		queue_free()
