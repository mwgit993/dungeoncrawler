class_name RobotEnemy
extends CharacterBody3D

## Every enemy robot, one script for all kinds (stats in Balance.ENEMIES):
##   scuttler  small spider drone that rushes in and bites
##   gunner    biped that keeps its distance and fires 3-shot bursts
##   bruiser   heavy that winds up a ground slam (red ring = get out)
##   foreman   Foundry boss: slams, charges in a straight line (red lane), calls scuttlers
##   warden    Ashfall boss: slams, fires rings of bolts, calls gunners
## Enemies sleep where the map places them until a player comes within `aggro` range (or shoots
## them), and wake their neighbours when they do.

enum State { SLEEP, CHASE, WINDUP, RECOVER, CHARGE }

var level: LevelMap
var kind: String = "scuttler"
var stats: Dictionary = {}
var is_boss: bool = false
var minion: bool = false
var alive: bool = true
var awake: bool = false
var hp: float = 10.0
var max_hp: float = 10.0
var damage: float = 5.0
var speed: float = 3.0
var radius: float = 0.5
var display_name: String = ""
var phase: int = 1
var hit_recent: float = 99.0  # seconds since last damaged (HUD shows HP bars for a while)

var _target: GorillaBot = null
var _state: State = State.SLEEP
var _state_t: float = 0.0
var _action: String = ""
var _attack_cd: float = 0.0
var _special_t: float = 6.0
var _summon_t: float = 5.0
var _stun: float = 0.0
var _knock: Vector3 = Vector3.ZERO
var _path: PackedVector3Array = PackedVector3Array()
var _path_i: int = 0
var _repath_t: float = 0.0
var _sense_t: float = 0.0
var _strafe: float = 1.0
var _burst_left: int = 0
var _burst_t: float = 0.0
var _charge_dir: Vector3 = Vector3.ZERO
var _charge_hit: Array[GorillaBot] = []
var _slam_center: Vector3 = Vector3.ZERO
var _minions: Array[RobotEnemy] = []
var _facing: Vector3 = Vector3(0.0, 0.0, 1.0)
var _windup_time: float = 0.3
var _dt: float = 1.0 / 60.0

var rig: EnemyRig
var net_id: int = 0                  # matches on the host and its clients (see LevelMap)
var _net_pos: Vector3 = Vector3.ZERO
var _net_spd: float = 0.0
var _net_windup: float = 0.0
var _net_stun: bool = false
var _net_aux: Vector3 = Vector3.ZERO
var _telegraph: MeshInstance3D = null
var _tele_mat: StandardMaterial3D = null
var _hp_scale: float = 1.0


func setup(lvl: LevelMap, k: String) -> void:
	level = lvl
	kind = k
	stats = Balance.ENEMIES.get(kind, Balance.ENEMIES["scuttler"])
	is_boss = kind == "foreman" or kind == "warden"
	display_name = String(stats.get("name", kind.to_upper()))
	name = "%s_%d" % [kind, get_instance_id() % 100000]
	_hp_scale = Balance.hp_mult(lvl.tier, lvl.player_count)
	max_hp = float(stats["hp"]) * _hp_scale
	hp = max_hp
	damage = float(stats["damage"]) * Balance.damage_mult(lvl.tier, lvl.player_count)
	speed = float(stats["speed"])
	radius = float(stats["radius"])
	_attack_cd = randf_range(0.3, 1.0)
	_strafe = 1.0 if randf() < 0.5 else -1.0
	_special_t = 5.0
	_summon_t = float(stats.get("summon_every", 9.0)) * 0.6
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = 4
	collision_mask = 1
	var cs: CollisionShape3D = CollisionShape3D.new()
	var cap: CapsuleShape3D = CapsuleShape3D.new()
	cap.radius = minf(radius, 0.9)
	cap.height = maxf(cap.radius * 2.0, 1.2)
	cs.shape = cap
	cs.position = Vector3(0.0, cap.height * 0.5, 0.0)
	add_child(cs)
	rig = EnemyRig.new()
	rig.name = "Rig"
	add_child(rig)
	rig.setup(kind)
	Art.blob_shadow(self, radius * 1.15)


## Called when the number of players changes mid-mission: keeps the same share of HP left.
func rescale(old_players: int, new_players: int) -> void:
	var f: float = Balance.hp_mult(level.tier, new_players) / Balance.hp_mult(level.tier, old_players)
	max_hp *= f
	hp *= f
	damage = float(stats["damage"]) * Balance.damage_mult(level.tier, new_players)


# --- Update -----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if level.puppet:
		_puppet_step(minf(delta, 0.05))
		return
	step(minf(delta, 0.05))


func step(dt: float) -> void:
	if not alive:
		return
	_dt = dt
	hit_recent += dt
	_attack_cd = maxf(_attack_cd - dt, 0.0)
	_state_t += dt
	_knock = _knock * exp(-9.0 * dt)
	if _state == State.SLEEP:
		_sense_t -= dt
		if _sense_t <= 0.0:
			_sense_t = 0.25
			_look_for_players()
		_animate(dt, 0.0)
		return
	_target = level.nearest_player(global_position)
	if _stun > 0.0:
		_stun -= dt
		_clear_telegraph()
		_slide(_knock * dt)
		_animate(dt, 0.0)
		return
	if is_boss:
		_summon_t -= dt
		_special_t -= dt
	var desired: Vector3 = Vector3.ZERO
	match _state:
		State.CHASE:
			desired = _think(dt)
		State.WINDUP:
			_update_windup(dt)
		State.RECOVER:
			if _state_t >= _recover_time():
				_state = State.CHASE
				_state_t = 0.0
		State.CHARGE:
			_update_charge(dt)
	if _state != State.CHARGE:
		var sep: Vector3 = _separation()
		velocity = velocity.move_toward(desired + sep, 30.0 * dt)
		_slide((velocity + _knock) * dt)
	_animate(dt, velocity.length())


func _look_for_players() -> void:
	var aggro: float = float(stats.get("aggro", 10.0))
	for p: GorillaBot in level.alive_players():
		var d: float = p.global_position.distance_to(global_position)
		if d <= aggro and (d < 4.0 or level.line_clear(global_position + Vector3.UP, p.global_position + Vector3.UP)):
			wake()
			return


func wake() -> void:
	if awake or not alive:
		return
	awake = true
	_state = State.CHASE
	_state_t = 0.0
	rig.woke()
	Net.ev("erig", [net_id, "woke", []])
	if is_boss:
		level.boss_woke.emit(self)
		Sfx.play("alarm", -6.0)
	# Wake the pack.
	for e: RobotEnemy in level.enemies:
		if not e.awake and e.global_position.distance_to(global_position) < 7.0:
			e.wake()


func _recover_time() -> float:
	match _action:
		"slam":
			return 0.7
		"charge":
			return 0.9
		"nova":
			return 0.5
	return 0.35


## Chooses what to do this step while chasing; returns the velocity we want.
func _think(_dt: float) -> Vector3:
	if _target == null:
		return Vector3.ZERO
	var to: Vector3 = _target.global_position - global_position
	to.y = 0.0
	var dist: float = to.length()
	var reach: float = float(stats["range"]) + radius
	_face(to)
	if is_boss and _summon_t <= 0.0:
		_summon_t = float(stats.get("summon_every", 9.0)) * (0.7 if phase == 2 else 1.0)
		_summon()
	match kind:
		"gunner":
			var sees: bool = level.line_clear(global_position + Vector3.UP, _target.global_position + Vector3.UP)
			if sees and dist <= float(stats["range"]) and _attack_cd <= 0.0:
				_begin("burst", 0.4)
				return Vector3.ZERO
			if not sees or dist > float(stats["range"]) * 0.85:
				return _seek(_target.global_position) * speed
			if dist < float(stats.get("keep_away", 7.0)):
				var away: Vector3 = -to.normalized()
				if level.walkable(LevelMap.to_cell(global_position + away * 1.2)):
					return away * speed
			return to.normalized().cross(Vector3.UP) * _strafe * speed * 0.5
		"bruiser":
			if dist <= reach + 0.4 and _attack_cd <= 0.0:
				_begin("slam", float(stats["windup"]))
				return Vector3.ZERO
		"foreman":
			if _special_t <= 0.0 and dist > 3.0 and dist < 16.0 and level.line_clear(global_position, _target.global_position, true):
				_special_t = 6.5 if phase == 1 else 4.5
				_begin("charge", float(stats["windup"]))
				return Vector3.ZERO
			if dist <= reach + 0.4 and _attack_cd <= 0.0:
				_begin("slam", float(stats["windup"]))
				return Vector3.ZERO
		"warden":
			if _special_t <= 0.0:
				_special_t = 5.0 if phase == 1 else 3.5
				_begin("nova", 0.7)
				return Vector3.ZERO
			if dist <= reach + 0.4 and _attack_cd <= 0.0:
				_begin("slam", float(stats["windup"]))
				return Vector3.ZERO
		_:
			if dist <= reach + 0.3 and _attack_cd <= 0.0:
				_begin("bite", 0.22)
				return Vector3.ZERO
	if dist <= reach * 0.8:
		return Vector3.ZERO
	return _seek(_target.global_position) * speed * (1.15 if phase == 2 else 1.0)


## Unit direction toward dest: straight if the way is clear, otherwise along an A* path.
func _seek(dest: Vector3) -> Vector3:
	if level.line_clear(global_position, dest, true):
		_path = PackedVector3Array()
		var d: Vector3 = dest - global_position
		d.y = 0.0
		return d.normalized() if d.length() > 0.05 else Vector3.ZERO
	_repath_t -= _dt
	if _path.is_empty() or _repath_t <= 0.0:
		_path = level.find_path(global_position, dest)
		_path_i = 0
		_repath_t = randf_range(0.4, 0.7)
	while _path_i < _path.size() and global_position.distance_to(_path[_path_i]) < 0.7:
		_path_i += 1
	if _path_i >= _path.size():
		return Vector3.ZERO
	var v: Vector3 = _path[_path_i] - global_position
	v.y = 0.0
	return v.normalized()


func _separation() -> Vector3:
	var push: Vector3 = Vector3.ZERO
	for e: RobotEnemy in level.enemies:
		if e == self or not e.alive:
			continue
		var d: Vector3 = global_position - e.global_position
		d.y = 0.0
		var min_d: float = radius + e.radius
		var l: float = d.length()
		if l < min_d and l > 0.001:
			push += d / l * (min_d - l) * 6.0
	for p: GorillaBot in level.alive_players():
		var d2: Vector3 = global_position - p.global_position
		d2.y = 0.0
		var l2: float = d2.length()
		var min_d2: float = radius + GorillaBot.RADIUS
		if l2 < min_d2 and l2 > 0.001:
			push += d2 / l2 * (min_d2 - l2) * 8.0
	return push


func _face(dir: Vector3) -> void:
	if dir.length() > 0.05:
		_facing = dir.normalized()


func _begin(action: String, windup: float) -> void:
	_action = action
	_state = State.WINDUP
	_state_t = 0.0
	velocity = Vector3.ZERO
	match action:
		"slam":
			_slam_center = global_position + _facing * (radius + 0.6)
			_show_ring(_slam_center, float(stats["slam_radius"]), windup)
			Sfx.play("warn", -12.0)
		"charge":
			_charge_dir = _facing
			_show_lane(global_position, _charge_dir, float(stats["charge_speed"]) * 1.1, radius * 2.0)
			Sfx.play("warn", -8.0)
		"nova":
			_show_ring(global_position, 2.5, windup)
	_windup_time = windup
	if action == "burst":
		_burst_left = int(stats.get("burst", 3))
		_burst_t = 0.0


func _update_windup(dt: float) -> void:
	if _target != null and (_action == "bite" or _action == "burst"):
		var to: Vector3 = _target.global_position - global_position
		to.y = 0.0
		_face(to)
	if _tele_mat != null:
		var k: float = clampf(_state_t / _windup_time, 0.0, 1.0)
		_tele_mat.albedo_color.a = 0.15 + 0.35 * k + 0.1 * sin(_state_t * 30.0)
		if _action == "slam" or _action == "nova":
			var r: float = float(stats.get("slam_radius", 2.5)) if _action == "slam" else 2.5
			_telegraph.scale = Vector3(r * k, 1.0, r * k)
	if _action == "burst" and _state_t >= _windup_time:
		_burst_t -= dt
		if _burst_t <= 0.0 and _burst_left > 0:
			_shoot_at_target()
			_burst_left -= 1
			_burst_t = float(stats.get("burst_gap", 0.18))
		if _burst_left <= 0:
			_finish(float(stats["cooldown"]))
		return
	if _state_t < _windup_time:
		return
	match _action:
		"bite":
			if _target != null and _target.global_position.distance_to(global_position) <= float(stats["range"]) + radius + 0.6:
				_target.take_damage(damage, global_position)
			velocity = _facing * speed * 2.0
			_finish(float(stats["cooldown"]))
		"slam":
			var hit: int = level.hurt_players(_slam_center, float(stats["slam_radius"]), damage)
			Fx.shockwave(level.fx_root, _slam_center, Color(1.0, 0.45, 0.3), float(stats["slam_radius"]))
			Sfx.play("slam", -4.0)
			level.shake(0.45 if hit > 0 else 0.25)
			_finish(float(stats["cooldown"]))
		"charge":
			_clear_telegraph()
			_state = State.CHARGE
			_state_t = 0.0
			level.count("charges")
			_charge_hit = []
			Sfx.play("dash", -4.0, 0.0)
		"nova":
			var n: int = int(stats.get("nova", 12))
			var rings: int = 2 if phase == 2 else 1
			for ring: int in range(rings):
				var off: float = (PI / float(n)) * float(ring)
				for i: int in range(n):
					var a: float = TAU * float(i) / float(n) + off
					var d: Vector3 = Vector3(cos(a), 0.0, sin(a))
					level.spawn_bolt(global_position + d * radius + Vector3(0.0, 1.4, 0.0), d,
						float(stats.get("shot_speed", 9.0)) * (1.0 - 0.18 * float(ring)), damage * 0.6, 22.0, false, self)
			Sfx.play("eshot", -4.0)
			_finish(float(stats["cooldown"]))


func _shoot_at_target() -> void:
	if _target == null:
		return
	var muzzle: Vector3 = global_position + _facing * (radius + 0.45) + Vector3(0.0, 1.15, 0.0)
	var d: Vector3 = _target.global_position + Vector3(0.0, 1.0, 0.0) - muzzle
	d.y = 0.0
	level.spawn_bolt(muzzle, d.normalized(), float(stats.get("shot_speed", 10.0)), damage, float(stats["range"]) + 4.0, false, self)
	rig.shot()
	Net.ev("erig", [net_id, "shot", []])
	Sfx.play("eshot", -12.0)


func _finish(cooldown: float) -> void:
	_attack_cd = cooldown * (0.8 if phase == 2 else 1.0)
	_state = State.RECOVER
	_state_t = 0.0
	_clear_telegraph()


func _update_charge(dt: float) -> void:
	var spd: float = float(stats.get("charge_speed", 14.0))
	velocity = _charge_dir * spd
	var before: Vector3 = global_position
	_slide(velocity * dt)
	for p: GorillaBot in level.alive_players():
		if p in _charge_hit:
			continue
		if p.global_position.distance_to(global_position) <= radius + GorillaBot.RADIUS + 0.3:
			if p.take_damage(damage * 1.2, global_position - _charge_dir):
				p.push_back(_charge_dir * 10.0)
			_charge_hit.append(p)
	var moved: float = before.distance_to(global_position)
	if _state_t > 1.1 or moved < spd * dt * 0.3:
		if moved < spd * dt * 0.3:
			level.shake(0.5)
			Sfx.play("clang", -4.0)
			_stun = 0.6
		velocity = Vector3.ZERO
		_action = "charge"
		_finish(float(stats["cooldown"]))


func _summon() -> void:
	_prune_minions()
	var cap: int = int(stats.get("max_minions", 4))
	var kind_s: String = String(stats.get("summon", "scuttler"))
	var want: int = mini(2, cap - _minions.size())
	for i: int in range(want):
		var a: float = randf() * TAU
		var pos: Vector3 = global_position + Vector3(cos(a), 0.0, sin(a)) * (radius + 1.4)
		if not level.walkable(LevelMap.to_cell(pos)):
			pos = global_position + _facing * (radius + 1.2)
			if not level.walkable(LevelMap.to_cell(pos)):
				continue
		var m: RobotEnemy = level.spawn_enemy(kind_s, pos, true)
		m.minion = true
		_minions.append(m)
		Fx.shockwave(level.fx_root, pos, Color(1.0, 0.3, 0.2), 1.0)
	if want > 0:
		Sfx.play("warp", -12.0)


func minion_count() -> int:
	_prune_minions()
	return _minions.size()


func _prune_minions() -> void:
	var keep: Array[RobotEnemy] = []
	for m: RobotEnemy in _minions:
		if is_instance_valid(m) and m.alive:
			keep.append(m)
	_minions = keep


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


# --- Damage -----------------------------------------------------------------------------

func take_damage(amount: float, dir: Vector3, knockback: float, stun: float = 0.0) -> void:
	if not alive:
		return
	hp -= amount
	hit_recent = 0.0
	if not awake:
		wake()
	var heft: float = float(stats.get("heft", 0.0))
	_knock += Vector3(dir.x, 0.0, dir.z) * knockback * (1.0 - heft)
	if stun > 0.0 and not is_boss:
		_stun = maxf(_stun, stun)
	elif stun > 0.0:
		_stun = maxf(_stun, stun * 0.25)
	if is_boss and phase == 1 and hp < max_hp * 0.5:
		phase = 2
		Sfx.play("alarm", -8.0)
	rig.hurt(dir, heft >= 0.8)
	Net.ev("erig", [net_id, "hurt", [dir, heft >= 0.8]])
	Fx.sparks(level.fx_root, global_position + Vector3(0.0, 0.9, 0.0) - dir * radius * 0.5, Color(1.0, 0.8, 0.4), 5, 4.0)
	Fx.number(level.fx_root, global_position + Vector3(0.0, 1.6 + radius, 0.0), str(int(round(amount))), Color(1.0, 0.95, 0.6))
	if hp <= 0.0:
		_die()


func _die() -> void:
	alive = false
	hp = 0.0
	_clear_telegraph()
	collision_layer = 0
	var size: float = radius * (2.4 if is_boss else 1.6)
	Fx.explosion(level.fx_root, global_position + Vector3(0.0, 0.8, 0.0), rig.glow_color, size)
	Fx.debris(level.fx_root, global_position + Vector3(0.0, 0.8, 0.0), Color(0.4, 0.4, 0.42), 8 if not is_boss else 24)
	Sfx.play("boom" if radius > 0.8 else "die", -4.0 if is_boss else -8.0)
	level.shake(1.0 if is_boss else 0.2)
	level.on_enemy_dead(self)
	queue_free()


# --- Telegraphs and animation -----------------------------------------------------------

func _show_ring(center: Vector3, r: float, _time: float) -> void:
	_clear_telegraph()
	_tele_mat = Art.alpha_mat(Color(1.0, 0.15, 0.1, 0.2), true)
	_telegraph = MeshInstance3D.new()
	_telegraph.mesh = Art.cylinder(1.0, 1.0, 0.03, 20)
	_telegraph.material_override = _tele_mat
	_telegraph.position = center + Vector3(0.0, 0.05, 0.0)
	_telegraph.scale = Vector3(0.1, 1.0, 0.1)
	level.fx_root.add_child(_telegraph)
	if r <= 0.0:
		_telegraph.visible = false


func _show_lane(from: Vector3, dir: Vector3, length: float, width: float) -> void:
	_clear_telegraph()
	_tele_mat = Art.alpha_mat(Color(1.0, 0.15, 0.1, 0.2), true)
	_telegraph = MeshInstance3D.new()
	_telegraph.mesh = Art.box(Vector3(1.0, 0.03, 1.0))
	_telegraph.material_override = _tele_mat
	_telegraph.position = from + dir * (length * 0.5) + Vector3(0.0, 0.05, 0.0)
	_telegraph.rotation.y = atan2(dir.x, dir.z)
	_telegraph.scale = Vector3(width, 1.0, length)
	level.fx_root.add_child(_telegraph)


func _clear_telegraph() -> void:
	if _telegraph != null and is_instance_valid(_telegraph):
		_telegraph.queue_free()
	_telegraph = null
	_tele_mat = null


func has_telegraph() -> bool:
	return _telegraph != null


func _animate(dt: float, spd: float) -> void:
	var yaw: float = atan2(_facing.x, _facing.z)
	rotation.y = lerp_angle(rotation.y, yaw, minf(dt * (6.0 if is_boss else 12.0), 1.0))
	var windup: float = 0.0
	if _state == State.WINDUP:
		windup = clampf(_state_t / maxf(_windup_time, 0.01), 0.0, 1.0)
	rig.animate(dt, spd / maxf(speed, 0.1), _state, windup, _action, phase, _stun > 0.0)


# --- Online co-op -----------------------------------------------------------------------

## Host: this robot in a snapshot. `aux` places a wind-up's telegraph: the slam's centre, or the
## charge's direction.
func net_entry() -> Array:
	var windup: float = 0.0
	if _state == State.WINDUP:
		windup = clampf(_state_t / maxf(_windup_time, 0.01), 0.0, 1.0)
	var aux: Vector3 = _slam_center if _action == "slam" else (_charge_dir if _action == "charge" else Vector3.ZERO)
	var flags: int = (1 if awake else 0) | (2 if _stun > 0.0 else 0) | (4 if minion else 0)
	return [net_id, kind, global_position, _facing, velocity.length(), int(_state), windup, _action,
		phase, flags, hp, max_hp, hit_recent, aux]


## Client: takes the host's state for this robot, and shows or clears its telegraph.
func net_apply(e: Array) -> void:
	_net_pos = e[2]
	var f: Vector3 = e[3]
	if f.length() > 0.01:
		_facing = f
	_net_spd = float(e[4])
	var st: int = int(e[5])
	_net_windup = float(e[6])
	var act: String = String(e[7])
	phase = int(e[8])
	var flags: int = int(e[9])
	awake = (flags & 1) != 0
	_net_stun = (flags & 2) != 0
	minion = (flags & 4) != 0
	hp = float(e[10])
	max_hp = float(e[11])
	hit_recent = float(e[12])
	_net_aux = e[13]
	var winding: bool = st == State.WINDUP and act in ["slam", "charge", "nova"]
	if winding and (_telegraph == null or act != _action or _state != State.WINDUP):
		match act:
			"slam":
				_show_ring(_net_aux, float(stats.get("slam_radius", 2.5)), 0.0)
			"charge":
				_show_lane(_net_pos, _net_aux, float(stats.get("charge_speed", 14.0)) * 1.1, radius * 2.0)
			"nova":
				_show_ring(_net_pos, 2.5, 0.0)
	elif not winding and _telegraph != null:
		_clear_telegraph()
	_state = st as State
	_action = act


## Client: smoothed toward the host's position, animated from its state.
func _puppet_step(dt: float) -> void:
	if not alive:
		return
	hit_recent += dt
	global_position = global_position.lerp(_net_pos, 1.0 - exp(-14.0 * dt))
	if global_position.distance_to(_net_pos) > 5.0:
		global_position = _net_pos
	if _tele_mat != null:
		_tele_mat.albedo_color.a = 0.15 + 0.35 * _net_windup + 0.1 * sin(float(Time.get_ticks_msec()) * 0.03)
		if _action == "slam" or _action == "nova":
			var r: float = float(stats.get("slam_radius", 2.5)) if _action == "slam" else 2.5
			_telegraph.scale = Vector3(r * _net_windup, 1.0, r * _net_windup)
	var yaw: float = atan2(_facing.x, _facing.z)
	rotation.y = lerp_angle(rotation.y, yaw, minf(dt * (6.0 if is_boss else 12.0), 1.0))
	rig.animate(dt, _net_spd / maxf(speed, 0.1), _state, _net_windup, _action, phase, _net_stun)


## Client: the host says this robot is gone (its explosion arrives as an effect).
func net_remove() -> void:
	alive = false
	_clear_telegraph()
	queue_free()
