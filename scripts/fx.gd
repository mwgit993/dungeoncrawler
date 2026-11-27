class_name Fx
extends Node3D

## Short-lived effects: sparks, debris, explosions, shockwave rings, floating damage numbers.
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
var _label: Label3D = null
var _light: OmniLight3D = null
var _t: float = 0.0
var _ttl: float = 0.5


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
	var fx: Fx = _make(parent, pos, 0.35)
	fx._grav = 9.0
	var m: StandardMaterial3D = Art.mat(color, 2.5)
	for i: int in range(count):
		var v: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(0.2, 1.2), randf_range(-1.0, 1.0)).normalized() * speed * randf_range(0.5, 1.0)
		fx._add(Art.box(Vector3(0.08, 0.08, 0.08)), m, v, randf_range(0.15, 0.32))


static func debris(parent: Node3D, pos: Vector3, color: Color, count: int) -> void:
	var fx: Fx = _make(parent, pos, 0.9)
	fx._grav = 16.0
	var m: StandardMaterial3D = Art.mat(color)
	var m2: StandardMaterial3D = Art.mat(color.darkened(0.4))
	for i: int in range(count):
		var v: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(0.8, 1.6), randf_range(-1.0, 1.0)) * randf_range(2.5, 5.5)
		var s: float = randf_range(0.1, 0.24)
		fx._add(Art.box(Vector3(s, s, s)), m if i % 2 == 0 else m2, v, randf_range(0.5, 0.85))


static func explosion(parent: Node3D, pos: Vector3, color: Color, size: float) -> void:
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
	var fx: Fx = _make(parent, pos, 0.25)
	fx._ring_mat = Art.alpha_mat(Color(color.r, color.g, color.b, 0.5), true)
	fx._ring = Art.part(fx, Art.cylinder(0.6, 0.6, 1.8, 8), fx._ring_mat, Vector3(0.0, 0.9, 0.0))
	fx._ring_r = -1.0


static func zap(parent: Node3D, a: Vector3, b: Vector3) -> void:
	var fx: Fx = _make(parent, a, 0.18)
	var m: StandardMaterial3D = Art.mat(Color(0.5, 0.9, 1.0), 3.0)
	var steps: int = maxi(int(a.distance_to(b) / 0.4), 2)
	for i: int in range(steps + 1):
		var p: Vector3 = (b - a) * (float(i) / float(steps))
		if i > 0 and i < steps:
			p += Vector3(randf_range(-0.2, 0.2), randf_range(-0.2, 0.2), randf_range(-0.2, 0.2))
		fx._add(Art.box(Vector3(0.1, 0.1, 0.1)), m, Vector3.ZERO, 0.18, p)


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
		if _ring_r > 0.0:
			var s: float = lerpf(0.2, _ring_r, 1.0 - pow(1.0 - f, 3.0))
			_ring.scale = Vector3(s, 1.0 if _ring.mesh is TorusMesh else s, s)
		_ring_mat.albedo_color.a = (1.0 - f) * 0.85
	if _label != null:
		_label.position.y = f * 0.9
		_label.modulate.a = 1.0 - maxf(f - 0.5, 0.0) * 2.0
	if _light != null:
		_light.light_energy = 3.0 * (1.0 - f)
	if _t >= _ttl:
		queue_free()
