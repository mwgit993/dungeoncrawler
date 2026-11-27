class_name Pickup
extends Node3D

## Scrap nuts (fly to the nearest bot and add to the shared scrap pool) and repair kits (go in
## the team's kit rack, or heal on the spot if the rack is full).

var level: LevelMap
var kind: String = "scrap"
var value: int = 1
var _vel: Vector3 = Vector3.ZERO
var _height: float = 0.6
var _vy: float = 0.0
var _t: float = 0.0
var _model: Node3D
var _attract: GorillaBot = null


func setup(lvl: LevelMap, k: String, v: int) -> void:
	level = lvl
	kind = k
	value = v
	_model = Node3D.new()
	add_child(_model)
	if kind == "kit":
		_height = 0.5
		Art.part(_model, Art.box(Vector3(0.6, 0.45, 0.6)), Art.mat(Color(0.85, 0.88, 0.9)), Vector3.ZERO)
		var red: StandardMaterial3D = Art.mat(Color(0.25, 0.95, 0.4), 1.6)
		Art.part(_model, Art.box(Vector3(0.42, 0.12, 0.62)), red, Vector3(0.0, 0.0, 0.0))
		Art.part(_model, Art.box(Vector3(0.12, 0.42, 0.62)), red, Vector3(0.0, 0.0, 0.0))
		Art.blob_shadow(self, 0.45)
	else:
		var big: bool = value >= 10
		var s: float = 1.35 if big else 1.0
		Art.part(_model, Art.cylinder(0.17 * s, 0.17 * s, 0.1 * s, 6), Art.mat(Color(1.0, 0.8, 0.3), 0.9), Vector3.ZERO, Vector3(90.0, 0, 0))
		Art.part(_model, Art.cylinder(0.07 * s, 0.07 * s, 0.12 * s, 6), Art.mat(Color(0.25, 0.2, 0.1)), Vector3.ZERO, Vector3(90.0, 0, 0))
	_t = randf() * TAU


## Throws the pickup outward with a little hop (used when scrap spills from a robot).
func pop(v: Vector3) -> void:
	_vel = v
	_vy = 5.0


func _process(delta: float) -> void:
	step(minf(delta, 0.05))


func step(dt: float) -> void:
	if is_queued_for_deletion():
		return
	_t += dt
	_model.rotation.y += dt * 3.0
	# Hop and slide to a stop.
	if _vy != 0.0 or _height > 0.45:
		_vy -= 18.0 * dt
		_height += _vy * dt
		if _height <= 0.45:
			_height = 0.45
			_vy = 0.0 if absf(_vy) < 2.0 else -_vy * 0.35
	var next: Vector3 = position + _vel * dt
	if level.walkable(LevelMap.to_cell(next)) or not level.walkable(LevelMap.to_cell(position)):
		position = next
	else:
		_vel = -_vel * 0.3
	_vel = _vel.move_toward(Vector3.ZERO, 8.0 * dt)
	_model.position.y = _height + sin(_t * 3.0) * 0.06
	var bot: GorillaBot = level.nearest_player(position)
	if bot == null:
		return
	var d: Vector3 = bot.global_position - position
	d.y = 0.0
	if kind == "kit":
		if d.length() < 1.0:
			_collect_kit(bot)
		return
	var pull: float = Balance.PICKUP_RADIUS * (Balance.MAGNET_MULT if Game.has_mod("magnet") else 1.0)
	if _attract == null and d.length() < pull and _vy == 0.0:
		_attract = bot
	if _attract != null and is_instance_valid(_attract) and _attract.alive:
		var to: Vector3 = _attract.global_position - position
		to.y = 0.0
		var spd: float = 6.0 + _t * 6.0
		position += to.normalized() * minf(spd * dt, to.length())
		if to.length() < 0.6:
			level.collect_scrap(value)
			Sfx.play("scrap", -14.0, 0.12)
			queue_free()


func _collect_kit(bot: GorillaBot) -> void:
	if Game.kits < Game.kit_max():
		Game.kits += 1
		Sfx.play("kit", -8.0)
		Fx.number(level.fx_root, bot.global_position + Vector3(0.0, 2.3, 0.0), "+KIT", Color(0.5, 1.0, 0.6))
	elif bot.hp < bot.max_hp:
		bot.heal(Balance.KIT_HEAL)
		Sfx.play("kit", -8.0)
	else:
		return
	queue_free()
