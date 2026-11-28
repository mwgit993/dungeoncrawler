class_name Prop
extends StaticBody3D

## A breakable crate ("c") or scrap cache ("$") in a mission. Blocks movement until broken, then
## spills scrap and frees its tile for pathfinding.

var level: LevelMap
var kind: String = "crate"
var cell: Vector2i = Vector2i.ZERO
var net_id: int = 0
var hp: float = Balance.CRATE_HP
var _model: Node3D
var _parts: Array[MeshInstance3D] = []
var _mats: Array[Material] = []
var _flash: float = 0.0
var _wobble: float = 0.0


func setup(lvl: LevelMap, k: String, c: Vector2i, rng: RandomNumberGenerator) -> void:
	level = lvl
	kind = k
	cell = c
	hp = Balance.CRATE_HP * (2.0 if kind == "cache" else 1.0) * (1.0 + 0.25 * float(lvl.tier - 1))
	collision_layer = 1
	collision_mask = 0
	var cs: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3(1.3, 2.0, 1.3)
	cs.shape = shape
	cs.position = Vector3(0.0, 1.0, 0.0)
	add_child(cs)
	_model = Node3D.new()
	_model.rotation.y = rng.randf_range(-0.35, 0.35)
	add_child(_model)
	if kind == "cache":
		var gold: StandardMaterial3D = Art.mat(Color(0.95, 0.75, 0.25))
		_parts.append(Art.part(_model, Art.box(Vector3(1.1, 0.75, 0.8)), Art.mat(Color(0.25, 0.28, 0.34)), Vector3(0.0, 0.375, 0.0)))
		_parts.append(Art.part(_model, Art.box(Vector3(1.16, 0.12, 0.86)), gold, Vector3(0.0, 0.7, 0.0)))
		_parts.append(Art.part(_model, Art.box(Vector3(0.2, 0.2, 0.06)), Art.mat(Color(1.0, 0.85, 0.3), 2.0), Vector3(0.0, 0.45, 0.42)))
	else:
		var p: Dictionary = Art.palette(lvl.tileset)
		var wood: Color = Color(0.5, 0.36, 0.22) if lvl.tileset == "ash" else Color(0.42, 0.44, 0.32)
		_parts.append(Art.part(_model, Art.box(Vector3(1.1, 1.0, 1.1)), Art.mat(wood), Vector3(0.0, 0.5, 0.0)))
		_parts.append(Art.part(_model, Art.box(Vector3(1.16, 0.12, 1.16)), Art.mat(wood.darkened(0.4)), Vector3(0.0, 0.94, 0.0)))
		_parts.append(Art.part(_model, Art.box(Vector3(1.16, 0.12, 1.16)), Art.mat(wood.darkened(0.4)), Vector3(0.0, 0.06, 0.0)))
		_parts.append(Art.part(_model, Art.box(Vector3(0.14, 0.8, 1.14)), Art.mat(p["accent"].darkened(0.2)), Vector3(0.0, 0.5, 0.0)))
	for part: MeshInstance3D in _parts:
		_mats.append(part.material_override)
	Art.blob_shadow(self, 0.85)


func take_damage(amount: float) -> void:
	if hp <= 0.0:
		return
	hp -= amount
	flash_hit()
	Net.ev("prop_hit", [net_id])
	Sfx.play("clang" if kind == "cache" else "crate", -10.0)
	if hp <= 0.0:
		_break()


func _break() -> void:
	var c: Color = Color(0.95, 0.75, 0.25) if kind == "cache" else Color(0.5, 0.4, 0.25)
	Fx.debris(level.fx_root, global_position + Vector3(0.0, 0.6, 0.0), c, 10)
	level.on_prop_broken(self)
	queue_free()


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash -= delta
		if _flash <= 0.0:
			for i: int in range(_parts.size()):
				_parts[i].material_override = _mats[i]
	if _wobble > 0.0:
		_wobble = maxf(_wobble - delta * 5.0, 0.0)
		_model.rotation.z = sin(_wobble * 25.0) * 0.08 * _wobble


## The white flash and wobble of a hit (online clients play it when the host says so).
func flash_hit() -> void:
	_flash = 0.08
	_wobble = 1.0
	for part: MeshInstance3D in _parts:
		part.material_override = Art.mat(Color(1, 1, 1), 1.0)
