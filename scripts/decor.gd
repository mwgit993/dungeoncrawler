class_name Decor
extends RefCounted

## Static scenery built from primitive shapes: pillars and rock spires, consoles, cargo.

static func pillar(parent: Node3D, pos: Vector3, tileset: String, rng: RandomNumberGenerator) -> void:
	var p: Dictionary = Art.palette(tileset)
	var root: Node3D = Node3D.new()
	root.position = pos
	root.rotation.y = float(rng.randi_range(0, 3)) * PI * 0.5
	parent.add_child(root)
	if tileset == "ash":
		# A cluster of jagged basalt spires with a glowing seam.
		var rock: StandardMaterial3D = Art.mat(p["wall"])
		var rock_hi: StandardMaterial3D = Art.mat(p["top"])
		Art.part(root, Art.cylinder(0.25, 0.65, 2.6, 5), rock, Vector3(0.0, 1.3, 0.0), Vector3(0, rng.randf() * 60.0, 3.0))
		Art.part(root, Art.cylinder(0.12, 0.42, 1.7, 5), rock_hi, Vector3(0.45, 0.85, 0.25), Vector3(-8.0, 20.0, -10.0))
		Art.part(root, Art.cylinder(0.08, 0.34, 1.2, 5), rock, Vector3(-0.4, 0.6, -0.3), Vector3(9.0, 0.0, 12.0))
		Art.part(root, Art.box(Vector3(0.08, 1.4, 0.08)), Art.mat(p["glow"], 2.2), Vector3(0.12, 0.9, 0.52), Vector3(0, 0, 4.0))
		return
	var metal: StandardMaterial3D = Art.mat(p["wall"])
	var trim: StandardMaterial3D = Art.mat(p["top"])
	Art.part(root, Art.box(Vector3(1.2, 0.3, 1.2)), trim, Vector3(0.0, 0.15, 0.0))
	Art.part(root, Art.cylinder(0.45, 0.45, 2.6, 8), metal, Vector3(0.0, 1.5, 0.0))
	Art.part(root, Art.box(Vector3(1.0, 0.25, 1.0)), trim, Vector3(0.0, 2.85, 0.0))
	var band_col: Color = p["glow"] if tileset == "ship" else p["accent"]
	Art.part(root, Art.cylinder(0.48, 0.48, 0.18, 8), Art.mat(band_col, 1.4 if tileset == "ship" else 0.0), Vector3(0.0, 1.9, 0.0))
	if tileset == "foundry":
		# A pipe running up one side.
		Art.part(root, Art.cylinder(0.12, 0.12, 2.6, 6), Art.mat(p["rust"]), Vector3(0.5, 1.4, 0.0))


static func console(parent: Node3D, pos: Vector3, tileset: String, rng: RandomNumberGenerator) -> void:
	var p: Dictionary = Art.palette(tileset)
	var root: Node3D = Node3D.new()
	root.position = pos
	root.rotation.y = float(rng.randi_range(0, 3)) * PI * 0.5
	parent.add_child(root)
	var body: StandardMaterial3D = Art.mat(p["wall"].lightened(0.1))
	var dark: StandardMaterial3D = Art.mat(p["dark"])
	if tileset == "ash":
		# Reactor coolant pump: squat drum with a hot core.
		Art.part(root, Art.cylinder(0.6, 0.7, 1.1, 8), body, Vector3(0.0, 0.55, 0.0))
		Art.part(root, Art.cylinder(0.35, 0.35, 0.3, 8), Art.mat(p["glow"], 2.5), Vector3(0.0, 1.2, 0.0))
		Art.part(root, Art.cylinder(0.14, 0.14, 1.4, 6), dark, Vector3(0.65, 0.7, 0.0), Vector3(0, 0, 90.0))
		return
	Art.part(root, Art.box(Vector3(1.3, 0.9, 0.8)), body, Vector3(0.0, 0.45, 0.0))
	Art.part(root, Art.box(Vector3(1.2, 0.6, 0.1)), dark, Vector3(0.0, 1.15, -0.2), Vector3(-25.0, 0, 0))
	var screen_col: Color = Color(0.3, 0.95, 0.6) if rng.randf() < 0.5 else p["glow"]
	Art.part(root, Art.box(Vector3(1.0, 0.45, 0.04)), Art.mat(screen_col, 1.8), Vector3(0.0, 1.16, -0.14), Vector3(-25.0, 0, 0))
	for i: int in range(3):
		var lc: Color = [Color(1, 0.25, 0.2), Color(1, 0.85, 0.2), Color(0.3, 1, 0.4)][i]
		Art.part(root, Art.box(Vector3(0.12, 0.08, 0.12)), Art.mat(lc, 2.0), Vector3(-0.35 + 0.35 * float(i), 0.93, 0.25))


static func cargo(parent: Node3D, pos: Vector3, rng: RandomNumberGenerator) -> void:
	var root: Node3D = Node3D.new()
	root.position = pos
	root.rotation.y = rng.randf_range(-0.2, 0.2)
	parent.add_child(root)
	var col: Color = [Color(0.32, 0.42, 0.3), Color(0.45, 0.3, 0.22), Color(0.3, 0.36, 0.48)][rng.randi_range(0, 2)]
	Art.part(root, Art.box(Vector3(1.5, 1.2, 1.5)), Art.mat(col), Vector3(0.0, 0.6, 0.0))
	Art.part(root, Art.box(Vector3(1.56, 0.14, 1.56)), Art.mat(col.darkened(0.35)), Vector3(0.0, 1.1, 0.0))
	Art.part(root, Art.box(Vector3(1.56, 0.14, 1.56)), Art.mat(col.darkened(0.35)), Vector3(0.0, 0.1, 0.0))
	if rng.randf() < 0.5:
		Art.part(root, Art.box(Vector3(1.0, 0.7, 1.0)), Art.mat(col.lightened(0.12)), Vector3(0.1, 1.55, -0.05), Vector3(0, 15.0, 0))
