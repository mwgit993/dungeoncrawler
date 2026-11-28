class_name Rig
extends Node3D

## Base for the character models (GorillaRig, EnemyRig). A rig is a tree of joints (plain Node3Ds)
## holding sculpted parts (Sculpt meshes) that the subclass animates in code every frame. It owns
## the effects every character shares:
##   - hit flash: the per-character material's `flash` uniform
##   - squash and stretch: a spring on the `root` joint's scale (impact() kicks it)
##   - recoil: a spring that tilts the root away from a hit
##   - blinking eyes: blink() returns the eye's Y scale for this frame
## The rig's +Z is forward and y = 0 is the floor. The owner turns the rig (or itself) to face.

var root: Node3D            # everything hangs off this; squash and recoil apply here
var material: ShaderMaterial
var t: float = 0.0          # seconds alive, drives idle motion

var _flash_t: float = 0.0
var _flash_len: float = 0.1
var _squash: float = 0.0    # > 0 squashed flat, < 0 stretched tall
var _squash_v: float = 0.0
var _tilt: Vector2 = Vector2.ZERO   # recoil lean (x = pitch, y = roll)
var _tilt_v: Vector2 = Vector2.ZERO
var _blink_at: float = 2.0
var _seed: float = 0.0


func _init() -> void:
	material = Art.char_material()
	root = Node3D.new()
	root.name = "Root"
	add_child(root)
	_seed = randf() * 10.0
	_blink_at = 1.0 + randf() * 3.0


## A joint under parent at pos.
func joint(parent: Node3D, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> Node3D:
	var n: Node3D = Node3D.new()
	n.position = pos
	n.rotation_degrees = rot_deg
	parent.add_child(n)
	return n


## A sculpted part on a joint. Pass a cache key to share the mesh between every rig of a kind.
func shape(parent: Node3D, key: String, build: Callable) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = Sculpt.cached(key, build)
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## A glowing part (eye, mouth, core) with no outline.
func glow(parent: Node3D, key: String, build: Callable, mat: Material) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = Sculpt.cached(key, build)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func flash(c: Color, time: float = 0.1) -> void:
	_flash_t = time
	_flash_len = time
	material.set_shader_parameter("flash_color", c)
	material.set_shader_parameter("flash", 1.0)


func flashing() -> bool:
	return _flash_t > 0.0


## Kicks the squash spring: positive squashes flat (landing, slamming), negative stretches.
func impact(amount: float) -> void:
	_squash_v += amount * 14.0


## Tilts the body away from a hit coming from world direction dir.
func recoil(dir: Vector3, amount: float = 1.0) -> void:
	var local: Vector3 = global_transform.basis.inverse() * dir
	local.y = 0.0
	if local.length() < 0.001:
		return
	local = local.normalized()
	_tilt_v += Vector2(local.z, -local.x) * 6.0 * amount


## Advances the shared springs and flash. Subclasses call this first in their animate().
func tick(dt: float) -> void:
	t += dt
	if _flash_t > 0.0:
		_flash_t -= dt
		material.set_shader_parameter("flash", clampf(_flash_t / _flash_len, 0.0, 1.0) if _flash_t > 0.0 else 0.0)
	# Semi-implicit springs, stable for any frame step the game uses (<= 0.05 s).
	_squash_v += (-260.0 * _squash - 16.0 * _squash_v) * dt
	_squash += _squash_v * dt
	_squash = clampf(_squash, -0.35, 0.35)
	_tilt_v += (-220.0 * _tilt - 15.0 * _tilt_v) * dt
	_tilt += _tilt_v * dt
	root.scale = Vector3(1.0 + _squash * 0.6, 1.0 - _squash, 1.0 + _squash * 0.6)
	root.rotation = Vector3(_tilt.x * 0.35, 0.0, _tilt.y * 0.35)


## The Y scale for eyes this frame: 1 when open, a sliver during a blink every few seconds.
func blink() -> float:
	if t >= _blink_at:
		if t < _blink_at + 0.11:
			return 0.15
		_blink_at = t + 2.2 + fmod(_seed * 7.3 + t * 1.7, 3.0)
	return 1.0


## Smoke test helpers: how many sculpted parts use this rig's material (with the outline pass),
## and the height of the top of the model above the rig's origin.
func sculpted_parts() -> int:
	var n: int = 0
	for mi: MeshInstance3D in _mesh_instances(self):
		if mi.material_override == material and material.next_pass != null and mi.mesh.get_surface_count() > 0:
			n += 1
	return n


func visual_height() -> float:
	var top: float = 0.0
	var inv: Transform3D = global_transform.affine_inverse()
	for mi: MeshInstance3D in _mesh_instances(self):
		var box: AABB = (inv * mi.global_transform) * mi.mesh.get_aabb()
		top = maxf(top, box.end.y)
	return top


func _mesh_instances(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c: Node in n.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		out.append_array(_mesh_instances(c))
	return out


## A smooth 0 -> 1 -> 0 envelope over k in [0, 1] that peaks at `peak`.
static func envelope(k: float, peak: float) -> float:
	if k <= 0.0 or k >= 1.0:
		return 0.0
	if k < peak:
		return sin(k / peak * PI * 0.5)
	return cos((k - peak) / (1.0 - peak) * PI * 0.5)
