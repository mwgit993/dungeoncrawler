class_name GorillaBot
extends CharacterBody3D

## The player: a gorilla robot that slashes with energy blades that slide out of its forearms and
## fires a plasma cannon from its mouth.
## Player 1 listens to keyboard + mouse and the first controller; co-op players each own a
## controller. The model is built from boxes and animated in code (knuckle-walk, blade slashes, slam).
##
## Keyboard/mouse: WASD move, mouse aims, left click blades, right click mouth cannon, Space dash,
## Q repair kit, E interact.
## Controller: left stick move, right stick aim, X / RB blades, B / RT cannon, A dash, LB repair
## kit, Y interact.

signal died(bot: GorillaBot)

const RADIUS: float = 0.55
const DEADZONE: float = 0.22

var slot: int = 0
var kbm: bool = true
var pad: int = -1
var color: Color = Color.ORANGE
var level: LevelMap

var hp: float = 100.0
var max_hp: float = 100.0
var shield: float = 0.0
var energy: float = 100.0
var energy_max: float = 100.0
var alive: bool = true
var input_enabled: bool = true
var aim: Vector3 = Vector3(0.0, 0.0, 1.0)
var interact_pressed: bool = false   # true for the one step interact was pressed
var pause_pressed: bool = false
var respawn_left: float = 0.0
var scripted: bool = false           # smoke test: read `sim` instead of devices
var sim: Dictionary = {}
var using_pad: bool = false          # last input came from the controller (for button prompts)

# Online co-op (see Net). "" is a normal local bot. On the host, "remote" is a client's bot: it
# goes where that client says and attacks with its buttons (net_state). On a client, "local" is
# our own bot, moved here and now while the host does the fighting, and "puppet" is everyone
# else's, drawn where the host's snapshots put them.
var net_mode: String = ""
var peer_id: int = 0
var net_state: Array = []            # host: the client's last input (see net_input)
var tp_seq: int = 0                  # bumps when the host moves the bot itself (level start, reboot)
var _net_pos: Vector3 = Vector3.ZERO
var _net_vel: Vector3 = Vector3.ZERO
var _net_kit_n: int = 0
var _net_int_n: int = 0
var _net_dashing: bool = false
var _net_blink: bool = false
var _net_tp_seen: int = -1
var _kit_presses: int = 0            # client: presses counted up, so the host can't miss a tap
var _int_presses: int = 0

var _dash_t: float = 0.0
var _dash_cd: float = 0.0
var _dash_dir: Vector3 = Vector3.ZERO
var _melee_cd: float = 0.0
var _combo: int = 0
var _combo_t: float = 0.0
var _cannon_cd: float = 0.0
var _regen_delay: float = 0.0
var _iframes: float = 0.0
var _prev: Dictionary = {}
var _mouse_last: Vector2 = Vector2(-1.0, -1.0)
var _use_mouse: bool = true

# Model and animation state.
var rig: GorillaRig
var _down_t: float = 0.0
var _slam_t: float = 0.0
var _slash_side: int = 0


func setup(lvl: LevelMap, player_slot: int, uses_kbm: bool, pad_id: int) -> void:
	level = lvl
	slot = player_slot
	kbm = uses_kbm
	pad = pad_id
	color = Art.PLAYER_COLORS[slot % Art.PLAYER_COLORS.size()]
	name = "Player%d" % (slot + 1)
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = 2
	collision_mask = 1
	var cs: CollisionShape3D = CollisionShape3D.new()
	var cap: CapsuleShape3D = CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = 1.9
	cs.shape = cap
	cs.position = Vector3(0.0, 0.95, 0.0)
	add_child(cs)
	rig = GorillaRig.new()
	rig.name = "Rig"
	add_child(rig)
	rig.setup(color)
	Art.blob_shadow(self, 0.95)
	reset_stats()


## Full HP and energy, with the current upgrades applied.
func reset_stats() -> void:
	max_hp = Game.max_hp()
	hp = max_hp
	energy_max = Game.energy_max()
	energy = energy_max
	shield = 0.0
	alive = true
	_iframes = 0.0
	_dash_t = 0.0
	_down_t = 0.0
	if rig != null:
		rig.revive()


func move_level(lvl: LevelMap, pos: Vector3) -> void:
	level = lvl
	global_position = pos
	velocity = Vector3.ZERO
	_net_pos = pos
	tp_seq += 1


# --- Input ------------------------------------------------------------------------------

func _read_input() -> Dictionary:
	if scripted:
		return sim.duplicate()
	var inp: Dictionary = {"move": Vector2.ZERO, "melee": false, "cannon": false, "dash": false,
		"interact": false, "kit": false, "pause": false}
	var mv: Vector2 = Vector2.ZERO
	if kbm:
		if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
			mv.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
			mv.x += 1.0
		if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
			mv.y -= 1.0
		if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
			mv.y += 1.0
		inp["melee"] = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		inp["cannon"] = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		inp["dash"] = Input.is_physical_key_pressed(KEY_SPACE) or Input.is_physical_key_pressed(KEY_SHIFT)
		inp["interact"] = Input.is_physical_key_pressed(KEY_E)
		inp["kit"] = Input.is_physical_key_pressed(KEY_Q)
		if mv != Vector2.ZERO or bool(inp["melee"]) or bool(inp["cannon"]):
			using_pad = false
		var mouse: Vector2 = get_viewport().get_mouse_position()
		if _mouse_last.x >= 0.0 and mouse.distance_to(_mouse_last) > 1.5:
			_use_mouse = true
			using_pad = false
		_mouse_last = mouse
	if pad >= 0 and pad in Input.get_connected_joypads():
		var stick: Vector2 = Vector2(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))
		if stick.length() > DEADZONE:
			mv += stick
			using_pad = true
		var rs: Vector2 = Vector2(Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X), Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y))
		if rs.length() > 0.35:
			inp["aim_screen"] = rs.normalized()
			_use_mouse = false
			using_pad = true
		var b_melee: bool = Input.is_joy_button_pressed(pad, JOY_BUTTON_X) or Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER)
		var b_cannon: bool = Input.is_joy_button_pressed(pad, JOY_BUTTON_B) or Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_RIGHT) > 0.45
		var b_dash: bool = Input.is_joy_button_pressed(pad, JOY_BUTTON_A)
		var b_int: bool = Input.is_joy_button_pressed(pad, JOY_BUTTON_Y)
		var b_kit: bool = Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_SHOULDER)
		if b_melee or b_cannon or b_dash or b_int or b_kit:
			using_pad = true
			_use_mouse = false
		inp["melee"] = bool(inp["melee"]) or b_melee
		inp["cannon"] = bool(inp["cannon"]) or b_cannon
		inp["dash"] = bool(inp["dash"]) or b_dash
		inp["interact"] = bool(inp["interact"]) or b_int
		inp["kit"] = bool(inp["kit"]) or b_kit
		inp["pause"] = Input.is_joy_button_pressed(pad, JOY_BUTTON_START)
	if mv.length() > 1.0:
		mv = mv.normalized()
	inp["move"] = mv
	return inp


## Turns a screen-space direction (x right, y down) into a flat world direction.
static func screen_to_world(v: Vector2) -> Vector3:
	var yaw: float = deg_to_rad(Balance.CAMERA_YAW)
	var right: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
	var up: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))
	return right * v.x - up * v.y


func _mouse_aim() -> Vector3:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return aim
	var mp: Vector2 = get_viewport().get_mouse_position()
	var o: Vector3 = cam.project_ray_origin(mp)
	var d: Vector3 = cam.project_ray_normal(mp)
	if absf(d.y) < 0.001:
		return aim
	var t: float = (1.0 - o.y) / d.y
	var hit: Vector3 = o + d * t
	var v: Vector3 = hit - global_position
	v.y = 0.0
	return v.normalized() if v.length() > 0.2 else aim


func _edge(inp: Dictionary, key: String) -> bool:
	var now: bool = bool(inp.get(key, false))
	var was: bool = bool(_prev.get(key, false))
	_prev[key] = now
	return now and not was


# --- Update -----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if level != null:
		step(minf(delta, 0.05))


func step(dt: float) -> void:
	interact_pressed = false
	pause_pressed = false
	if net_mode == "puppet":
		_puppet_step(dt)
		return
	_tick_timers(dt)
	if not alive:
		_down_t += dt
		rig.animate_down(dt)
		return
	if net_mode == "remote":
		_remote_step(dt)
		return
	var inp: Dictionary = _read_input() if input_enabled else {}
	interact_pressed = _edge(inp, "interact")
	pause_pressed = _edge(inp, "pause")
	if net_mode == "local":
		if interact_pressed:
			_int_presses += 1
		if _edge(inp, "kit"):
			_kit_presses += 1
	var mv: Vector2 = inp.get("move", Vector2.ZERO)
	var move_dir: Vector3 = screen_to_world(mv)
	# Aim: mouse, right stick, a scripted direction, or the way we're walking.
	if inp.has("aim"):
		var a: Vector3 = inp["aim"]
		if a.length() > 0.01:
			aim = Vector3(a.x, 0.0, a.z).normalized()
	elif inp.has("aim_screen"):
		aim = screen_to_world(inp["aim_screen"]).normalized()
	elif kbm and _use_mouse and not scripted and input_enabled:
		aim = _mouse_aim()
	elif move_dir.length() > 0.3:
		aim = move_dir.normalized()
	# Movement and dash.
	var speed: float = Balance.PLAYER_SPEED * Game.speed_mult()
	if _edge(inp, "dash") and _dash_cd <= 0.0:
		_dash_dir = move_dir.normalized() if move_dir.length() > 0.2 else aim
		_dash_t = Balance.DASH_TIME
		_dash_cd = Game.dash_cooldown()
		Sfx.play("dash", -8.0)
		Fx.afterimage(level.fx_root, global_position, color)
		_rig("dash", [])
	if _dash_t > 0.0:
		velocity = _dash_dir * Balance.DASH_SPEED
	else:
		var slow: float = 0.55 if _slam_t > 0.0 else 1.0
		velocity = velocity.move_toward(move_dir * speed * slow, Balance.PLAYER_ACCEL * dt)
	_slide(velocity * dt)
	if net_mode == "local":
		# Our own bot online: the host swings and fires for us from the buttons we send.
		net_state = [bool(inp.get("melee", false)), bool(inp.get("cannon", false))]
		rig.animate(dt, velocity, aim, energy / maxf(energy_max, 1.0))
		rig.visible = not _net_blink or fmod(float(Time.get_ticks_msec()) * 0.001, 0.12) > 0.05 or _dash_t > 0.0
		return
	# Attacks.
	if bool(inp.get("melee", false)) and _melee_cd <= 0.0:
		_melee()
	if bool(inp.get("cannon", false)) and _cannon_cd <= 0.0:
		_fire_cannon()
	if _edge(inp, "kit"):
		use_kit()
	rig.animate(dt, velocity, aim, energy / maxf(energy_max, 1.0))
	# Blink while invulnerable after a hit.
	rig.visible = _iframes <= 0.0 or fmod(_iframes, 0.12) > 0.05 or _dash_t > 0.0


func _tick_timers(dt: float) -> void:
	_dash_t = maxf(_dash_t - dt, 0.0)
	_dash_cd = maxf(_dash_cd - dt, 0.0)
	_melee_cd = maxf(_melee_cd - dt, 0.0)
	_cannon_cd = maxf(_cannon_cd - dt, 0.0)
	_iframes = maxf(_iframes - dt, 0.0)
	_combo_t = maxf(_combo_t - dt, 0.0)
	_slam_t = maxf(_slam_t - dt, 0.0)
	if _regen_delay > 0.0:
		_regen_delay -= dt
	elif alive:
		energy = minf(energy + Game.energy_regen() * dt, energy_max)


func _slide(motion: Vector3) -> void:
	motion.y = 0.0
	for i: int in range(3):
		if motion.length() < 0.0005:
			break
		var col: KinematicCollision3D = move_and_collide(motion)
		if col == null:
			break
		var n: Vector3 = col.get_normal()
		n.y = 0.0
		if n.length() < 0.01:
			break
		n = n.normalized()
		motion = col.get_remainder().slide(n)
		velocity = velocity.slide(n)
	position.y = 0.0


# --- Actions ----------------------------------------------------------------------------

func _melee() -> void:
	_combo = _combo + 1 if _combo_t > 0.0 else 1
	_combo_t = Balance.COMBO_WINDOW
	_melee_cd = Balance.MELEE_COOLDOWN
	var dmg: float = Balance.MELEE_DAMAGE * Game.melee_mult()
	if _combo % Balance.COMBO_EVERY == 0:
		var seismic: bool = Game.has_mod("seismic")
		var r: float = Balance.SLAM_RADIUS * (Balance.SEISMIC_RADIUS if seismic else 1.0)
		var center: Vector3 = global_position + aim * 1.4
		var hits: int = level.hit_circle(center, r, dmg * Balance.SLAM_MULT, Balance.MELEE_KNOCKBACK * 1.4,
			Balance.SEISMIC_STUN if seismic else 0.0)
		_slam_t = 0.38
		_rig("slam", [])
		_melee_cd = Balance.MELEE_COOLDOWN * 1.6
		Sfx.play("slam", -3.0)
		Fx.shockwave(level.fx_root, center, Color(1.0, 0.8, 0.45), r)
		level.shake(0.5 if hits > 0 else 0.3)
	else:
		_slash_side = 1 - _slash_side
		_rig("slash", [_slash_side])
		var hits2: int = level.hit_arc(global_position, aim, Balance.MELEE_RANGE, Balance.MELEE_ARC, dmg,
			Balance.MELEE_KNOCKBACK)
		# The blade's sweep: arm 0 swings from its side (-x, the bot's right) across to the left.
		Fx.slash(level.fx_root, global_position, aim, Balance.MELEE_RANGE, Balance.MELEE_ARC,
			color.lerp(Color.WHITE, 0.35), 1.0 if _slash_side == 0 else -1.0)
		Sfx.play("slash", -7.0)
		if hits2 > 0:
			Sfx.play("hit", -6.0)
			level.shake(0.15)


func _fire_cannon() -> void:
	if energy < Balance.CANNON_ENERGY:
		return
	energy -= Balance.CANNON_ENERGY
	_regen_delay = Balance.ENERGY_REGEN_DELAY
	_cannon_cd = Balance.CANNON_COOLDOWN
	_rig("fire", [])
	var from: Vector3 = global_position + aim * 0.75 + Vector3(0.0, 1.35, 0.0)
	var dmg: float = Balance.CANNON_DAMAGE * Game.cannon_mult()
	var arcs: bool = Game.has_mod("arc")
	if Game.has_mod("splitter"):
		for k: int in [-1, 0, 1]:
			var d: Vector3 = aim.rotated(Vector3.UP, deg_to_rad(Balance.SPLITTER_SPREAD * float(k)))
			level.spawn_bolt(from, d, Balance.CANNON_SPEED, dmg * Balance.SPLITTER_MULT, Balance.CANNON_RANGE, true, self, arcs)
	else:
		level.spawn_bolt(from, aim, Balance.CANNON_SPEED, dmg, Balance.CANNON_RANGE, true, self, arcs)
	Sfx.play("zap", -9.0)


func use_kit() -> bool:
	if Game.kits <= 0 or hp >= max_hp or not alive:
		if Game.kits <= 0:
			Sfx.play("cant", -10.0)
		return false
	Game.kits -= 1
	heal(Balance.KIT_HEAL)
	Sfx.play("kit", -6.0)
	return true


func heal(amount: float) -> void:
	hp = minf(hp + amount, max_hp)
	Fx.sparks(level.fx_root, global_position + Vector3(0.0, 1.2, 0.0), Color(0.4, 1.0, 0.5), 10, 3.0)
	Fx.number(level.fx_root, global_position + Vector3(0.0, 2.3, 0.0), "+%d" % int(amount), Color(0.5, 1.0, 0.5))


## Returns true if the hit landed (not dodged by a dash or the post-hit grace period).
func take_damage(amount: float, from: Vector3) -> bool:
	if not alive or _dash_t > 0.0 or _iframes > 0.0:
		return false
	if shield > 0.0:
		var absorbed: float = minf(shield, amount)
		shield -= absorbed
		amount -= absorbed
	hp -= amount
	_iframes = Balance.HIT_IFRAMES
	Sfx.play("hurt", -6.0)
	level.shake(0.25)
	var push: Vector3 = global_position - from
	push.y = 0.0
	if push.length() > 0.01:
		push_back(push.normalized() * 4.0)
	_rig("hurt", [push.normalized() if push.length() > 0.01 else -aim])
	Fx.number(level.fx_root, global_position + Vector3(0.0, 2.3, 0.0), str(int(ceil(amount))), Color(1.0, 0.4, 0.35))
	if hp <= 0.0:
		_die()
	return true


func _die() -> void:
	hp = 0.0
	alive = false
	_down_t = 0.0
	_rig("knock_down", [])
	rig.visible = true
	Sfx.play("die", -4.0)
	Fx.explosion(level.fx_root, global_position + Vector3(0.0, 1.0, 0.0), color, 1.6)
	died.emit(self)


func revive(at: Vector3, hp_share: float = 0.5) -> void:
	alive = true
	hp = max_hp * hp_share
	energy = energy_max
	_iframes = 1.5
	global_position = at
	_net_pos = at
	tp_seq += 1
	velocity = Vector3.ZERO
	_rig("revive", [])
	Fx.shockwave(level.fx_root, at, Color(0.4, 0.9, 1.0), 1.5)
	Sfx.play("warp", -10.0)


func is_dashing() -> bool:
	return _dash_t > 0.0


func dash_ready() -> float:
	return 1.0 - _dash_cd / maxf(Game.dash_cooldown(), 0.01)


## Knockback. A client moves its own bot, so the host sends it the push instead.
func push_back(v: Vector3) -> void:
	velocity += v
	if net_mode == "remote":
		Net.ev_to(slot, "push", [v])


## Plays an animation cue on the model, and on everyone's screen when hosting online.
func _rig(cue: String, args: Array) -> void:
	rig.callv(cue, args)
	Net.ev("prig", [slot, cue, args])


# --- Online co-op -----------------------------------------------------------------------

## Host: a client's bot. It stands where the client put it and fights with its buttons.
func _remote_step(dt: float) -> void:
	if net_state.size() >= 8:
		var pos: Vector3 = net_state[0]
		if level.walkable(LevelMap.to_cell(pos)) or not level.walkable(LevelMap.to_cell(global_position)):
			global_position = Vector3(pos.x, 0.0, pos.z)
		velocity = net_state[1]
		var a: Vector3 = net_state[2]
		if a.length() > 0.01:
			aim = Vector3(a.x, 0.0, a.z).normalized()
		var dashing: bool = bool(net_state[3])
		if dashing and not _net_dashing:
			# The client already showed its own dash; everyone else sees it from here.
			Net.skip_slot = slot
			Sfx.play("dash", -8.0)
			Fx.afterimage(level.fx_root, global_position, color)
			_rig("dash", [])
			Net.skip_slot = -1
		_net_dashing = dashing
		_dash_t = Balance.DASH_TIME if dashing else 0.0
		if bool(net_state[4]) and _melee_cd <= 0.0:
			_melee()
		if bool(net_state[5]) and _cannon_cd <= 0.0:
			_fire_cannon()
		var kit_n: int = int(net_state[6])
		if kit_n > _net_kit_n:
			use_kit()
		_net_kit_n = kit_n
		var int_n: int = int(net_state[7])
		interact_pressed = int_n > _net_int_n
		_net_int_n = int_n
	rig.animate(dt, velocity, aim, energy / maxf(energy_max, 1.0))
	rig.visible = _iframes <= 0.0 or fmod(_iframes, 0.12) > 0.05 or _dash_t > 0.0


## Client: what our own bot sends the host every frame.
func net_input() -> Array:
	var buttons: Array = net_state if net_state.size() >= 2 else [false, false]
	return [global_position, velocity, aim, _dash_t > 0.0, bool(buttons[0]) and alive,
		bool(buttons[1]) and alive, _kit_presses, _int_presses]


## Host: this bot in a snapshot.
func net_entry() -> Array:
	var flags: int = (1 if alive else 0) | (2 if _dash_t > 0.0 else 0) | (4 if _iframes > 0.0 else 0)
	return [slot, global_position, velocity, aim, hp, max_hp, shield, energy, energy_max, flags,
		respawn_left, tp_seq]


## Client: takes the host's numbers for this bot. Our own bot keeps walking where we steer it,
## unless the host moved it (a new level, a reboot next to a teammate).
func net_apply(e: Array) -> void:
	hp = float(e[4])
	max_hp = float(e[5])
	shield = float(e[6])
	energy = float(e[7])
	energy_max = float(e[8])
	var flags: int = int(e[9])
	alive = (flags & 1) != 0
	_net_blink = (flags & 4) != 0
	respawn_left = float(e[10])
	var seq: int = int(e[11])
	_net_pos = e[1]
	_net_vel = e[2]
	if net_mode == "puppet":
		var a: Vector3 = e[3]
		if a.length() > 0.01:
			aim = a
		_dash_t = Balance.DASH_TIME if (flags & 2) != 0 else 0.0
		if seq != _net_tp_seen:
			global_position = _net_pos
	elif seq != _net_tp_seen and _net_tp_seen >= 0:
		global_position = _net_pos
		velocity = Vector3.ZERO
	_net_tp_seen = seq


## Client: someone else's bot, smoothed toward the host's latest position.
func _puppet_step(dt: float) -> void:
	_net_pos += _net_vel * dt
	global_position = global_position.lerp(_net_pos, 1.0 - exp(-14.0 * dt))
	if global_position.distance_to(_net_pos) > 4.0:
		global_position = _net_pos
	velocity = _net_vel
	if not alive:
		rig.animate_down(dt)
		return
	rig.animate(dt, velocity, aim, energy / maxf(energy_max, 1.0))
	rig.visible = not _net_blink or fmod(float(Time.get_ticks_msec()) * 0.001, 0.12) > 0.05 or _dash_t > 0.0
