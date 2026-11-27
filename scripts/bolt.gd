class_name Bolt
extends Node3D

## A plasma bolt. Player bolts (friendly) hit robots and crates; enemy bolts hit players.
## Moves itself and checks hits by distance (no physics bodies), in short sub-steps so fast
## bolts can't skip through a target. Walls, pillars and consoles stop it; pits don't.

var level: LevelMap
var dir: Vector3 = Vector3.FORWARD
var speed: float = 20.0
var damage: float = 10.0
var friendly: bool = true
var arcs: bool = false
var source: Node3D = null
var _left: float = 15.0
var _hit_r: float = 0.3
var _trail: MeshInstance3D


func setup(lvl: LevelMap, d: Vector3, spd: float, dmg: float, max_range: float, is_friendly: bool,
		src: Node3D, chain: bool) -> void:
	level = lvl
	dir = Vector3(d.x, 0.0, d.z).normalized()
	speed = spd
	damage = dmg
	_left = max_range
	friendly = is_friendly
	source = src
	arcs = chain
	_hit_r = 0.3 if friendly else 0.32
	var core_col: Color = Color(1.0, 0.75, 0.3) if friendly else Color(1.0, 0.25, 0.35)
	Art.part(self, Art.ball(0.17 if friendly else 0.2, 6), Art.mat(core_col, 3.0), Vector3.ZERO)
	_trail = Art.part(self, Art.ball(0.11, 6), Art.mat(core_col.darkened(0.2), 1.6), -dir * 0.3)
	rotation.y = 0.0


func _process(delta: float) -> void:
	step(minf(delta, 0.05))


func step(dt: float) -> void:
	if is_queued_for_deletion():
		return
	var dist: float = speed * dt
	var steps: int = maxi(int(ceil(dist / 0.3)), 1)
	var inc: Vector3 = dir * (dist / float(steps))
	for i: int in range(steps):
		position += inc
		_left -= inc.length()
		if level.blocks_shot(position) or _left <= 0.0:
			_pop(false)
			return
		if friendly:
			if _check_enemies() or _check_props():
				return
		elif _check_players():
			return


func _check_enemies() -> bool:
	for e: RobotEnemy in level.enemies:
		if not e.alive:
			continue
		var d: Vector3 = e.global_position - position
		d.y = 0.0
		if d.length() <= e.radius + _hit_r:
			e.take_damage(damage, dir, 2.5)
			if arcs:
				var next: RobotEnemy = level.nearest_enemy(e.global_position, Balance.ARC_RANGE, e)
				if next != null:
					next.take_damage(damage * Balance.ARC_MULT, (next.global_position - e.global_position).normalized(), 1.0)
					Fx.zap(level.fx_root, e.global_position + Vector3(0.0, 1.0, 0.0), next.global_position + Vector3(0.0, 1.0, 0.0))
			_pop(true)
			return true
	return false


func _check_props() -> bool:
	for p: Prop in level.props:
		var d: Vector3 = p.global_position - position
		d.y = 0.0
		if absf(d.x) < 0.75 and absf(d.z) < 0.75:
			p.take_damage(damage)
			_pop(true)
			return true
	return false


func _check_players() -> bool:
	for p: GorillaBot in level.alive_players():
		var d: Vector3 = p.global_position - position
		d.y = 0.0
		if d.length() <= GorillaBot.RADIUS + _hit_r:
			if p.is_dashing():
				continue
			p.take_damage(damage, position - dir)
			_pop(true)
			return true
	return false


func _pop(hit: bool) -> void:
	var c: Color = Color(1.0, 0.8, 0.4) if friendly else Color(1.0, 0.35, 0.4)
	Fx.sparks(level.fx_root, position, c, 6 if hit else 4, 3.5)
	queue_free()
