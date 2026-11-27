class_name Station
extends Node3D

## A hub station on the ship: the mission table, the quartermaster (vendor) and the two
## augmenters. Locked stations sit dark with a red LOCKED tag until their mission is cleared.

const TITLES: Dictionary = {
	"missions": "MISSION TABLE", "quartermaster": "QUARTERMASTER",
	"augments": "AUGMENT BAY", "lab": "WEAPONS LAB",
}
const INTERACT_RANGE: float = 2.8

var station_id: String = ""
var unlocked: bool = true
var _label: Label3D
var _lock_label: Label3D
var _glow_parts: Array[MeshInstance3D] = []
var _glow_mats: Array[Material] = []
var _spinner: Node3D = null
var _t: float = 0.0


func setup(id: String, tileset: String) -> void:
	station_id = id
	name = "Station_%s" % id
	var p: Dictionary = Art.palette(tileset)
	var metal: StandardMaterial3D = Art.mat(p["wall"].lightened(0.15))
	var dark: StandardMaterial3D = Art.mat(p["dark"])
	match id:
		"quartermaster":
			Art.part(self, Art.box(Vector3(1.7, 0.9, 0.7)), metal, Vector3(0.0, 0.45, 0.3))
			Art.part(self, Art.box(Vector3(1.8, 0.1, 0.8)), Art.mat(p["accent"]), Vector3(0.0, 0.95, 0.3))
			# The shopkeeper bot behind the counter.
			Art.part(self, Art.box(Vector3(0.75, 0.8, 0.5)), Art.mat(Color(0.55, 0.5, 0.4)), Vector3(0.0, 1.3, -0.35))
			Art.part(self, Art.box(Vector3(0.5, 0.4, 0.45)), Art.mat(Color(0.62, 0.57, 0.46)), Vector3(0.0, 1.92, -0.3))
			_glow(Art.part(self, Art.box(Vector3(0.36, 0.08, 0.04)), Art.mat(Color(0.3, 1.0, 0.45), 2.0), Vector3(0.0, 1.95, -0.06)))
			Art.part(self, Art.box(Vector3(0.18, 0.6, 0.18)), dark, Vector3(-0.5, 1.2, -0.1), Vector3(-40.0, 0, 0))
			Art.part(self, Art.box(Vector3(0.18, 0.6, 0.18)), dark, Vector3(0.5, 1.2, -0.1), Vector3(-40.0, 0, 0))
			# Wares on the counter.
			Art.part(self, Art.box(Vector3(0.3, 0.25, 0.3)), Art.mat(Color(0.3, 0.8, 0.4)), Vector3(-0.5, 1.12, 0.35))
			_glow(Art.part(self, Art.cylinder(0.1, 0.1, 0.35, 6), Art.mat(Color(0.3, 0.7, 1.0), 1.6), Vector3(0.45, 1.17, 0.35)))
		"augments":
			Art.part(self, Art.cylinder(0.95, 1.0, 0.2, 10), metal, Vector3(0.0, 0.1, 0.0))
			_glow(Art.part(self, Art.cylinder(0.7, 0.7, 0.22, 10), Art.mat(Color(0.75, 0.35, 1.0), 1.8), Vector3(0.0, 0.11, 0.0)))
			Art.part(self, Art.box(Vector3(0.25, 2.6, 0.25)), dark, Vector3(-0.85, 1.3, -0.3))
			Art.part(self, Art.box(Vector3(0.25, 2.6, 0.25)), dark, Vector3(0.85, 1.3, -0.3))
			Art.part(self, Art.box(Vector3(2.0, 0.3, 0.4)), metal, Vector3(0.0, 2.65, -0.3))
			for s: float in [-0.45, 0.45]:
				Art.part(self, Art.box(Vector3(0.12, 0.8, 0.12)), dark, Vector3(s, 2.15, -0.1), Vector3(25.0, 0, s * 30.0))
				_glow(Art.part(self, Art.box(Vector3(0.22, 0.12, 0.22)), Art.mat(Color(0.75, 0.35, 1.0), 1.6), Vector3(s * 0.8, 1.75, 0.05)))
		"lab":
			Art.part(self, Art.box(Vector3(1.8, 0.85, 0.9)), metal, Vector3(0.0, 0.425, 0.0))
			Art.part(self, Art.box(Vector3(1.9, 0.08, 1.0)), dark, Vector3(0.0, 0.88, 0.0))
			var tube_cols: Array[Color] = [Color(0.3, 1.0, 0.5), Color(0.3, 0.8, 1.0), Color(1.0, 0.35, 0.8)]
			for i: int in range(3):
				Art.part(self, Art.cylinder(0.17, 0.17, 0.08, 8), dark, Vector3(-0.55 + 0.55 * float(i), 0.96, -0.15))
				_glow(Art.part(self, Art.cylinder(0.13, 0.13, 0.7, 8), Art.mat(tube_cols[i], 1.8), Vector3(-0.55 + 0.55 * float(i), 1.35, -0.15)))
			Art.part(self, Art.box(Vector3(0.7, 0.5, 0.08)), dark, Vector3(0.45, 1.25, 0.3), Vector3(-15.0, 0, 0))
		"missions":
			Art.part(self, Art.cylinder(0.95, 0.7, 0.9, 10), metal, Vector3(0.0, 0.45, 0.0))
			_glow(Art.part(self, Art.cylinder(0.9, 0.9, 0.08, 10), Art.mat(p["glow"], 1.4), Vector3(0.0, 0.92, 0.0)))
			_spinner = Node3D.new()
			_spinner.position = Vector3(0.0, 1.75, 0.0)
			add_child(_spinner)
			var holo: StandardMaterial3D = Art.alpha_mat(Color(0.35, 0.9, 1.0, 0.55), true)
			_glow(Art.part(_spinner, Art.ball(0.45, 10), holo, Vector3.ZERO))
			var ring: TorusMesh = TorusMesh.new()
			ring.inner_radius = 0.62
			ring.outer_radius = 0.7
			ring.rings = 16
			ring.ring_segments = 3
			_glow(Art.part(_spinner, ring, Art.mat(p["glow"], 1.6), Vector3.ZERO, Vector3(20.0, 0, 0)))
	Art.blob_shadow(self, 1.0)
	for part: MeshInstance3D in _glow_parts:
		_glow_mats.append(part.material_override)
	_label = _make_label(String(TITLES.get(id, id.to_upper())), Color(1.0, 0.92, 0.55), 3.25)
	_lock_label = _make_label("LOCKED", Color(1.0, 0.35, 0.3), 2.85)
	_lock_label.visible = false


func _glow(mi: MeshInstance3D) -> MeshInstance3D:
	_glow_parts.append(mi)
	return mi


func _make_label(text: String, color: Color, y: float) -> Label3D:
	var l: Label3D = Label3D.new()
	l.text = text
	if Art.font != null:
		l.font = Art.font
	l.font_size = 8
	l.pixel_size = 0.05
	l.modulate = color
	l.outline_size = 3
	l.outline_modulate = Color(0, 0, 0, 0.9)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	l.position = Vector3(0.0, y, 0.0)
	add_child(l)
	return l


func title() -> String:
	return String(TITLES.get(station_id, station_id.to_upper()))


func set_unlocked(on: bool) -> void:
	unlocked = on
	_lock_label.visible = not on
	_label.modulate = Color(1.0, 0.92, 0.55) if on else Color(0.6, 0.6, 0.65)
	for i: int in range(_glow_parts.size()):
		_glow_parts[i].material_override = _glow_mats[i] if on else Art.mat(Color(0.18, 0.18, 0.22))


func _process(delta: float) -> void:
	_t += delta
	if _spinner != null and unlocked:
		_spinner.rotation.y += delta * 0.8
		_spinner.position.y = 1.75 + sin(_t * 2.0) * 0.06
