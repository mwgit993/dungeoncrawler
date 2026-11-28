class_name EnemyRig
extends Rig

## The robot enemies' models and animation, one rig per kind (stats live in Balance.ENEMIES):
##   scuttler  spider-crab drone: domed shell, six jointed legs, snapping mandibles, antenna
##   gunner    chicken-walker: backward-knee legs, scanning visor head, arm cannon that kicks
##   bruiser   hulk: huge shoulders and hammer fists, tiny head, exhaust stacks; stomps
##   foreman   Foundry boss: tracked loader with a cab, smokestack and two pincer arms
##   warden    Ashfall boss: lumpy magma golem with a glowing core and orbiting rock shards
## RobotEnemy drives it: animate() every step with its state, plus hurt(), shot() and woke().
## A strike (slam, bite, nova) is played when the state leaves WINDUP.

const DARK: Color = Color(0.2, 0.19, 0.21)
const SILVER: Color = Color(0.74, 0.76, 0.8)

var kind: String = "scuttler"
var glow_mat: StandardMaterial3D
var glow_color: Color = Color(1.0, 0.25, 0.15)
var glow_base: float = 2.4

var _body: Node3D
var _head: Node3D
var _legs: Array[Node3D] = []
var _arms: Array[Node3D] = []
var _elbows: Array[Node3D] = []
var _bits: Array[Node3D] = []   # per kind: mandibles, pincers, wheels, orbiting shards, antenna
var _eyes: Array[MeshInstance3D] = []
var _leg_yaw: Array[float] = []
var _gait: float = 0.0
var _prev_state: int = 0
var _prev_action: String = ""
var _strike_t: float = 0.0
var _strike: String = ""
var _kick: float = 0.0          # gunner recoil
var _wake_t: float = 0.0
var _step_sign: float = 1.0
var _sleep_k: float = 1.0       # 1 = powered down pose


func setup(k: String) -> void:
	kind = k
	match kind:
		"gunner":
			_build_gunner()
		"bruiser":
			_build_bruiser()
		"foreman":
			_build_foreman()
		"warden":
			_build_warden()
		_:
			_build_scuttler()


func _glow_setup(c: Color, energy: float) -> void:
	glow_color = c
	glow_base = energy
	glow_mat = Art.glow_mat(c, energy)


func _eye(parent: Node3D, key: String, build: Callable, pos: Vector3) -> MeshInstance3D:
	var e: MeshInstance3D = glow(parent, key, build, glow_mat)
	e.position = pos
	_eyes.append(e)
	return e


# --- Scuttler ------------------------------------------------------------------------------

const SCUT_SHELL: Color = Color(0.66, 0.38, 0.2)
const SCUT_RIDGE: Color = Color(0.48, 0.26, 0.15)


func _build_scuttler() -> void:
	_glow_setup(Color(1.0, 0.22, 0.15), 2.6)
	_body = joint(root, Vector3(0.0, 0.42, 0.0))
	shape(_body, "scut_body", _m_scut_body)
	_eye(_body, "scut_eye", _m_ball.bind(Vector3(0.075, 0.065, 0.04)), Vector3(0.0, 0.05, 0.45))
	for s: float in [-1.0, 1.0]:
		_eye(_body, "scut_eye2", _m_ball.bind(Vector3(0.035, 0.035, 0.03)), Vector3(0.13 * s, 0.07, 0.41))
		var mand: Node3D = joint(_body, Vector3(0.09 * s, -0.05, 0.42))
		shape(mand, "scut_mand_%d" % int(s), _m_scut_mandible.bind(s))
		_bits.append(mand)
	var ant: Node3D = joint(_body, Vector3(0.0, 0.18, -0.24))
	shape(ant, "scut_antenna", _m_antenna.bind(0.22))
	glow(ant, "scut_tip", _m_ball.bind(Vector3(0.04, 0.04, 0.04)), glow_mat).position = Vector3(0.0, 0.24, -0.06)
	_bits.append(ant)
	for i: int in range(6):
		var side: float = -1.0 if i < 3 else 1.0
		var row: float = float(i % 3) - 1.0
		var leg: Node3D = joint(_body, Vector3(0.24 * side, -0.02, row * 0.22))
		shape(leg, "scut_leg", _m_scut_leg)
		var yaw0: float = (0.0 if side > 0.0 else PI) - row * 0.55 * side
		leg.rotation.y = yaw0
		_leg_yaw.append(yaw0)
		_legs.append(leg)


func _m_scut_body() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.04, -0.03), Vector3(0.34, 0.19, 0.4), SCUT_SHELL, 0.75)
	sc.blob(Vector3(0.0, 0.16, -0.05), Vector3(0.12, 0.08, 0.34), SCUT_RIDGE, 0.7)
	for s: float in [-1.0, 1.0]:
		sc.blob(Vector3(0.2 * s, 0.11, -0.12), Vector3(0.09, 0.06, 0.2), SCUT_RIDGE, 0.7)
	sc.blob(Vector3(0.0, -0.06, 0.0), Vector3(0.28, 0.1, 0.32), DARK, 0.7)
	sc.blob(Vector3(0.0, 0.0, 0.33), Vector3(0.21, 0.13, 0.13), DARK, 0.7)
	return sc


func _m_scut_mandible(s: float) -> Sculpt:
	return Sculpt.new().tube([Vector3.ZERO, Vector3(0.04 * s, -0.04, 0.12), Vector3(-0.03 * s, -0.06, 0.19)],
		[0.035, 0.03, 0.015], SILVER, 6)


func _m_scut_leg() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.24, 0.17, 0.0), Vector3(0.46, -0.4, 0.0)], [0.055, 0.045, 0.02], DARK, 6, 2)
	sc.blob(Vector3(0.24, 0.17, 0.0), Vector3(0.06, 0.06, 0.06), SCUT_RIDGE, 0.8)
	return sc


func _m_antenna(h: float) -> Sculpt:
	return Sculpt.new().tube([Vector3.ZERO, Vector3(0.0, h * 0.6, -0.02), Vector3(0.0, h, -0.06)], [0.025, 0.02, 0.015], DARK, 5, 2)


func _m_ball(r: Vector3) -> Sculpt:
	return Sculpt.new().blob(Vector3.ZERO, r, Color.WHITE, 0.8, Vector3.ZERO, 0.0, 6, 10)


# --- Gunner --------------------------------------------------------------------------------

const GUN_BODY: Color = Color(0.52, 0.6, 0.42)
const GUN_DARK: Color = Color(0.3, 0.34, 0.27)
const GUN_STRIPE: Color = Color(0.92, 0.74, 0.2)


func _build_gunner() -> void:
	_glow_setup(Color(1.0, 0.85, 0.22), 2.4)
	for s: float in [-1.0, 1.0]:
		var leg: Node3D = joint(root, Vector3(0.2 * s, 0.95, 0.0))
		shape(leg, "gun_leg", _m_gun_leg)
		_legs.append(leg)
	_body = joint(root, Vector3(0.0, 1.05, 0.0))
	shape(_body, "gun_body", _m_gun_body)
	_head = joint(_body, Vector3(0.0, 0.34, 0.06))
	shape(_head, "gun_head", _m_gun_head)
	_eye(_head, "gun_visor", _m_ball.bind(Vector3(0.13, 0.03, 0.02)), Vector3(0.0, 0.02, 0.215))
	var ant: Node3D = joint(_head, Vector3(-0.12, 0.12, -0.06))
	shape(ant, "gun_antenna", _m_antenna.bind(0.26))
	glow(ant, "gun_tip", _m_ball.bind(Vector3(0.035, 0.035, 0.035)), glow_mat).position = Vector3(0.0, 0.28, -0.06)
	_bits.append(ant)
	var gun: Node3D = joint(_body, Vector3(0.38, 0.04, 0.02))
	shape(gun, "gun_cannon", _m_gun_cannon)
	glow(gun, "gun_muzzle", _m_ball.bind(Vector3(0.06, 0.06, 0.03)), glow_mat).position = Vector3(0.0, 0.0, 0.69)
	_arms.append(gun)
	var off: Node3D = joint(_body, Vector3(-0.36, 0.02, 0.0))
	shape(off, "gun_offarm", _m_gun_offarm)
	_arms.append(off)


func _m_gun_leg() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.34, 0.17), Vector3(0.0, -0.66, -0.08), Vector3(0.0, -0.88, 0.03)],
		[0.09, 0.07, 0.055, 0.05], DARK, 7, 2)
	sc.blob(Vector3(0.0, -0.34, 0.17), Vector3(0.095, 0.095, 0.095), GUN_BODY, 0.8)
	sc.blob(Vector3(0.0, -0.91, 0.09), Vector3(0.1, 0.045, 0.17), DARK, 0.5)
	return sc


func _m_gun_body() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.05, 0.0), Vector3(0.34, 0.3, 0.32), GUN_BODY, 0.65)
	sc.blob(Vector3(0.0, -0.18, 0.04), Vector3(0.26, 0.12, 0.25), GUN_DARK, 0.7)
	sc.blob(Vector3(0.0, 0.12, 0.27), Vector3(0.24, 0.05, 0.08), GUN_STRIPE, 0.6)
	sc.blob(Vector3(0.0, 0.08, -0.3), Vector3(0.24, 0.22, 0.14), DARK, 0.55)
	for s: float in [-1.0, 1.0]:
		sc.blob(Vector3(0.1 * s, 0.14, -0.43), Vector3(0.05, 0.08, 0.03), GUN_DARK, 0.6)
	return sc


func _m_gun_head() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.02, 0.0), Vector3(0.22, 0.14, 0.2), GUN_DARK, 0.55)
	sc.blob(Vector3(0.0, 0.02, 0.15), Vector3(0.17, 0.075, 0.07), DARK, 0.55)
	sc.blob(Vector3(0.0, 0.14, -0.02), Vector3(0.14, 0.04, 0.15), GUN_BODY, 0.6)
	return sc


func _m_gun_cannon() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.15, 0.15, 0.15), GUN_BODY, 0.75)
	sc.tube([Vector3(0.0, 0.0, 0.05), Vector3(0.0, 0.0, 0.62)], [0.1, 0.085], DARK, 8)
	sc.blob(Vector3(0.0, 0.0, 0.62), Vector3(0.11, 0.11, 0.06), SILVER, 0.6)
	sc.blob(Vector3(0.0, 0.1, 0.26), Vector3(0.06, 0.05, 0.14), GUN_STRIPE, 0.6)
	return sc


func _m_gun_offarm() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.28, 0.06), Vector3(0.0, -0.42, 0.18)], [0.065, 0.055, 0.05], DARK, 6, 2)
	sc.blob(Vector3(0.0, -0.45, 0.22), Vector3(0.07, 0.07, 0.08), GUN_BODY, 0.7)
	return sc


# --- Bruiser -------------------------------------------------------------------------------

const BRU_BODY: Color = Color(0.58, 0.28, 0.22)
const BRU_PLATE: Color = Color(0.44, 0.2, 0.17)
const BRU_STRIPE: Color = Color(0.94, 0.74, 0.16)


func _build_bruiser() -> void:
	_glow_setup(Color(1.0, 0.27, 0.15), 2.4)
	for s: float in [-1.0, 1.0]:
		var leg: Node3D = joint(root, Vector3(0.38 * s, 0.72, -0.02))
		shape(leg, "bru_leg", _m_bru_leg)
		_legs.append(leg)
	_body = joint(root, Vector3(0.0, 1.22, 0.0))
	shape(_body, "bru_body", _m_bru_body)
	for s2: float in [-1.0, 1.0]:
		glow(_body, "bru_exhaust", _m_ball.bind(Vector3(0.07, 0.04, 0.07)), glow_mat).position = Vector3(0.28 * s2, 0.64, -0.5)
	_head = joint(_body, Vector3(0.0, 0.56, 0.36))
	shape(_head, "bru_head", _m_bru_head)
	for s4: float in [-1.0, 1.0]:
		_eye(_head, "bru_eye", _m_ball.bind(Vector3(0.06, 0.045, 0.03)), Vector3(0.1 * s4, 0.03, 0.25))
	for s3: float in [-1.0, 1.0]:
		var arm: Node3D = joint(_body, Vector3(0.8 * s3, 0.25, 0.0))
		shape(arm, "bru_upper", _m_bru_upper)
		var elbow: Node3D = joint(arm, Vector3(0.0, -0.48, 0.05))
		shape(elbow, "bru_fist", _m_bru_fist)
		_arms.append(arm)
		_elbows.append(elbow)


func _m_bru_leg() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.36, 0.07), Vector3(0.0, -0.6, 0.0)], [0.2, 0.18, 0.17], DARK, 9)
	sc.blob(Vector3(0.0, -0.66, 0.09), Vector3(0.24, 0.09, 0.3), BRU_PLATE, 0.5)
	return sc


func _m_bru_body() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.05, 0.0), Vector3(0.7, 0.52, 0.5), BRU_BODY, 0.6, Vector3.ZERO, 0.3)
	sc.blob(Vector3(0.0, -0.42, 0.0), Vector3(0.5, 0.18, 0.38), DARK, 0.7)
	sc.blob(Vector3(0.0, -0.32, 0.04), Vector3(0.58, 0.09, 0.44), BRU_STRIPE, 0.6)
	sc.blob(Vector3(0.0, 0.1, 0.4), Vector3(0.42, 0.28, 0.12), BRU_PLATE, 0.5)
	for s: float in [-1.0, 1.0]:
		sc.blob(Vector3(0.72 * s, 0.32, 0.0), Vector3(0.36, 0.33, 0.38), BRU_BODY, 0.6)
		sc.blob(Vector3(0.74 * s, 0.52, 0.0), Vector3(0.3, 0.08, 0.3), BRU_STRIPE, 0.55, Vector3(0.0, 0.0, -12.0 * s))
		sc.tube([Vector3(0.28 * s, 0.3, -0.42), Vector3(0.28 * s, 0.62, -0.5)], [0.08, 0.075], DARK, 7)
	return sc


func _m_bru_head() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.27, 0.21, 0.25), BRU_PLATE, 0.6)
	sc.blob(Vector3(0.0, 0.02, 0.16), Vector3(0.21, 0.1, 0.1), DARK, 0.55)
	sc.blob(Vector3(0.0, 0.13, 0.12), Vector3(0.29, 0.06, 0.15), BRU_BODY, 0.5)
	sc.blob(Vector3(0.0, -0.13, 0.15), Vector3(0.18, 0.06, 0.1), SILVER, 0.5)
	return sc


func _m_bru_upper() -> Sculpt:
	return Sculpt.new().tube([Vector3.ZERO, Vector3(0.0, -0.48, 0.05)], [0.18, 0.16], DARK, 9)


func _m_bru_fist() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.32, 0.05)], [0.2, 0.27], BRU_BODY, 9)
	sc.blob(Vector3(0.0, -0.6, 0.08), Vector3(0.36, 0.32, 0.38), BRU_PLATE, 0.4)
	sc.blob(Vector3(0.0, -0.66, 0.36), Vector3(0.3, 0.09, 0.08), BRU_STRIPE, 0.5)
	return sc


# --- Foreman (Foundry boss) -------------------------------------------------------------------

const FORE_BODY: Color = Color(0.88, 0.66, 0.2)
const FORE_METAL: Color = Color(0.5, 0.51, 0.56)


func _build_foreman() -> void:
	_glow_setup(Color(1.0, 0.32, 0.15), 2.6)
	for s: float in [-1.0, 1.0]:
		var tread: Node3D = joint(root, Vector3(0.95 * s, 0.38, 0.0))
		shape(tread, "fore_tread", _m_fore_tread)
		_legs.append(tread)
		for z: float in [-0.72, 0.0, 0.72]:
			var wheel: Node3D = joint(tread, Vector3(0.3 * s, 0.0, z))
			shape(wheel, "fore_wheel", _m_fore_wheel)
			_bits.append(wheel)
	_body = joint(root, Vector3(0.0, 1.05, -0.1))
	shape(_body, "fore_body", _m_fore_body)
	_eye(_body, "fore_window", _m_ball.bind(Vector3(0.46, 0.14, 0.04)), Vector3(0.0, 0.8, 0.24))
	for s2: float in [-1.0, 1.0]:
		_eye(_body, "fore_lamp", _m_ball.bind(Vector3(0.11, 0.07, 0.04)), Vector3(0.42 * s2, 0.05, 0.94))
	glow(_body, "fore_stack", _m_ball.bind(Vector3(0.13, 0.05, 0.13)), glow_mat).position = Vector3(0.45, 1.78, -0.66)
	for s3: float in [-1.0, 1.0]:
		var arm: Node3D = joint(_body, Vector3(1.05 * s3, 0.45, 0.4))
		shape(arm, "fore_boom", _m_fore_boom)
		var claw: Node3D = joint(arm, Vector3(0.0, -0.2, 1.2))
		shape(claw, "fore_palm", _m_fore_palm)
		for up: float in [1.0, -1.0]:
			var pincer: Node3D = joint(claw, Vector3(0.0, 0.12 * up, 0.18))
			shape(pincer, "fore_pincer_%d" % int(up), _m_fore_pincer.bind(up))
			_bits.append(pincer)
		_arms.append(arm)
		_elbows.append(claw)


func _m_fore_tread() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.3, 0.36, 1.15), DARK, 0.35)
	sc.blob(Vector3(0.0, 0.32, 0.0), Vector3(0.31, 0.06, 1.0), FORE_METAL, 0.4)
	return sc


func _m_fore_wheel() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.05, 0.22, 0.22), SILVER, 0.8)
	sc.blob(Vector3(0.03, 0.11, 0.0), Vector3(0.04, 0.08, 0.05), DARK, 0.6)
	return sc


func _m_fore_body() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.95, 0.42, 0.95), FORE_BODY, 0.4)
	sc.blob(Vector3(0.0, -0.32, 0.0), Vector3(0.98, 0.12, 0.98), DARK, 0.4)
	sc.blob(Vector3(0.0, -0.12, 0.92), Vector3(0.82, 0.16, 0.14), DARK, 0.45)
	for i: int in range(4):
		sc.blob(Vector3(-0.54 + 0.36 * float(i), -0.12, 1.02), Vector3(0.09, 0.12, 0.05), FORE_BODY, 0.5, Vector3(0.0, 0.0, 30.0))
	sc.blob(Vector3(0.0, 0.72, -0.25), Vector3(0.6, 0.4, 0.5), FORE_BODY, 0.45)
	sc.blob(Vector3(0.0, 1.1, -0.25), Vector3(0.62, 0.06, 0.52), DARK, 0.4)
	sc.tube([Vector3(0.45, 0.9, -0.62), Vector3(0.45, 1.75, -0.66)], [0.11, 0.1], DARK, 8)
	return sc


func _m_fore_boom() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.26, 0.26, 0.26), FORE_METAL, 0.7)
	sc.tube([Vector3.ZERO, Vector3(0.0, 0.05, 0.62), Vector3(0.0, -0.18, 1.12)], [0.2, 0.18, 0.17], FORE_METAL, 9)
	sc.tube([Vector3(0.0, -0.2, 0.1), Vector3(0.0, -0.25, 0.75)], [0.06, 0.05], SILVER, 6)
	return sc


func _m_fore_palm() -> Sculpt:
	return Sculpt.new().blob(Vector3(0.0, 0.0, 0.06), Vector3(0.3, 0.27, 0.22), DARK, 0.5)


func _m_fore_pincer(up: float) -> Sculpt:
	return Sculpt.new().tube([Vector3.ZERO, Vector3(0.0, 0.13 * up, 0.28), Vector3(0.0, 0.01 * up, 0.5)],
		[0.08, 0.065, 0.035], FORE_BODY, 7)


# --- Warden (Ashfall boss) ---------------------------------------------------------------------

const ROCK: Color = Color(0.38, 0.28, 0.25)
const ROCK_LIGHT: Color = Color(0.56, 0.42, 0.35)


func _build_warden() -> void:
	_glow_setup(Color(1.0, 0.46, 0.1), 2.8)
	for s: float in [-1.0, 1.0]:
		var leg: Node3D = joint(root, Vector3(0.6 * s, 1.0, 0.0))
		shape(leg, "war_leg", _m_war_leg)
		glow(leg, "war_crack", _m_ball.bind(Vector3(0.05, 0.12, 0.03)), glow_mat).position = Vector3(0.0, -0.5, 0.33)
		_legs.append(leg)
	_body = joint(root, Vector3(0.0, 1.75, 0.0))
	shape(_body, "war_body", _m_war_body)
	_eye(_body, "war_core", _m_ball.bind(Vector3(0.3, 0.3, 0.2)), Vector3(0.0, 0.0, 0.52))
	for c: Vector3 in [Vector3(0.42, -0.3, 0.5), Vector3(-0.5, 0.2, 0.46), Vector3(0.55, 0.35, 0.36),
			Vector3(-0.3, -0.35, 0.52), Vector3(0.7, -0.05, 0.3), Vector3(-0.72, -0.1, 0.28)]:
		glow(_body, "war_crack2", _m_ball.bind(Vector3(0.035, 0.16, 0.03)), glow_mat).position = c
	_head = joint(_body, Vector3(0.0, 0.82, 0.15))
	shape(_head, "war_head", _m_war_head)
	_eye(_head, "war_eyes", _m_ball.bind(Vector3(0.24, 0.045, 0.03)), Vector3(0.0, 0.02, 0.34))
	for s2: float in [-1.0, 1.0]:
		var arm: Node3D = joint(_body, Vector3(1.0 * s2, 0.4, 0.0))
		shape(arm, "war_upper", _m_war_upper)
		var elbow: Node3D = joint(arm, Vector3(0.0, -0.6, 0.05))
		shape(elbow, "war_fist", _m_war_fist)
		glow(elbow, "war_crack3", _m_ball.bind(Vector3(0.14, 0.04, 0.03)), glow_mat).position = Vector3(0.0, -0.55, 0.6)
		_arms.append(arm)
		_elbows.append(elbow)
	for i: int in range(3):
		var orb: Node3D = joint(root, Vector3(0.0, 1.9, 0.0))
		orb.rotation.y = TAU * float(i) / 3.0
		shape(orb, "war_shard", _m_war_shard)
		_bits.append(orb)


func _m_war_leg() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.5, 0.07), Vector3(0.0, -0.86, 0.0)], [0.32, 0.29, 0.27], ROCK, 9)
	sc.blob(Vector3(0.0, -0.9, 0.1), Vector3(0.38, 0.14, 0.46), ROCK_LIGHT, 0.6)
	return sc


func _m_war_body() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.85, 0.66, 0.6), ROCK, 0.95, Vector3.ZERO, 0.15, 10, 16)
	sc.blob(Vector3(0.48, 0.4, -0.3), Vector3(0.36, 0.32, 0.34), ROCK, 0.9, Vector3(10.0, 20.0, 0.0))
	sc.blob(Vector3(-0.52, 0.3, -0.26), Vector3(0.38, 0.34, 0.34), ROCK, 0.9, Vector3(-8.0, 0.0, 15.0))
	sc.blob(Vector3(0.1, 0.5, -0.4), Vector3(0.4, 0.26, 0.3), ROCK_LIGHT, 0.85)
	for s: float in [-1.0, 1.0]:
		sc.blob(Vector3(0.38 * s, 0.24, 0.42), Vector3(0.3, 0.26, 0.15), ROCK_LIGHT, 0.6, Vector3(-15.0, 25.0 * s, 0.0))
	sc.blob(Vector3(0.0, -0.5, 0.2), Vector3(0.55, 0.22, 0.4), ROCK_LIGHT, 0.7)
	return sc


func _m_war_head() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.4, 0.3, 0.36), ROCK_LIGHT, 0.75)
	sc.blob(Vector3(0.0, 0.14, 0.24), Vector3(0.38, 0.08, 0.14), ROCK, 0.6)
	for s: float in [-1.0, 1.0]:
		sc.tube([Vector3(0.28 * s, 0.14, -0.02), Vector3(0.46 * s, 0.38, -0.06), Vector3(0.5 * s, 0.58, -0.18)],
			[0.09, 0.06, 0.025], ROCK, 7, 2)
	return sc


func _m_war_upper() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.08, 0.0), Vector3(0.46, 0.42, 0.46), ROCK_LIGHT, 0.85)
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.6, 0.05)], [0.28, 0.25], ROCK, 9)
	return sc


func _m_war_fist() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.3, 0.06)], [0.26, 0.32], ROCK, 9)
	sc.blob(Vector3(0.0, -0.6, 0.12), Vector3(0.48, 0.45, 0.5), ROCK, 0.75)
	sc.blob(Vector3(0.18, -0.4, 0.28), Vector3(0.22, 0.2, 0.2), ROCK_LIGHT, 0.8)
	return sc


func _m_war_shard() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.0, 1.38), Vector3(0.24, 0.2, 0.14), ROCK_LIGHT, 0.5, Vector3(15.0, 0.0, 30.0))
	sc.blob(Vector3(0.0, -0.08, 1.4), Vector3(0.14, 0.1, 0.1), ROCK, 0.6, Vector3(0.0, 0.0, -20.0))
	return sc


# --- Events --------------------------------------------------------------------------------

func hurt(push_dir: Vector3, heavy: bool) -> void:
	flash(Color(1.0, 1.0, 1.0), 0.08)
	recoil(push_dir, 0.35 if heavy else 1.0)
	impact(0.05 if heavy else 0.14)


## A shot left the gun (gunner bursts).
func shot() -> void:
	_kick = 1.0


## The strike being played (slam, bite, nova...), or "" when none is.
func striking() -> String:
	return _strike if _strike_t > 0.0 else ""


func woke() -> void:
	_wake_t = 0.45
	impact(-0.3)


# --- Animation -----------------------------------------------------------------------------

## moving: speed as a share of normal walking speed. state: RobotEnemy.State. windup: 0-1 through
## the current wind-up. stunned: wobbling after a crash or a seismic slam.
func animate(dt: float, moving: float, state: int, windup: float, action: String, phase: int,
		stunned: bool) -> void:
	tick(dt)
	var sleeping: bool = state == RobotEnemy.State.SLEEP
	if _prev_state == RobotEnemy.State.WINDUP and state != RobotEnemy.State.WINDUP:
		_strike = _prev_action
		_strike_t = 0.5
		if _prev_action == "slam" or _prev_action == "bite":
			impact(0.3 if _prev_action == "slam" else 0.15)
		elif _prev_action == "nova":
			impact(-0.25)
	_prev_state = state
	_prev_action = action
	_strike_t = maxf(_strike_t - dt, 0.0)
	_wake_t = maxf(_wake_t - dt, 0.0)
	_kick = maxf(_kick - dt * 7.0, 0.0)
	_sleep_k = move_toward(_sleep_k, 1.0 if sleeping else 0.0, dt * 4.0)
	var m: float = clampf(moving, 0.0, 1.5)
	_gait += dt * (2.5 + 6.0 * m)
	var wind: float = windup if state == RobotEnemy.State.WINDUP else 0.0
	var strike: float = _strike_t / 0.5   # 1 right at the hit, easing to 0
	var energy: float = glow_base * (1.0 - 0.8 * _sleep_k) + wind * 4.0 + (1.2 if phase >= 2 else 0.0)
	if sleeping:
		energy += sin(t * 2.0 + _seed) * 0.3
	glow_mat.emission_energy_multiplier = maxf(energy, 0.15) + _wake_t * 8.0
	if kind != "foreman":  # its "eyes" are windows and lamps
		var bl: float = blink() if not sleeping else 0.5
		for e: MeshInstance3D in _eyes:
			e.scale = Vector3(1.0, bl, 1.0)
	var wobble: float = sin(t * 30.0) * 0.08 if stunned else 0.0
	match kind:
		"gunner":
			_anim_gunner(dt, m, state, wind, wobble)
		"bruiser":
			_anim_bruiser(dt, m, state, wind, action, strike, wobble)
		"foreman":
			_anim_foreman(dt, m, state, wind, action, strike, wobble, phase)
		"warden":
			_anim_warden(dt, m, state, wind, action, strike, wobble, phase)
		_:
			_anim_scuttler(dt, m, state, wind, strike, wobble)


func _anim_scuttler(_dt: float, m: float, _state: int, wind: float, strike: float, wobble: float) -> void:
	var breath: float = sin(t * 3.0 + _seed)
	var tuck: float = _sleep_k
	for i: int in range(_legs.size()):
		# Tripod gait: legs 0, 2, 4 and 1, 3, 5 alternate (left/right rows interleave).
		var ph: float = _gait * 2.0 + (PI if (i + int(i >= 3)) % 2 == 0 else 0.0)
		var side: float = -1.0 if i < 3 else 1.0
		_legs[i].rotation.y = _leg_yaw[i] + sin(ph) * 0.38 * m * side
		var lift: float = maxf(cos(ph), 0.0) * 0.35 * m
		# Each leg points along its own +X, so +Z rotation lifts the foot on either side.
		_legs[i].rotation.z = lift + tuck * 0.7 - wind * 0.2
	_body.position = Vector3(0.0, 0.42 + absf(sin(_gait * 2.0)) * 0.04 * m + breath * 0.008 - tuck * 0.2 - wind * 0.1,
		-wind * 0.12 + strike * 0.2)
	_body.rotation = Vector3(-wind * 0.35 + strike * 0.25, 0.0, sin(_gait * 2.0) * 0.06 * m + wobble)
	# Mandibles open during the wind-up and snap shut on the bite; twitch now and then.
	var open: float = wind * 0.7 + maxf(sin(t * 5.0 + _seed), 0.0) * 0.12 - strike * 0.3
	_bits[0].rotation.y = -open
	_bits[1].rotation.y = open
	_bits[2].rotation = Vector3(sin(t * 4.0 + _seed) * 0.25 - m * 0.3, 0.0, cos(t * 3.1) * 0.2)


func _anim_gunner(_dt: float, m: float, _state: int, wind: float, wobble: float) -> void:
	var breath: float = sin(t * 2.4 + _seed)
	var slump: float = _sleep_k
	var sw: float = sin(_gait) * m
	_legs[0].rotation.x = sw * 0.55
	_legs[1].rotation.x = -sw * 0.55
	var bob: float = absf(cos(_gait)) * 0.09 * m
	_body.position = Vector3(0.0, 1.05 + bob + breath * 0.01 - slump * 0.22 - wind * 0.06, 0.0)
	_body.rotation = Vector3(0.1 * m + slump * 0.45 + wind * 0.08, 0.0, sin(_gait) * 0.07 * m + wobble)
	# The head lags the body's bob, and scans around while idle.
	var idle: float = (1.0 - clampf(m * 2.0, 0.0, 1.0)) * (1.0 - slump)
	_head.rotation = Vector3(-bob * 1.2 + slump * 0.5 - wind * 0.1, sin(t * 0.9 + _seed) * 0.5 * idle, 0.0)
	_head.position.y = 0.34 - bob * 0.3
	_bits[0].rotation = Vector3(sin(t * 5.0 + _seed) * 0.2 - m * 0.25, 0.0, 0.0)
	# Cannon: hangs when idle, levels during the wind-up, kicks back with each shot.
	var aim_k: float = maxf(wind, _kick)
	_arms[0].rotation.x = lerpf(0.35 + sw * 0.15 + slump * 0.5, -0.05, aim_k) - _kick * 0.35
	_arms[0].position.z = 0.02 - _kick * 0.12
	_arms[1].rotation.x = -sw * 0.4 + breath * 0.04 + slump * 0.3
	if _kick > 0.9:
		impact(0.03)


func _anim_bruiser(_dt: float, m: float, _state: int, wind: float, action: String, strike: float,
		wobble: float) -> void:
	var breath: float = sin(t * 1.8 + _seed)
	var slump: float = _sleep_k
	var sw: float = sin(_gait) * m
	_legs[0].rotation.x = sw * 0.45
	_legs[1].rotation.x = -sw * 0.45
	# Each heavy footfall thumps the body.
	if m > 0.2 and signf(sw) != _step_sign:
		_step_sign = signf(sw)
		impact(0.05)
	var lean: float = 0.12 * m + slump * 0.35
	var arm: float = 0.15 - sw * 0.5
	var arm2: float = 0.15 + sw * 0.5
	var elbow: float = -0.25
	var slam_wind: float = wind if action == "slam" else 0.0
	lean = lerpf(lean, -0.3, slam_wind)
	arm = lerpf(arm, -2.8, slam_wind)
	arm2 = lerpf(arm2, -2.8, slam_wind)
	elbow = lerpf(elbow, -0.7, slam_wind)
	if _strike == "slam" and strike > 0.0:
		var hit: float = sin(strike * PI * 0.5)
		lean = lerpf(lean, 0.6, hit)
		arm = lerpf(arm, -1.1, hit)
		arm2 = lerpf(arm2, -1.1, hit)
		elbow = lerpf(elbow, -0.1, hit)
	_body.position = Vector3(0.0, 1.22 + absf(cos(_gait)) * 0.06 * m + breath * 0.015 - slump * 0.18, 0.0)
	_body.rotation = Vector3(lean, sin(_gait) * 0.1 * m, sin(_gait) * 0.08 * m + wobble)
	_arms[0].rotation = Vector3(arm, 0.0, 0.12 + breath * 0.03)
	_arms[1].rotation = Vector3(arm2, 0.0, -0.12 - breath * 0.03)
	_elbows[0].rotation.x = elbow
	_elbows[1].rotation.x = elbow
	_head.rotation = Vector3(-slam_wind * 0.4 + slump * 0.4, sin(t * 0.7 + _seed) * 0.25 * (1.0 - m), 0.0)


func _anim_foreman(dt: float, m: float, state: int, wind: float, action: String, strike: float,
		wobble: float, phase: int) -> void:
	var charging: bool = state == RobotEnemy.State.CHARGE
	var spd: float = m * (3.0 if charging else 1.0)
	for w: int in range(6):
		_bits[w].rotation.x += dt * spd * 9.0
	var rumble: float = sin(t * 23.0) * 0.012 * (1.0 + m) + (sin(t * 41.0) * 0.02 if phase >= 2 else 0.0)
	var lean: float = 0.06 * m + (0.16 if charging else 0.0)
	var arm: float = sin(t * 1.3 + _seed) * 0.08
	var open: float = 0.15 + maxf(sin(t * 2.6 + _seed), 0.0) * 0.25
	var slam_wind: float = wind if action == "slam" else 0.0
	var charge_wind: float = wind if action == "charge" else 0.0
	arm = lerpf(arm, -1.0, slam_wind)
	open = lerpf(open, 0.7, maxf(slam_wind, charge_wind))
	lean = lerpf(lean, -0.12, charge_wind)
	if charging:
		arm = 0.25
		open = 0.6
	if _strike == "slam" and strike > 0.0:
		var hit: float = sin(strike * PI * 0.5)
		arm = lerpf(arm, 0.4, hit)
		open = lerpf(open, 0.0, hit)
		lean = lerpf(lean, 0.15, hit)
	_body.position = Vector3(0.0, 1.05 + rumble - _sleep_k * 0.1, -0.1)
	_body.rotation = Vector3(lean, 0.0, wobble)
	for a: int in range(2):
		_arms[a].rotation.x = arm + _sleep_k * 0.3
		_elbows[a].rotation.x = -arm * 0.5
	for p: int in range(6, 10):
		var up: float = 1.0 if (p - 6) % 2 == 0 else -1.0
		_bits[p].rotation.x = -open * up
	_legs[0].rotation.x = 0.0
	_legs[1].rotation.x = 0.0


func _anim_warden(dt: float, m: float, _state: int, wind: float, action: String, strike: float,
		wobble: float, phase: int) -> void:
	var breath: float = sin(t * 1.5 + _seed)
	var sw: float = sin(_gait) * m
	_legs[0].rotation.x = sw * 0.35
	_legs[1].rotation.x = -sw * 0.35
	if m > 0.2 and signf(sw) != _step_sign:
		_step_sign = signf(sw)
		impact(0.06)
	var lean: float = 0.08 * m + _sleep_k * 0.3
	var arm: Array[float] = [sin(_gait + PI) * 0.25 * m + breath * 0.05, sin(_gait) * 0.25 * m + breath * 0.05]
	var spread: float = 0.12
	var head_x: float = 0.0
	var slam_wind: float = wind if action == "slam" else 0.0
	var nova_wind: float = wind if action == "nova" else 0.0
	for a: int in range(2):
		arm[a] = lerpf(arm[a], -2.6, slam_wind)
		arm[a] = lerpf(arm[a], -0.6, nova_wind)
	spread = lerpf(spread, 1.1, nova_wind)
	lean = lerpf(lean, -0.25, maxf(slam_wind, nova_wind * 0.6))
	head_x = -0.35 * nova_wind - 0.2 * slam_wind
	if strike > 0.0:
		var hit: float = sin(strike * PI * 0.5)
		if _strike == "slam":
			for b: int in range(2):
				arm[b] = lerpf(arm[b], -1.2, hit)
			lean = lerpf(lean, 0.5, hit)
		elif _strike == "nova":
			spread = lerpf(spread, 1.4, hit)
			head_x = lerpf(head_x, -0.4, hit)
	_body.position = Vector3(0.0, 1.75 + absf(cos(_gait)) * 0.05 * m + breath * 0.025 - _sleep_k * 0.15, 0.0)
	_body.rotation = Vector3(lean, sin(_gait) * 0.08 * m, sin(_gait) * 0.06 * m + wobble)
	_arms[0].rotation = Vector3(arm[0], 0.0, spread)
	_arms[1].rotation = Vector3(arm[1], 0.0, -spread)
	for e: int in range(2):
		_elbows[e].rotation.x = -0.3 - 0.3 * slam_wind
	_head.rotation = Vector3(head_x + _sleep_k * 0.4, sin(t * 0.5 + _seed) * 0.2 * (1.0 - m), 0.0)
	# The core throbs (faster in phase 2) and the shards orbit and bob.
	var pulse: float = 1.0 + sin(t * (5.0 if phase >= 2 else 3.0)) * 0.08 + nova_wind * 0.3
	_eyes[0].scale = Vector3(pulse, pulse, 1.0)
	var orbit_speed: float = (2.4 if phase >= 2 else 1.4) * (1.0 - _sleep_k * 0.8) + nova_wind * 4.0
	for i: int in range(3):
		var orb: Node3D = _bits[i]
		orb.rotation.y += dt * orbit_speed
		orb.position.y = 1.9 + sin(t * 2.0 + float(i) * 2.1) * 0.15 - _sleep_k * 0.6
