class_name LevelMap
extends Node3D

## One playable map, built from a Maps entry: floor, walls, props, lights, spawn points and the
## pathfinding grid. It is also the world the entities live in, so it owns the shared combat
## helpers (hit_arc, spawn_bolt, spawn_scrap ...) and the lists of everything alive.

signal enemy_died(enemy: RobotEnemy)
signal boss_died(enemy: RobotEnemy)
signal boss_woke(enemy: RobotEnemy)
signal scrap_collected(amount: int)
signal shake_requested(amount: float)

const WALLS: String = "#w"
const SOLID_PROPS: String = "otc$"
const ENEMY_CHARS: Dictionary = {"s": "scuttler", "g": "gunner", "b": "bruiser"}
const STATION_CHARS: Dictionary = {"Q": "quartermaster", "A": "augments", "L": "lab", "M": "missions"}

var def: Dictionary = {}
var id: String = ""
var tileset: String = "foundry"
var rows: PackedStringArray = PackedStringArray()
var w: int = 0
var h: int = 0
var is_hub: bool = false
var tier: int = 1
var player_count: int = 1

var start_pos: Vector3 = Vector3.ZERO
var exit_pos: Vector3 = Vector3.ZERO
var has_exit: bool = false
var exit_active: bool = false
var stations: Array[Station] = []
var enemies: Array[RobotEnemy] = []
var props: Array[Prop] = []
var players: Array[GorillaBot] = []
var boss: RobotEnemy = null
var counters: Dictionary = {}  # event tallies (shots, slams, charges) for the smoke test

var astar: AStarGrid2D = AStarGrid2D.new()
var _shot_block: PackedByteArray = PackedByteArray()
var _wall_mats: Array[ShaderMaterial] = []
var _exit_node: Node3D = null
var _exit_ring: MeshInstance3D = null
var _exit_beam: MeshInstance3D = null

var actors: Node3D
var bolts: Node3D
var pickups: Node3D
var fx_root: Node3D


func build(map_def: Dictionary, mission_tier: int, players_in: int) -> void:
	def = map_def
	id = String(def["id"])
	tileset = String(def["tileset"])
	is_hub = id == "hub"
	tier = mission_tier
	player_count = maxi(players_in, 1)
	var r: Array = def["rows"]
	for line: Variant in r:
		rows.append(String(line))
	h = rows.size()
	w = rows[0].length()
	name = "Level_%s" % id
	actors = _child("Actors")
	bolts = _child("Bolts")
	pickups = _child("Pickups")
	fx_root = _child("Fx")
	_build_environment()
	_build_floor()
	_build_walls()
	_build_grid()
	_place_things()
	_build_lights()


func _child(n: String) -> Node3D:
	var c: Node3D = Node3D.new()
	c.name = n
	add_child(c)
	return c


# --- Grid helpers -----------------------------------------------------------------------

func ch(x: int, z: int) -> String:
	if x < 0 or z < 0 or x >= w or z >= h:
		return "#"
	return rows[z][x]


func is_wall_char(c: String) -> bool:
	return WALLS.contains(c)


static func cell_center(x: int, z: int) -> Vector3:
	return Vector3((float(x) + 0.5) * Balance.TILE, 0.0, (float(z) + 0.5) * Balance.TILE)


static func to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / Balance.TILE), floori(p.z / Balance.TILE))


## Can something walk on this cell? (walls, pits, pillars, consoles and unbroken crates block).
func walkable(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
		return false
	return not astar.is_point_solid(c)


## Do walls, pillars or consoles stop a shot at this point? Pits and crates don't (crates are
## hit as props).
func blocks_shot(p: Vector3) -> bool:
	var c: Vector2i = to_cell(p)
	if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
		return true
	return _shot_block[c.y * w + c.x] == 1


## True when a straight line between two points crosses no wall/pillar (sampled every 0.4 m).
func line_clear(a: Vector3, b: Vector3, walk: bool = false) -> bool:
	var d: Vector3 = b - a
	d.y = 0.0
	var steps: int = maxi(int(d.length() / 0.4), 1)
	for i: int in range(1, steps):
		var p: Vector3 = a + d * (float(i) / float(steps))
		if walk:
			if not walkable(to_cell(p)):
				return false
		elif blocks_shot(p):
			return false
	return true


## Waypoints from a to b around obstacles (empty if there is no way).
func find_path(a: Vector3, b: Vector3) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	var ca: Vector2i = to_cell(a)
	var cb: Vector2i = to_cell(b)
	if not astar.is_in_boundsv(ca) or not astar.is_in_boundsv(cb):
		return out
	if astar.is_point_solid(cb):
		return out
	var was_solid: bool = astar.is_point_solid(ca)
	if was_solid:
		astar.set_point_solid(ca, false)
	var ids: Array[Vector2i] = astar.get_id_path(ca, cb)
	if was_solid:
		astar.set_point_solid(ca, true)
	for i: int in range(1, ids.size()):
		out.append(cell_center(ids[i].x, ids[i].y))
	return out


# --- Building ---------------------------------------------------------------------------

func _build_environment() -> void:
	var p: Dictionary = Art.palette(tileset)
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = p["sky"]
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = p["ambient"]
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 0.9
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.light_energy = 0.95
	sun.light_color = Color(1.0, 0.97, 0.92) if tileset != "ash" else Color(1.0, 0.85, 0.75)
	sun.shadow_enabled = false
	add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, Vector3(-0.55, -1.0, -0.22), Vector3.UP)


func _build_floor() -> void:
	var t: Dictionary = Art.tiles(tileset)
	var px: int = Art.TILE_PX
	var p: Dictionary = Art.palette(tileset)
	var img: Image = Image.create(w * px, h * px, false, Image.FORMAT_RGBA8)
	img.fill(p["sky"])
	var glow: Image = Image.create(w * px, h * px, false, Image.FORMAT_RGBA8)
	glow.fill(Color(0, 0, 0, 1))
	var src_rect: Rect2i = Rect2i(0, 0, px, px)
	var bands: Array[Image] = _ao_bands(px)
	var lips: Array[Image] = _ao_bands(px, 0.25, 2)
	for z: int in range(h):
		for x: int in range(w):
			var c: String = ch(x, z)
			if is_wall_char(c):
				continue
			var key: String = "floor0"
			var hsh: int = absi(x * 73856093 ^ z * 19349663) % 100
			if c == ",":
				key = "detail"
			elif c == "=":
				key = "stripe"
			elif c == "~":
				key = "pit"
			elif hsh < 22:
				key = "floor1"
			elif hsh < 34:
				key = "floor2"
			var at: Vector2i = Vector2i(x * px, z * px)
			img.blit_rect(t[key], src_rect, at)
			if key == "pit" or key == "stripe":
				glow.blit_rect(t[key + "_glow"], src_rect, at)
			# Baked shading: floor darkens along walls; pits get a dark lip.
			var dirs: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
			for d: int in range(4):
				var n: String = ch(x + dirs[d].x, z + dirs[d].y)
				if is_wall_char(n):
					img.blend_rect(bands[d], Rect2i(0, 0, bands[d].get_width(), bands[d].get_height()),
						at + _band_offset(d, px, bands[d]))
				elif n == "~" and c != "~":
					img.blend_rect(lips[d], Rect2i(0, 0, lips[d].get_width(), lips[d].get_height()),
						at + _band_offset(d, px, lips[d]))
	var mi: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(float(w) * Balance.TILE, float(h) * Balance.TILE)
	mi.mesh = plane
	mi.position = Vector3(float(w) * Balance.TILE * 0.5, 0.0, float(h) * Balance.TILE * 0.5)
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = Art.floor_shader
	m.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(img))
	m.set_shader_parameter("glow_tex", ImageTexture.create_from_image(glow))
	m.set_shader_parameter("map_size", plane.size)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Floor"
	add_child(mi)


# Four gradient strips (top, bottom, left, right edge of a tile) for baked edge shading.
func _ao_bands(px: int, strength: float = 0.5, depth: int = 4) -> Array[Image]:
	var out: Array[Image] = []
	for d: int in range(4):
		var horiz: bool = d < 2
		var im: Image = Image.create(px if horiz else depth, depth if horiz else px, false, Image.FORMAT_RGBA8)
		for i: int in range(depth):
			var k: float = 1.0 - float(i) / float(depth)
			var a: float = strength * k * k
			var row: int = i if d == 0 or d == 2 else depth - 1 - i
			for j: int in range(px):
				if horiz:
					im.set_pixel(j, row, Color(0, 0, 0, a))
				else:
					im.set_pixel(row, j, Color(0, 0, 0, a))
		out.append(im)
	return out


func _band_offset(d: int, px: int, band: Image) -> Vector2i:
	if d == 1:
		return Vector2i(0, px - band.get_height())
	if d == 3:
		return Vector2i(px - band.get_width(), 0)
	return Vector2i.ZERO


func _build_walls() -> void:
	var plain: Array[Transform3D] = []
	var windows: Array[Transform3D] = []
	var body: StaticBody3D = StaticBody3D.new()
	body.name = "WallBody"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	for z: int in range(h):
		var run_start: int = -1
		var run_pit: bool = false
		for x: int in range(w + 1):
			var c: String = ch(x, z) if x < w else "."
			var visible: bool = x < w and is_wall_char(c) and _touches_open(x, z)
			if visible:
				var tf: Transform3D = Transform3D(Basis.IDENTITY, cell_center(x, z) + Vector3(0.0, Balance.WALL_H * 0.5, 0.0))
				if c == "w":
					windows.append(tf)
				else:
					plain.append(tf)
			# Collision: merge each row's solid cells (walls and pits) into long boxes.
			var solid: bool = x < w and (visible or c == "~")
			var pit: bool = c == "~"
			if solid and run_start >= 0 and pit != run_pit:
				_add_run(body, run_start, x - 1, z)
				run_start = -1
			if solid and run_start < 0:
				run_start = x
				run_pit = pit
			elif not solid and run_start >= 0:
				_add_run(body, run_start, x - 1, z)
				run_start = -1
	var box: BoxMesh = Art.box(Vector3(Balance.TILE, Balance.WALL_H, Balance.TILE))
	for pair: Array in [[plain, false], [windows, true]]:
		var list: Array[Transform3D] = pair[0]
		if list.is_empty():
			continue
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = box
		mm.instance_count = list.size()
		for i: int in range(list.size()):
			mm.set_instance_transform(i, list[i])
		var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var mat: ShaderMaterial = Art.wall_material(tileset, bool(pair[1]))
		_wall_mats.append(mat)
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.name = "Windows" if bool(pair[1]) else "Walls"
		add_child(mmi)


func _add_run(body: StaticBody3D, x0: int, x1: int, z: int) -> void:
	var cs: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	var n: int = x1 - x0 + 1
	shape.size = Vector3(float(n) * Balance.TILE, 3.0, Balance.TILE)
	cs.shape = shape
	cs.position = Vector3((float(x0) + float(n) * 0.5) * Balance.TILE, 1.5, (float(z) + 0.5) * Balance.TILE)
	body.add_child(cs)


func _touches_open(x: int, z: int) -> bool:
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var c: String = ch(x + dx, z + dz)
			if not is_wall_char(c):
				return true
	return false


func _build_grid() -> void:
	astar.region = Rect2i(0, 0, w, h)
	astar.cell_size = Vector2(1.0, 1.0)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	_shot_block.resize(w * h)
	for z: int in range(h):
		for x: int in range(w):
			var c: String = ch(x, z)
			var blocked: bool = is_wall_char(c) or c == "~" or SOLID_PROPS.contains(c) or STATION_CHARS.has(c)
			astar.set_point_solid(Vector2i(x, z), blocked)
			var stops_shots: bool = is_wall_char(c) or c == "o" or c == "t" or STATION_CHARS.has(c)
			_shot_block[z * w + x] = 1 if stops_shots else 0


func _place_things() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(id)
	var deco: Node3D = _child("Props")
	for z: int in range(h):
		for x: int in range(w):
			var c: String = ch(x, z)
			var pos: Vector3 = cell_center(x, z)
			match c:
				"P":
					start_pos = pos
				"X":
					exit_pos = pos
					has_exit = true
					_build_exit(pos)
				"o":
					Decor.pillar(deco, pos, tileset, rng)
					_static_box(deco, pos, Vector3(1.3, 3.0, 1.3))
				"t":
					Decor.console(deco, pos, tileset, rng)
					_static_box(deco, pos, Vector3(1.5, 3.0, 1.2))
				"c", "$":
					if is_hub:
						Decor.cargo(deco, pos, rng)
						_static_box(deco, pos, Vector3(1.6, 3.0, 1.6))
					else:
						var prop: Prop = Prop.new()
						prop.setup(self, "cache" if c == "$" else "crate", Vector2i(x, z), rng)
						prop.position = pos
						deco.add_child(prop)
						props.append(prop)
				"+":
					spawn_pickup("kit", pos, 0)
				"B":
					if not is_hub:
						boss = spawn_enemy(String(def["boss"]), pos, false)
				_:
					if ENEMY_CHARS.has(c) and not is_hub:
						spawn_enemy(String(ENEMY_CHARS[c]), pos, false)
					elif STATION_CHARS.has(c):
						var st: Station = Station.new()
						st.setup(String(STATION_CHARS[c]), tileset)
						st.position = pos
						st.rotation.y = _face_open(x, z)
						deco.add_child(st)
						stations.append(st)
						_static_box(deco, pos, Vector3(1.6, 3.0, 1.6))


## Yaw that turns a station's front (+Z) toward the most open neighbouring cell.
func _face_open(x: int, z: int) -> float:
	var best: Vector2i = Vector2i(0, 1)
	var best_n: int = -1
	for d: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]:
		var n: int = 0
		for k: int in range(1, 4):
			if walkable(Vector2i(x + d.x * k, z + d.y * k)):
				n += 1
			else:
				break
		if n > best_n:
			best_n = n
			best = d
	return atan2(float(best.x), float(best.y))


func _static_box(parent: Node3D, pos: Vector3, size: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = Vector3(0.0, size.y * 0.5, 0.0)
	body.add_child(cs)
	body.position = pos
	parent.add_child(body)


func _build_exit(pos: Vector3) -> void:
	_exit_node = Node3D.new()
	_exit_node.name = "ExtractionPad"
	_exit_node.position = pos
	add_child(_exit_node)
	Art.part(_exit_node, Art.cylinder(1.5, 1.6, 0.16, 12), Art.mat(Color(0.32, 0.34, 0.38)), Vector3(0.0, 0.08, 0.0))
	Art.part(_exit_node, Art.cylinder(1.15, 1.15, 0.18, 12), Art.mat(Color(0.18, 0.2, 0.24)), Vector3(0.0, 0.1, 0.0))
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 1.2
	torus.outer_radius = 1.42
	torus.rings = 16
	torus.ring_segments = 4
	_exit_ring = Art.part(_exit_node, torus, Art.mat(Color(0.5, 0.15, 0.12), 0.6), Vector3(0.0, 0.18, 0.0))
	var beam_mat: StandardMaterial3D = Art.alpha_mat(Color(0.3, 0.9, 1.0, 0.22), true)
	_exit_beam = Art.part(_exit_node, Art.cylinder(1.05, 1.05, 6.0, 12), beam_mat, Vector3(0.0, 3.1, 0.0))
	_exit_beam.visible = false


func activate_exit() -> void:
	if not has_exit or exit_active:
		return
	exit_active = true
	if _exit_ring != null:
		_exit_ring.material_override = Art.mat(Color(0.3, 0.95, 1.0), 2.0)
	if _exit_beam != null:
		_exit_beam.visible = true
	var light: OmniLight3D = OmniLight3D.new()
	light.light_color = Color(0.3, 0.9, 1.0)
	light.light_energy = 2.0
	light.omni_range = 6.0
	light.position = Vector3(0.0, 1.5, 0.0)
	_exit_node.add_child(light)
	Sfx.play("warp", -8.0)


func _build_lights() -> void:
	var p: Dictionary = Art.palette(tileset)
	var count: int = 0
	for z: int in range(h):
		for x: int in range(w):
			if count >= 28:
				return
			var c: String = ch(x, z)
			var want: bool = false
			if c == "~" and (x * 7 + z * 13) % 9 == 0:
				want = true
			elif c == "w" and (x + z) % 4 == 0 and _touches_open(x, z):
				want = true
			if want:
				var light: OmniLight3D = OmniLight3D.new()
				light.light_color = p["glow"]
				light.light_energy = 1.4 if c == "~" else 0.8
				light.omni_range = 5.0
				light.omni_attenuation = 1.5
				light.position = cell_center(x, z) + Vector3(0.0, 1.2, 0.0)
				add_child(light)
				count += 1


# --- Per-frame --------------------------------------------------------------------------

func _process(delta: float) -> void:
	var pts: PackedVector3Array = PackedVector3Array()
	pts.resize(4)
	var n: int = 0
	for p: GorillaBot in players:
		if n < 4 and is_instance_valid(p):
			pts[n] = p.global_position + Vector3(0.0, 1.0, 0.0)
			n += 1
	for m: ShaderMaterial in _wall_mats:
		m.set_shader_parameter("players", pts)
		m.set_shader_parameter("player_count", n)
	if _exit_ring != null and exit_active:
		_exit_ring.rotation.y += delta * 1.5


## Steps every entity by dt. The smoke test uses this to fast-forward without real frames.
func simulate(seconds: float, dt: float = 1.0 / 60.0) -> void:
	var t: float = 0.0
	while t < seconds:
		for p: GorillaBot in players:
			if is_instance_valid(p):
				p.step(dt)
		for e: RobotEnemy in enemies.duplicate():
			if is_instance_valid(e):
				e.step(dt)
		for b: Node in bolts.get_children():
			if b is Bolt and not b.is_queued_for_deletion():
				(b as Bolt).step(dt)
		for k: Node in pickups.get_children():
			if k is Pickup and not k.is_queued_for_deletion():
				(k as Pickup).step(dt)
		t += dt


# --- Spawning ---------------------------------------------------------------------------

func spawn_enemy(kind: String, pos: Vector3, awake: bool) -> RobotEnemy:
	var e: RobotEnemy = RobotEnemy.new()
	e.setup(self, kind)
	e.position = pos
	actors.add_child(e)
	enemies.append(e)
	if awake:
		e.wake()
	return e


func spawn_bolt(from: Vector3, dir: Vector3, speed: float, damage: float, max_range: float,
		friendly: bool, source: Node3D, arcs: bool = false) -> Bolt:
	var b: Bolt = Bolt.new()
	b.setup(self, dir, speed, damage, max_range, friendly, source, arcs)
	count("player_bolts" if friendly else "enemy_bolts")
	b.position = from
	bolts.add_child(b)
	return b


func spawn_pickup(kind: String, pos: Vector3, value: int) -> Pickup:
	var k: Pickup = Pickup.new()
	k.setup(self, kind, value)
	k.position = pos
	pickups.add_child(k)
	return k


## Scatters `amount` scrap around pos as a handful of nuts.
func spawn_scrap(pos: Vector3, amount: int) -> void:
	if amount <= 0:
		return
	var pieces: int = clampi(amount / 3, 1, 8)
	var each: int = amount / pieces
	var extra: int = amount - each * pieces
	for i: int in range(pieces):
		var k: Pickup = spawn_pickup("scrap", Vector3(pos.x, 0.0, pos.z), each + (extra if i == 0 else 0))
		var a: float = randf() * TAU
		k.pop(Vector3(cos(a), 0.0, sin(a)) * randf_range(2.0, 4.5))


func collect_scrap(amount: int) -> void:
	scrap_collected.emit(amount)


# --- Combat -----------------------------------------------------------------------------

func alive_players() -> Array[GorillaBot]:
	var out: Array[GorillaBot] = []
	for p: GorillaBot in players:
		if is_instance_valid(p) and p.alive:
			out.append(p)
	return out


func nearest_player(pos: Vector3) -> GorillaBot:
	var best: GorillaBot = null
	var best_d: float = INF
	for p: GorillaBot in alive_players():
		var d: float = p.global_position.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = p
	return best


## Damages every enemy and crate inside a cone. Returns how many were hit.
func hit_arc(origin: Vector3, dir: Vector3, radius: float, arc_deg: float, damage: float,
		knockback: float, stun: float = 0.0) -> int:
	var hits: int = 0
	var half: float = deg_to_rad(arc_deg) * 0.5
	for e: RobotEnemy in enemies.duplicate():
		if not e.alive:
			continue
		var d: Vector3 = e.global_position - origin
		d.y = 0.0
		if d.length() > radius + e.radius:
			continue
		if d.length() > 0.6 and absf(dir.signed_angle_to(d, Vector3.UP)) > half:
			continue
		e.take_damage(damage, d.normalized() if d.length() > 0.01 else dir, knockback, stun)
		hits += 1
	for p: Prop in props.duplicate():
		var d2: Vector3 = p.global_position - origin
		d2.y = 0.0
		if d2.length() <= radius + 0.7 and (d2.length() < 0.8 or absf(dir.signed_angle_to(d2, Vector3.UP)) <= half):
			p.take_damage(damage)
			hits += 1
	return hits


## Damages every enemy and crate within radius of center.
func hit_circle(center: Vector3, radius: float, damage: float, knockback: float, stun: float = 0.0) -> int:
	var hits: int = 0
	for e: RobotEnemy in enemies.duplicate():
		if not e.alive:
			continue
		var d: Vector3 = e.global_position - center
		d.y = 0.0
		if d.length() <= radius + e.radius:
			e.take_damage(damage, d.normalized() if d.length() > 0.01 else Vector3.FORWARD, knockback, stun)
			hits += 1
	for p: Prop in props.duplicate():
		var d2: Vector3 = p.global_position - center
		d2.y = 0.0
		if d2.length() <= radius + 0.7:
			p.take_damage(damage)
			hits += 1
	return hits


## Enemy area attack: damages every player within radius. Returns how many were hit.
func hurt_players(center: Vector3, radius: float, damage: float) -> int:
	count("enemy_slams")
	var hits: int = 0
	for p: GorillaBot in alive_players():
		var d: Vector3 = p.global_position - center
		d.y = 0.0
		if d.length() <= radius + 0.5 and p.take_damage(damage, center):
			hits += 1
	return hits


func nearest_enemy(pos: Vector3, max_dist: float, exclude: RobotEnemy = null) -> RobotEnemy:
	var best: RobotEnemy = null
	var best_d: float = max_dist
	for e: RobotEnemy in enemies:
		if e == exclude or not e.alive:
			continue
		var d: float = e.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = e
	return best


func on_enemy_dead(e: RobotEnemy) -> void:
	enemies.erase(e)
	var range_v: Vector2i = e.stats.get("scrap", Vector2i(1, 2))
	var amount: int = int(round(float(randi_range(range_v.x, range_v.y)) * Balance.scrap_mult(tier, player_count)))
	if e.minion:
		amount = 0 if randf() < 0.5 else 1
	spawn_scrap(e.global_position, amount)
	enemy_died.emit(e)
	if e == boss:
		boss_died.emit(e)
		activate_exit()


func on_prop_broken(p: Prop) -> void:
	props.erase(p)
	astar.set_point_solid(p.cell, false)
	var range_v: Vector2i = Balance.CACHE_SCRAP if p.kind == "cache" else Balance.CRATE_SCRAP
	spawn_scrap(p.global_position, int(round(float(randi_range(range_v.x, range_v.y)) * Balance.scrap_mult(tier, player_count))))


## Changes how many bots are in the map and rescales every enemy's HP to match.
func set_player_count(n: int) -> void:
	n = clampi(n, 1, 4)
	if n == player_count:
		return
	var old: int = player_count
	player_count = n
	for e: RobotEnemy in enemies:
		e.rescale(old, n)


func count(key: String) -> void:
	counters[key] = int(counters.get(key, 0)) + 1


func shake(amount: float) -> void:
	shake_requested.emit(amount)
