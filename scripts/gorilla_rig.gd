class_name GorillaRig
extends Rig

## The player's gorilla robot: hunched sculpted torso, huge knuckle-walking forearms, a low head
## with a heavy brow, glowing eyes and a jaw that drops open when the mouth cannon fires.
## Each forearm has a blade emitter on its outer side: an energy blade in the team colour shoots
## out of it when the bot attacks, stays out while it keeps fighting and slides back in after.
## GorillaBot calls the event methods (slash, slam, fire, hurt, dash, knock_down, revive) and
## animate() every step.

const METAL: Color = Color(0.5, 0.53, 0.6)
const DARK: Color = Color(0.22, 0.24, 0.3)
const SILVER: Color = Color(0.8, 0.82, 0.86)
const EYE: Color = Color(0.45, 0.95, 1.0)
const MOUTH: Color = Color(1.0, 0.55, 0.15)
const HUNCH: float = 0.3
const BLADE_LEN: float = 1.55
const BLADE_HOLD: float = 0.9     # seconds the blades stay out after the last attack
const SLASH_TIME: float = 0.3

var team: Color = Color.ORANGE
var yaw: float = 0.0

var _hips: Node3D
var _torso: Node3D
var _head: Node3D
var _jaw: Node3D
var _arms: Array[Node3D] = []
var _elbows: Array[Node3D] = []
var _legs: Array[Node3D] = []
var _eyes: Array[MeshInstance3D] = []
var _mouth: MeshInstance3D
var _mouth_mat: StandardMaterial3D
var _eye_mat: StandardMaterial3D
var _walk: float = 0.0
var _slash_t: float = 0.0
var _slash_side: int = 0
var _blades: Array[Node3D] = []
var _blade_mat: StandardMaterial3D
var _blade_out: float = 0.0       # 0 = sheathed, 1 = fully out
var _blade_hold: float = 0.0
var _slam_t: float = 0.0
var _slammed: bool = false
var _fire_t: float = 0.0
var _dash_t: float = 0.0
var _down: bool = false
var _down_k: float = 0.0
var _twist: float = 0.0


func setup(team_color: Color) -> void:
	team = team_color
	var tk: String = team.to_html()
	_eye_mat = Art.glow_mat(EYE, 2.6)
	_mouth_mat = Art.glow_mat(MOUTH, 1.0)
	_blade_mat = Art.glow_mat(team.lerp(Color.WHITE, 0.35), 2.2)
	# Hips and stubby legs.
	_hips = joint(root, Vector3(0.0, 0.7, -0.1))
	shape(_hips, "gor_hips", _m_hips)
	for s: float in [-1.0, 1.0]:
		var leg: Node3D = joint(_hips, Vector3(0.24 * s, -0.02, -0.02))
		shape(leg, "gor_leg", _m_leg)
		_legs.append(leg)
	# Hunched torso with a big back, team chest plate and shoulder pads.
	_torso = joint(root, Vector3(0.0, 0.78, -0.08))
	shape(_torso, "gor_torso_" + tk, _m_torso)
	# Head: low and forward, heavy brow, glowing eyes, dropping jaw.
	_head = joint(_torso, Vector3(0.0, 0.8, 0.33))
	shape(_head, "gor_head", _m_head)
	for s4: float in [-1.0, 1.0]:
		var e: MeshInstance3D = glow(_head, "gor_eye", _m_eye, _eye_mat)
		e.position = Vector3(0.115 * s4, 0.085, 0.285)
		_eyes.append(e)
	_jaw = joint(_head, Vector3(0.0, -0.06, 0.06))
	shape(_jaw, "gor_jaw", _m_jaw)
	_mouth = glow(_jaw, "gor_mouth", _m_mouth, _mouth_mat)
	_mouth.position = Vector3(0.0, -0.05, 0.32)
	# Long arms: upper arm, then an elbow with a huge forearm and fist.
	for s5: float in [-1.0, 1.0]:
		var arm: Node3D = joint(_torso, Vector3(0.66 * s5, 0.6, 0.02))
		shape(arm, "gor_upper", _m_upper)
		var elbow: Node3D = joint(arm, Vector3(0.0, -0.52, 0.02))
		shape(elbow, "gor_fore_" + tk, _m_fore)
		# The blade emitter on the outside of the forearm, and the blade that slides out of it
		# along the arm, past the fist.
		var em: Node3D = joint(elbow, Vector3(0.21 * s5, -0.4, 0.03))
		shape(em, "gor_emitter", _m_emitter)
		var blade: Node3D = joint(em, Vector3(0.0, -0.12, 0.0))
		glow(blade, "gor_blade", _m_blade, _blade_mat)
		glow(blade, "gor_blade_core", _m_blade_core, Art.glow_mat(Color.WHITE, 3.0))
		blade.scale = Vector3(1.0, 0.02, 1.0)
		blade.visible = false
		_arms.append(arm)
		_elbows.append(elbow)
		_blades.append(blade)


# --- Meshes (built once per team colour, then cached) ------------------------------------

func _m_hips() -> Sculpt:
	return Sculpt.new().blob(Vector3.ZERO, Vector3(0.36, 0.2, 0.26), DARK, 0.7)


func _m_leg() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.32, 0.07), Vector3(0.0, -0.58, -0.02)], [0.15, 0.13, 0.12], METAL)
	sc.blob(Vector3(0.0, -0.33, 0.08), Vector3(0.12, 0.11, 0.11), DARK, 0.8)
	sc.blob(Vector3(0.0, -0.63, 0.07), Vector3(0.15, 0.08, 0.22), DARK, 0.5)
	return sc


func _m_torso() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.42, -0.02), Vector3(0.56, 0.46, 0.4), METAL, 0.62, Vector3.ZERO, 0.25)
	sc.blob(Vector3(0.0, 0.58, -0.2), Vector3(0.46, 0.32, 0.28), METAL, 0.8)
	sc.blob(Vector3(0.0, 0.1, 0.06), Vector3(0.4, 0.22, 0.3), DARK, 0.75)
	sc.blob(Vector3(0.0, 0.46, 0.33), Vector3(0.4, 0.28, 0.1), team, 0.5, Vector3(-12.0, 0.0, 0.0))
	sc.blob(Vector3(0.0, 0.5, 0.38), Vector3(0.14, 0.09, 0.05), SILVER, 0.6, Vector3(-12.0, 0.0, 0.0))
	for s: float in [-1.0, 1.0]:
		sc.blob(Vector3(0.6 * s, 0.66, 0.0), Vector3(0.26, 0.25, 0.26), METAL, 0.75)
		sc.blob(Vector3(0.62 * s, 0.79, 0.0), Vector3(0.25, 0.1, 0.25), team, 0.55, Vector3(0.0, 0.0, -14.0 * s))
		sc.blob(Vector3(0.22 * s, 0.6, -0.44), Vector3(0.09, 0.15, 0.06), DARK, 0.5)
	return sc


func _m_head() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3(0.0, 0.1, -0.02), Vector3(0.31, 0.27, 0.28), METAL, 0.6)
	sc.blob(Vector3(0.0, 0.18, 0.2), Vector3(0.34, 0.085, 0.11), DARK, 0.5)
	sc.blob(Vector3(0.0, 0.03, 0.18), Vector3(0.25, 0.14, 0.11), SILVER, 0.55)
	sc.blob(Vector3(0.0, 0.34, -0.05), Vector3(0.1, 0.06, 0.22), DARK, 0.6)
	return sc


func _m_eye() -> Sculpt:
	return Sculpt.new().blob(Vector3.ZERO, Vector3(0.075, 0.045, 0.035), Color.WHITE, 0.6)


func _m_jaw() -> Sculpt:
	return Sculpt.new().blob(Vector3(0.0, -0.08, 0.14), Vector3(0.27, 0.11, 0.18), DARK, 0.55)


func _m_mouth() -> Sculpt:
	return Sculpt.new().blob(Vector3.ZERO, Vector3(0.14, 0.035, 0.03), Color.WHITE, 0.5)


func _m_upper() -> Sculpt:
	return Sculpt.new().tube([Vector3.ZERO, Vector3(0.0, -0.52, 0.02)], [0.16, 0.14], METAL)


func _m_fore() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.tube([Vector3.ZERO, Vector3(0.0, -0.24, 0.03), Vector3(0.0, -0.46, 0.05)], [0.15, 0.22, 0.24], DARK)
	sc.blob(Vector3(0.0, -0.3, 0.04), Vector3(0.255, 0.08, 0.255), team, 0.6)
	sc.blob(Vector3(0.0, -0.64, 0.07), Vector3(0.27, 0.21, 0.29), METAL, 0.45, Vector3.ZERO, 0.15)
	for k: int in range(3):
		sc.blob(Vector3(-0.12 + 0.12 * float(k), -0.74, 0.24), Vector3(0.07, 0.07, 0.07), SILVER, 0.8)
	return sc


func _m_emitter() -> Sculpt:
	var sc: Sculpt = Sculpt.new()
	sc.blob(Vector3.ZERO, Vector3(0.075, 0.2, 0.11), DARK, 0.45)
	sc.blob(Vector3(0.0, -0.17, 0.0), Vector3(0.06, 0.05, 0.09), SILVER, 0.5)
	return sc


func _m_blade() -> Sculpt:
	return Sculpt.new().blob(Vector3(0.0, -BLADE_LEN * 0.5, 0.0), Vector3(0.035, BLADE_LEN * 0.5, 0.12), Color.WHITE, 0.55,
		Vector3.ZERO, 0.35)


func _m_blade_core() -> Sculpt:
	return Sculpt.new().blob(Vector3(0.0, -BLADE_LEN * 0.47, 0.0), Vector3(0.04, BLADE_LEN * 0.44, 0.045), Color.WHITE, 0.8)


# --- Events and animation ------------------------------------------------------------------

## A blade swing with one arm (side 0 or 1): the blades snap out, the arm winds out to the side
## and sweeps across in front of the bot.
func slash(side: int) -> void:
	_slash_t = SLASH_TIME
	_slash_side = side
	_blade_hold = BLADE_HOLD


func slam() -> void:
	_slam_t = 0.42
	_slammed = false
	_blade_hold = BLADE_HOLD


## How far the blades are out, 0 to 1 (the smoke test reads it).
func blades_out() -> float:
	return _blade_out


func fire() -> void:
	_fire_t = 0.16


func hurt(push_dir: Vector3) -> void:
	flash(Color(1.0, 0.35, 0.3), 0.12)
	recoil(push_dir, 1.0)
	impact(0.12)


func dash() -> void:
	_dash_t = 0.18
	impact(-0.18)


func knock_down() -> void:
	_down = true
	impact(0.25)


func revive() -> void:
	_down = false
	_down_k = 0.0
	impact(-0.25)


## velocity: the bot's world velocity. aim: the facing direction. energy_k: 0-1 cannon energy.
func animate(dt: float, velocity: Vector3, aim: Vector3, energy_k: float) -> void:
	tick(dt)
	var target_yaw: float = atan2(aim.x, aim.z)
	var turn: float = wrapf(target_yaw - yaw, -PI, PI)
	yaw = lerp_angle(yaw, target_yaw, minf(dt * 16.0, 1.0))
	rotation.y = yaw
	var flat: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var m: float = clampf(flat.length() / Balance.PLAYER_SPEED, 0.0, 1.4)
	# Which way we move relative to facing (strafing and backing up swing the legs less).
	var local: Vector3 = global_transform.basis.inverse() * flat if m > 0.05 else Vector3.ZERO
	_walk += dt * (2.0 + 7.5 * m)
	var sw: float = sin(_walk) * m
	var breath: float = sin(t * 2.3 + _seed)
	# Legs swing; stance widens a touch when standing.
	_legs[0].rotation.x = sw * 0.75
	_legs[1].rotation.x = -sw * 0.75
	_legs[0].rotation.z = -0.06 * (1.0 - m)
	_legs[1].rotation.z = 0.06 * (1.0 - m)
	_hips.position.y = 0.7 + absf(cos(_walk)) * 0.07 * m
	# Torso: hunch, lean into the run, swagger roll, breathing, twist from turning and slashing.
	var lean: float = HUNCH + 0.16 * m + clampf(local.z, -1.0, 1.0) * 0.04
	var roll: float = sin(_walk) * 0.09 * m - clampf(local.x / Balance.PLAYER_SPEED, -1.0, 1.0) * 0.08
	_twist = lerpf(_twist, clampf(turn, -0.6, 0.6) * 0.35, minf(dt * 10.0, 1.0))
	var twist: float = sin(_walk) * 0.12 * m - _twist
	_torso.position.y = 0.78 + absf(cos(_walk)) * 0.08 * m + breath * 0.012
	var arm_x: Array[float] = [-0.42 - sin(_walk - 0.5) * 0.75 * m, -0.42 + sin(_walk - 0.5) * 0.75 * m]
	var elbow_x: Array[float] = [-0.3 - maxf(sin(_walk - 0.9), 0.0) * 0.5 * m, -0.3 - maxf(-sin(_walk - 0.9), 0.0) * 0.5 * m]
	var arm_z: Array[float] = [0.08 + breath * 0.025, -0.08 - breath * 0.025]
	# Idle: arms sway with the breath, head glances around.
	var idle: float = 1.0 - clampf(m * 2.0, 0.0, 1.0)
	var head_yaw: float = sin(t * 0.6 + _seed) * 0.2 * idle + clampf(turn, -0.7, 0.7) * 0.6
	var head_x: float = -0.05 + breath * 0.03 * idle
	var arm_y: Array[float] = [0.0, 0.0]
	# Blades: out fast while fighting, back in slowly once the bot stops.
	_blade_hold = maxf(_blade_hold - dt, 0.0)
	_blade_out = move_toward(_blade_out, 1.0 if _blade_hold > 0.0 else 0.0, dt * (14.0 if _blade_hold > 0.0 else 5.0))
	# While the blades are out, the forearms come up off the ground so the blades don't drag.
	var guard: float = smoothstep(0.0, 1.0, _blade_out)
	for g: int in range(2):
		arm_x[g] = lerpf(arm_x[g], -0.95, guard * 0.8)
		elbow_x[g] = lerpf(elbow_x[g], -0.85, guard * 0.8)
	# Slash: the arm swings out to its side and back, then sweeps across in front, arm straight.
	_slash_t = maxf(_slash_t - dt, 0.0)
	if _slash_t > 0.0:
		var k: float = 1.0 - _slash_t / SLASH_TIME
		var i: int = _slash_side
		var out_sign: float = -1.0 if i == 0 else 1.0   # arm 0 sits on the -x side
		var wind: float = smoothstep(0.0, 0.16, k)
		var sweep: float = smoothstep(0.12, 0.45, k)   # the sweep is over by about 0.14 s
		var settle: float = smoothstep(0.65, 1.0, k)
		var reach: float = wind - settle * 0.9
		arm_x[i] = lerpf(arm_x[i], -1.5, clampf(reach, 0.0, 1.0))
		elbow_x[i] = lerpf(elbow_x[i], lerpf(-0.7, -0.05, sweep), clampf(reach, 0.0, 1.0))
		arm_y[i] = (out_sign * 1.15 * wind - out_sign * 2.1 * sweep) * (1.0 - settle)
		twist += out_sign * (0.35 * wind - 0.8 * sweep) * (1.0 - settle)
		lean += 0.1 * sweep * (1.0 - settle)
	# Slam: both arms high overhead, then down into the floor with a squash.
	_slam_t = maxf(_slam_t - dt, 0.0)
	if _slam_t > 0.0:
		var k2: float = 1.0 - _slam_t / 0.42
		var up_k: float = clampf(k2 / 0.3, 0.0, 1.0)
		var down_k: float = clampf((k2 - 0.3) / 0.12, 0.0, 1.0)
		var rec: float = clampf((k2 - 0.6) / 0.4, 0.0, 1.0)
		var raise: float = sin(up_k * PI * 0.5) * (1.0 - down_k)
		var hit: float = down_k * (1.0 - rec)
		for j: int in range(2):
			arm_x[j] = lerpf(lerpf(arm_x[j], -3.0, raise), -1.25, hit)
			elbow_x[j] = lerpf(lerpf(elbow_x[j], -0.5, raise), -0.1, hit)
			arm_z[j] *= 1.0 - raise
		lean = lerpf(lerpf(lean, 0.05, raise), 0.85, hit)
		head_x += -0.35 * raise + 0.2 * hit
		if down_k >= 1.0 and not _slammed:
			_slammed = true
			impact(0.3)
	# Dash: lunge forward, arms trail.
	_dash_t = maxf(_dash_t - dt, 0.0)
	if _dash_t > 0.0:
		var d: float = _dash_t / 0.18
		lean += 0.45 * d
		for j2: int in range(2):
			arm_x[j2] = lerpf(arm_x[j2], 0.7, d)
			elbow_x[j2] = lerpf(elbow_x[j2], -0.6, d)
	for a: int in range(2):
		_arms[a].rotation = Vector3(arm_x[a], arm_y[a], arm_z[a])
		_elbows[a].rotation.x = elbow_x[a]
		_blades[a].visible = _blade_out > 0.03
		_blades[a].scale = Vector3(1.0, maxf(_blade_out, 0.02), 1.0)
	_blade_mat.emission_energy_multiplier = 2.0 + 0.4 * sin(t * 30.0) + 1.5 * (_slash_t / SLASH_TIME)
	_torso.rotation = Vector3(lean, twist, roll)
	# Mouth cannon: head jerks back and the jaw drops open around the glow.
	_fire_t = maxf(_fire_t - dt, 0.0)
	var f: float = _fire_t / 0.16
	_head.rotation = Vector3(head_x - 0.3 * f, head_yaw, 0.0)
	_jaw.rotation.x = 0.55 * f + 0.04 * maxf(breath, 0.0)
	_mouth_mat.emission_energy_multiplier = 1.0 + 6.0 * f + energy_k * 0.8
	_mouth.scale = Vector3(1.0 + 0.3 * f, 1.0 + 2.2 * f, 1.0)
	var bl: float = blink()
	for e: MeshInstance3D in _eyes:
		e.scale = Vector3(1.0, bl, 1.0)
	_eye_mat.emission_energy_multiplier = 2.4 + sin(t * 3.0) * 0.3
	_down_k = 0.0


## The knocked-out pose, eased in while the bot waits for a reboot.
func animate_down(dt: float) -> void:
	tick(dt)
	_down_k = minf(_down_k + dt * 5.0, 1.0)
	var k: float = sin(_down_k * PI * 0.5)
	_torso.rotation = Vector3(lerpf(HUNCH, 1.35, k), 0.0, 0.0)
	_torso.position.y = lerpf(0.78, 0.35, k)
	_hips.position.y = lerpf(0.7, 0.3, k)
	_head.rotation = Vector3(0.4 * k, 0.3 * k, 0.0)
	_jaw.rotation.x = 0.3 * k
	for a: int in range(2):
		_arms[a].rotation = Vector3(-1.2 * k, 0.0, (0.5 if a == 0 else -0.5) * k)
		_elbows[a].rotation.x = -0.2
		_legs[a].rotation.x = -1.2 * k
	_eye_mat.emission_energy_multiplier = 0.3 + 0.3 * absf(sin(t * 4.0))
	_mouth_mat.emission_energy_multiplier = 0.2
	_blade_out = 0.0
	_blade_hold = 0.0
	for b: Node3D in _blades:
		b.visible = false
