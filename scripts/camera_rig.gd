class_name CameraRig
extends Camera3D

## Fixed-angle isometric camera (orthographic). Follows the middle of the group, zooms out to
## keep every co-op player on screen, and snaps to whole screen pixels so the low-res picture
## doesn't shimmer while it scrolls. Shake is added in whole pixels too.

const VIEW_H: float = 360.0
const VIEW_W: float = 640.0
const DISTANCE: float = 60.0

var targets: Array[GorillaBot] = []
var _focus: Vector3 = Vector3.ZERO
var _size: float = Balance.CAMERA_SIZE
var _shake: float = 0.0
var _basis: Basis


func _ready() -> void:
	projection = Camera3D.PROJECTION_ORTHOGONAL
	keep_aspect = Camera3D.KEEP_HEIGHT
	size = Balance.CAMERA_SIZE
	near = 1.0
	far = 160.0
	_basis = Basis.from_euler(Vector3(deg_to_rad(-Balance.CAMERA_PITCH), deg_to_rad(Balance.CAMERA_YAW), 0.0))


func add_shake(amount: float) -> void:
	_shake = minf(_shake + amount, 1.2)


func snap_to(pos: Vector3) -> void:
	_focus = pos
	_size = Balance.CAMERA_SIZE
	_apply(0.0)


func _process(delta: float) -> void:
	var pts: Array[Vector3] = []
	for p: GorillaBot in targets:
		if is_instance_valid(p) and (p.alive or targets.size() == 1):
			pts.append(p.global_position)
	if pts.is_empty():
		for p2: GorillaBot in targets:
			if is_instance_valid(p2):
				pts.append(p2.global_position)
	if not pts.is_empty():
		var center: Vector3 = Vector3.ZERO
		for v: Vector3 in pts:
			center += v
		center /= float(pts.size())
		# Size needed to fit everyone, measured in camera space.
		var half_w: float = 0.0
		var half_h: float = 0.0
		var right: Vector3 = _basis.x
		var up: Vector3 = _basis.y
		for v2: Vector3 in pts:
			var d: Vector3 = v2 - center
			half_w = maxf(half_w, absf(d.dot(right)))
			half_h = maxf(half_h, absf(d.dot(up)))
		var need: float = maxf((half_h + 3.5) * 2.0, (half_w + 4.0) * 2.0 * VIEW_H / VIEW_W)
		var target_size: float = clampf(need, Balance.CAMERA_SIZE, Balance.CAMERA_MAX_SIZE)
		var k: float = 1.0 - exp(-Balance.CAMERA_FOLLOW * delta)
		_focus = _focus.lerp(center, k)
		_size = lerpf(_size, target_size, 1.0 - exp(-3.0 * delta))
	_shake = maxf(_shake - delta * 2.5, 0.0)
	_apply(_shake)


func _apply(shake_amt: float) -> void:
	size = _size
	var px: float = _size / VIEW_H
	var local: Vector3 = _basis.inverse() * _focus
	local.x = round(local.x / px) * px
	local.y = round(local.y / px) * px
	var snapped: Vector3 = _basis * local
	var off: Vector3 = Vector3.ZERO
	if shake_amt > 0.01:
		var mag: float = ceil(shake_amt * 4.0)
		off = _basis.x * float(randi_range(-int(mag), int(mag))) * px + _basis.y * float(randi_range(-int(mag), int(mag))) * px
	global_transform = Transform3D(_basis, snapped + _basis.z * DISTANCE + off)
