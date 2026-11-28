class_name MapGen
extends RefCounted

## Random mission maps (Matt's request). generate() lays out a fresh map for a mission, in the same
## text-grid format as the hand-made maps in maps.gd (same legend), so LevelMap builds it unchanged:
##   1. rooms: the start room in one corner, the boss room in the opposite corner, and a handful of
##      rooms of random sizes in between, never touching (at least two wall tiles apart)
##   2. corridors, three tiles wide, along a minimum spanning tree of the rooms plus a few extra
##      links so there are loops; doorways get hazard stripes (cracks on the ash map)
##   3. each room gets a layout (a pillar hall, a machine room, pits or lava pools, a loot store, or
##      open floor); the ash map adds a lava river that the corridors bridge
##   4. robots in groups, more of them further from the start; crates, scrap caches, repair kits
##   5. checks: the boss, the pad, every robot, every kit and every crate can be reached from P.
##      A room's obstacles are taken back if they would cut a doorway off, and a layout that fails
##      the final check is thrown away and rolled again (after a few tries: the hand-made map).
## The start room is kept clear east of P (the smoke test fights there), and the boss has open floor
## around it. The same mission and seed give the same map on every machine (integer maths and a
## seeded RandomNumberGenerator only): that is how online clients rebuild the host's map.

const WALL: int = 35      # #
const VENT: int = 119     # w
const FLOOR: int = 46     # .
const DETAIL: int = 44    # ,
const STRIPE: int = 61    # =
const PIT: int = 126      # ~
const PILLAR: int = 111   # o
const CONSOLE: int = 116  # t
const CRATE: int = 99     # c
const CACHE: int = 36     # $
const KIT: int = 43       # +
const START: int = 80     # P
const EXIT: int = 88      # X
const BOSS: int = 66      # B
const ENEMIES: String = "sgb"

const DEFAULTS: Dictionary = {
	"size": Vector2i(46, 40),
	"rooms": Vector2i(6, 9),      # rooms besides the start and the boss room
	"enemies": 20,                # robots outside the boss room, roughly
	"mix": "sssssgggbb",          # picked from at random for each robot
	"layouts": "ppmmmkkllo",      # p pillars, m machines, k pits, l loot, o open
	"river": false,               # a lava river across the middle (the corridors bridge it)
	"min_path": 26,               # steps from P to the boss, at least
}

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _w: int = 0
var _h: int = 0
var _g: PackedByteArray = PackedByteArray()
var _corr: PackedByteArray = PackedByteArray()   # 1 = corridor floor outside every room
var _keep: PackedByteArray = PackedByteArray()   # 1 = nothing solid may go here
var _rooms: Array[Rect2i] = []
var _doors: PackedInt32Array = PackedInt32Array()
var _start: Vector2i = Vector2i.ZERO
var _boss: Vector2i = Vector2i.ZERO
var _exit: Vector2i = Vector2i.ZERO
var _p: Dictionary = {}


## The map's rows for this mission and seed.
static func generate(def: Dictionary, seed_value: int) -> Array[String]:
	var gen: MapGen = MapGen.new()
	for attempt: int in range(6):
		var rows: Array[String] = gen._try(def, seed_value + attempt * 7919)
		if not rows.is_empty():
			return rows
	var fallback: Array[String] = []
	for r: Variant in def["rows"]:
		fallback.append(String(r))
	return fallback


func _try(def: Dictionary, seed_value: int) -> Array[String]:
	_p = DEFAULTS.duplicate()
	var gen: Dictionary = def.get("gen", {})
	_p.merge(gen, true)
	_rng.seed = seed_value
	var size: Vector2i = _p["size"]
	_w = size.x
	_h = size.y
	_g = PackedByteArray()
	_g.resize(_w * _h)
	_g.fill(WALL)
	_corr = PackedByteArray()
	_corr.resize(_w * _h)
	_keep = PackedByteArray()
	_keep.resize(_w * _h)
	_rooms.clear()
	_doors = PackedInt32Array()
	if not _place_rooms():
		return []
	for r: Rect2i in _rooms:
		_fill(r, FLOOR)
	_connect_rooms()
	_mark_doors()
	_dress_start_room()
	_dress_boss_room()
	for i: int in range(2, _rooms.size()):
		_dress_room(i)
	if bool(_p["river"]):
		_lava_river()
	_floor_details()
	var reach: PackedInt32Array = _bfs(_start)
	if reach[_i(_boss.x, _boss.y)] < int(_p["min_path"]) or reach[_i(_exit.x, _exit.y)] < 0:
		return []
	_place_loot(reach)
	_place_enemies(reach)
	_vents()
	if not _final_check():
		return []
	var rows: Array[String] = []
	for z: int in range(_h):
		rows.append(_g.slice(z * _w, (z + 1) * _w).get_string_from_ascii())
	return rows


# --- Grid helpers ----------------------------------------------------------------------------

func _i(x: int, z: int) -> int:
	return z * _w + x


func _at(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= _w or z >= _h:
		return WALL
	return _g[_i(x, z)]


func _put(x: int, z: int, c: int) -> void:
	if x > 0 and z > 0 and x < _w - 1 and z < _h - 1:
		_g[_i(x, z)] = c


func _fill(r: Rect2i, c: int) -> void:
	for z: int in range(r.position.y, r.end.y):
		for x: int in range(r.position.x, r.end.x):
			_put(x, z, c)


static func walkable(c: int) -> bool:
	return c != WALL and c != VENT and c != PIT and c != PILLAR and c != CONSOLE and c != CRATE and c != CACHE


func _is_floor(x: int, z: int) -> bool:
	var c: int = _at(x, z)
	return c == FLOOR or c == DETAIL


func _center(r: Rect2i) -> Vector2i:
	return r.position + r.size / 2


## Steps from `from` to every cell over walkable tiles (4 directions), -1 where it can't get.
func _bfs(from: Vector2i) -> PackedInt32Array:
	var dist: PackedInt32Array = PackedInt32Array()
	dist.resize(_w * _h)
	dist.fill(-1)
	var queue: PackedInt32Array = PackedInt32Array([_i(from.x, from.y)])
	dist[queue[0]] = 0
	var head: int = 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		var cx: int = cur % _w
		var cz: int = cur / _w
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = cx + d.x
			var nz: int = cz + d.y
			if nx < 0 or nz < 0 or nx >= _w or nz >= _h:
				continue
			var ni: int = _i(nx, nz)
			if dist[ni] < 0 and walkable(_g[ni]):
				dist[ni] = dist[cur] + 1
				queue.append(ni)
	return dist


func _doors_reachable() -> bool:
	var reach: PackedInt32Array = _bfs(_start)
	for d: int in _doors:
		if reach[d] < 0:
			return false
	return reach[_i(_boss.x, _boss.y)] >= 0


# --- 1. Rooms --------------------------------------------------------------------------------

func _place_rooms() -> bool:
	var corner: int = _rng.randi_range(0, 3)
	var cx: int = corner % 2
	var cz: int = corner / 2
	_rooms.append(_corner_room(cx, cz, Vector2i(_rng.randi_range(10, 12), _rng.randi_range(8, 9))))
	_rooms.append(_corner_room(1 - cx, 1 - cz, Vector2i(_rng.randi_range(14, 16), _rng.randi_range(11, 12))))
	var span: Vector2i = _p["rooms"]
	var want: int = 2 + _rng.randi_range(span.x, span.y)
	var tries: int = 0
	while _rooms.size() < want and tries < 500:
		tries += 1
		var s: Vector2i = Vector2i(_rng.randi_range(6, 12), _rng.randi_range(5, 10))
		var r: Rect2i = Rect2i(Vector2i(_rng.randi_range(2, _w - 2 - s.x), _rng.randi_range(2, _h - 2 - s.y)), s)
		if _fits(r):
			_rooms.append(r)
	return _rooms.size() >= 2 + span.x


func _corner_room(cx: int, cz: int, s: Vector2i) -> Rect2i:
	var x: int = 2 + _rng.randi_range(0, 3) if cx == 0 else _w - 2 - s.x - _rng.randi_range(0, 3)
	var z: int = 2 + _rng.randi_range(0, 3) if cz == 0 else _h - 2 - s.y - _rng.randi_range(0, 3)
	return Rect2i(Vector2i(x, z), s)


func _fits(r: Rect2i) -> bool:
	for o: Rect2i in _rooms:
		if r.grow(2).intersects(o):
			return false
	return true


func _in_room(x: int, z: int) -> int:
	for k: int in range(_rooms.size()):
		if _rooms[k].has_point(Vector2i(x, z)):
			return k
	return -1


# --- 2. Corridors ----------------------------------------------------------------------------

func _connect_rooms() -> void:
	var n: int = _rooms.size()
	var linked: Dictionary = {}
	var edges: Array[Vector2i] = []
	# Prim's minimum spanning tree over the room centres.
	var inside: Array[int] = [0]
	while inside.size() < n:
		var best: Vector2i = Vector2i(-1, -1)
		var best_d: int = 1 << 30
		for a: int in inside:
			for b: int in range(n):
				if b in inside:
					continue
				var d: int = _dist2(_center(_rooms[a]), _center(_rooms[b]))
				if d < best_d:
					best_d = d
					best = Vector2i(a, b)
		inside.append(best.y)
		edges.append(best)
		linked[_key(best.x, best.y)] = true
	# A few extra links for loops (never straight from the start room to the boss room).
	for a2: int in range(n):
		if _rng.randf() >= 0.35:
			continue
		var best2: int = -1
		var best_d2: int = 1 << 30
		for b2: int in range(n):
			if b2 == a2 or linked.has(_key(a2, b2)) or (mini(a2, b2) == 0 and maxi(a2, b2) == 1):
				continue
			var d2: int = _dist2(_center(_rooms[a2]), _center(_rooms[b2]))
			if d2 < best_d2:
				best_d2 = d2
				best2 = b2
		if best2 >= 0:
			edges.append(Vector2i(a2, best2))
			linked[_key(a2, best2)] = true
	for e: Vector2i in edges:
		_corridor(_center(_rooms[e.x]), _center(_rooms[e.y]))
	for z: int in range(_h):
		for x: int in range(_w):
			if _is_floor(x, z) and _in_room(x, z) < 0:
				_corr[_i(x, z)] = 1


func _key(a: int, b: int) -> int:
	return mini(a, b) * 1000 + maxi(a, b)


func _dist2(a: Vector2i, b: Vector2i) -> int:
	var d: Vector2i = a - b
	return d.x * d.x + d.y * d.y


## A three-wide corridor from a to b with one bend.
func _corridor(a: Vector2i, b: Vector2i) -> void:
	var bend: Vector2i = Vector2i(b.x, a.y) if _rng.randi() % 2 == 0 else Vector2i(a.x, b.y)
	_run(a, bend)
	_run(bend, b)


func _run(a: Vector2i, b: Vector2i) -> void:
	var step: Vector2i = Vector2i(signi(b.x - a.x), signi(b.y - a.y))
	var p: Vector2i = a
	while true:
		for dz: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if _at(p.x + dx, p.y + dz) == WALL:
					_put(p.x + dx, p.y + dz, FLOOR)
		if p == b:
			break
		p += step


## Doorways: floor just outside a room's edge where a corridor comes in. They and the cells around
## them stay clear of anything solid. Openings up to 4 tiles wide get hazard stripes; a longer run
## is a corridor passing along the room's side, which stays plain floor.
func _mark_doors() -> void:
	for r: Rect2i in _rooms:
		var sides: Array[Array] = [[], [], [], []]   # top, bottom, left, right: cells in order
		for x: int in range(r.position.x, r.end.x):
			sides[0].append(Vector2i(x, r.position.y - 1))
			sides[1].append(Vector2i(x, r.end.y))
		for z: int in range(r.position.y, r.end.y):
			sides[2].append(Vector2i(r.position.x - 1, z))
			sides[3].append(Vector2i(r.end.x, z))
		for side: Array in sides:
			var run: Array[Vector2i] = []
			for k: int in range(side.size() + 1):
				var c: Vector2i = side[k] if k < side.size() else Vector2i(-1, -1)
				if k < side.size() and _is_floor(c.x, c.y) and _corr[_i(c.x, c.y)] == 1:
					run.append(c)
					continue
				for d: Vector2i in run:
					_door(d, run.size() <= 4)
				run.clear()


func _door(c: Vector2i, stripe: bool) -> void:
	_doors.append(_i(c.x, c.y))
	if stripe:
		_put(c.x, c.y, STRIPE)
	for dz: int in range(-2, 3):
		for dx: int in range(-2, 3):
			var nx: int = c.x + dx
			var nz: int = c.y + dz
			if nx >= 0 and nz >= 0 and nx < _w and nz < _h:
				_keep[_i(nx, nz)] = 1


# --- 3. Room layouts -------------------------------------------------------------------------

## True if c can go at (x, z): plain floor in a room, away from doorways, and not boxed in by
## other solid things next to it (so obstacles never form walls of their own).
func _can_block(x: int, z: int) -> bool:
	if not _is_floor(x, z) or _keep[_i(x, z)] == 1 or _corr[_i(x, z)] == 1:
		return false
	return true


func _solid(x: int, z: int, c: int, placed: Array[Vector3i]) -> void:
	if _can_block(x, z):
		placed.append(Vector3i(x, z, _at(x, z)))
		_put(x, z, c)


func _undo(placed: Array[Vector3i]) -> void:
	for k: int in range(placed.size() - 1, -1, -1):
		var v: Vector3i = placed[k]
		_g[_i(v.x, v.y)] = v.z
	placed.clear()


func _dress_start_room() -> void:
	var r: Rect2i = _rooms[0]
	_start = Vector2i(r.position.x + 2, r.position.y + r.size.y / 2)
	# Nothing solid in the start room, so there's room to fight east of P.
	for z: int in range(r.position.y, r.end.y):
		for x: int in range(r.position.x, r.end.x):
			_keep[_i(x, z)] = 1
	_put(_start.x, _start.y, START)


func _dress_boss_room() -> void:
	var r: Rect2i = _rooms[1]
	_boss = _center(r)
	for dz: int in range(-3, 4):
		for dx: int in range(-3, 4):
			_keep[_i(_boss.x + dx, _boss.y + dz)] = 1
	# The extraction pad: the open spot in the boss room furthest from the start.
	var best: int = -1
	for z: int in range(r.position.y + 1, r.end.y - 1):
		for x: int in range(r.position.x + 1, r.end.x - 1):
			if absi(x - _boss.x) < 4 and absi(z - _boss.y) < 4:
				continue
			if _keep[_i(x, z)] == 1:
				continue
			var d: int = _dist2(Vector2i(x, z), _start)
			if d > best:
				best = d
				_exit = Vector2i(x, z)
	if best < 0:
		_exit = _boss + Vector2i(4, 0)
	for dz2: int in range(-1, 2):
		for dx2: int in range(-1, 2):
			_keep[_i(_exit.x + dx2, _exit.y + dz2)] = 1
	_put(_boss.x, _boss.y, BOSS)
	_put(_exit.x, _exit.y, EXIT)
	var placed: Array[Vector3i] = []
	for c: Vector2i in [Vector2i(2, 2), Vector2i(r.size.x - 3, 2), Vector2i(2, r.size.y - 3), Vector2i(r.size.x - 3, r.size.y - 3)]:
		_solid(r.position.x + c.x, r.position.y + c.y, PILLAR, placed)
	for k: int in range(2):
		var at: Vector2i = Vector2i(_rng.randi_range(r.position.x + 2, r.end.x - 4), _rng.randi_range(r.position.y + 2, r.end.y - 4))
		if absi(at.x - _boss.x) >= 3 and absi(at.y - _boss.y) >= 3:
			for q: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				_solid(at.x + q.x, at.y + q.y, PIT, placed)
	if not _doors_reachable():
		_undo(placed)


func _dress_room(i: int) -> void:
	var r: Rect2i = _rooms[i]
	var layouts: String = _p["layouts"]
	var kind: String = layouts[_rng.randi_range(0, layouts.length() - 1)]
	var placed: Array[Vector3i] = []
	var x0: int = r.position.x
	var z0: int = r.position.y
	var x1: int = r.end.x - 1
	var z1: int = r.end.y - 1
	match kind:
		"p":
			# Pillars in two rows, two tiles in from the walls.
			var step: int = 3 if r.size.x >= 9 else 4
			for x: int in range(x0 + 2, x1 - 1, step):
				_solid(x, z0 + 2, PILLAR, placed)
				_solid(x, z1 - 2, PILLAR, placed)
		"m":
			# Machines along one wall.
			var along_top: bool = _rng.randi() % 2 == 0
			for x2: int in range(x0 + 1, x1, 2):
				_solid(x2, z0 if along_top else z1, CONSOLE, placed)
			if r.size.y >= 8:
				_solid(x0 + r.size.x / 2, z0 + r.size.y / 2, CONSOLE, placed)
		"k":
			# Pits (lava pools on the ash map): two or three blobs.
			for b: int in range(_rng.randi_range(2, 3)):
				var at: Vector2i = Vector2i(_rng.randi_range(x0 + 1, maxi(x0 + 1, x1 - 2)), _rng.randi_range(z0 + 1, maxi(z0 + 1, z1 - 2)))
				var wide: int = _rng.randi_range(2, 3)
				for dz: int in range(2):
					for dx: int in range(wide):
						_solid(at.x + dx, at.y + dz, PIT, placed)
		"l":
			# A store room: crates stacked in the corners.
			for c: Vector2i in [Vector2i(x0, z0), Vector2i(x1, z0), Vector2i(x0, z1), Vector2i(x1, z1)]:
				if _rng.randf() < 0.7:
					var sx: int = 1 if c.x == x0 else -1
					var sz: int = 1 if c.y == z0 else -1
					_solid(c.x, c.y, CRATE, placed)
					_solid(c.x + sx, c.y, CRATE, placed)
					if _rng.randf() < 0.5:
						_solid(c.x, c.y + sz, CRATE, placed)
		_:
			# Open floor with the odd pillar.
			if r.size.x >= 8 and r.size.y >= 7:
				_solid(x0 + r.size.x / 2, z0 + r.size.y / 2, PILLAR, placed)
	# A stray crate or two in any room.
	for k: int in range(_rng.randi_range(0, 2)):
		var cx: int = x0 if _rng.randi() % 2 == 0 else x1
		_solid(cx, _rng.randi_range(z0, z1), CRATE, placed)
	if not _doors_reachable():
		_undo(placed)


## The ash map's lava river: a band across the middle. Corridor floor stays (the bridges).
func _lava_river() -> void:
	var z0: int = _rng.randi_range(_h / 3, _h * 2 / 3)
	var placed: Array[Vector3i] = []
	for z: int in range(z0, z0 + 2):
		for x: int in range(1, _w - 1):
			if _is_floor(x, z) and _corr[_i(x, z)] == 0 and _keep[_i(x, z)] == 0:
				placed.append(Vector3i(x, z, _at(x, z)))
				_put(x, z, PIT)
	if not _doors_reachable():
		_undo(placed)


## Floor detail (grating, ash): a strip along one wall of some rooms and a few patches.
func _floor_details() -> void:
	for r: Rect2i in _rooms:
		if _rng.randf() < 0.5:
			var z: int = r.position.y if _rng.randi() % 2 == 0 else r.end.y - 1
			for x: int in range(r.position.x, r.end.x):
				if _at(x, z) == FLOOR:
					_put(x, z, DETAIL)
		for k: int in range(_rng.randi_range(0, 2)):
			var px: int = _rng.randi_range(r.position.x, r.end.x - 1)
			var pz: int = _rng.randi_range(r.position.y, r.end.y - 1)
			for dz: int in range(2):
				for dx: int in range(_rng.randi_range(1, 3)):
					if _at(px + dx, pz + dz) == FLOOR:
						_put(px + dx, pz + dz, DETAIL)


# --- 4. Loot and robots ----------------------------------------------------------------------

## The rooms after the start, nearest (by walking) first.
func _rooms_by_distance(reach: PackedInt32Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []   # (room index, steps)
	for k: int in range(2, _rooms.size()):
		var c: Vector2i = _center(_rooms[k])
		var best: int = 1 << 30
		var r: Rect2i = _rooms[k]
		for z: int in range(r.position.y, r.end.y):
			for x: int in range(r.position.x, r.end.x):
				var d: int = reach[_i(x, z)]
				if d >= 0 and d < best:
					best = d
		if best < (1 << 30):
			out.append(Vector2i(k, best))
		else:
			out.append(Vector2i(k, 9999 + _dist2(c, _start)))
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return out


func _free_cells(r: Rect2i, reach: PackedInt32Array, min_from_start: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for z: int in range(r.position.y, r.end.y):
		for x: int in range(r.position.x, r.end.x):
			if not _is_floor(x, z) or reach[_i(x, z)] < 0:
				continue
			if maxi(absi(x - _start.x), absi(z - _start.y)) < min_from_start:
				continue
			out.append(Vector2i(x, z))
	return out


func _pick(cells: Array[Vector2i]) -> Vector2i:
	var k: int = _rng.randi_range(0, cells.size() - 1)
	var c: Vector2i = cells[k]
	cells.remove_at(k)
	return c


func _place_loot(reach: PackedInt32Array) -> void:
	var order: Array[Vector2i] = _rooms_by_distance(reach)
	# A repair kit in the start room, and one about halfway and one near the end.
	var start_cells: Array[Vector2i] = _free_cells(_rooms[0], reach, 0)
	var keep_out: Array[Vector2i] = []
	for c: Vector2i in start_cells:
		if c.y == _start.y or absi(c.y - _start.y) <= 1 and c.x > _start.x:
			keep_out.append(c)
	for c2: Vector2i in keep_out:
		start_cells.erase(c2)
	if not start_cells.is_empty():
		var kit: Vector2i = _pick(start_cells)
		_put(kit.x, kit.y, KIT)
	for frac: float in [0.45, 0.85]:
		if order.is_empty():
			break
		var room: int = order[mini(int(float(order.size()) * frac), order.size() - 1)].x
		var cells: Array[Vector2i] = _free_cells(_rooms[room], reach, 6)
		if not cells.is_empty():
			var k: Vector2i = _pick(cells)
			_put(k.x, k.y, KIT)
	# Scrap caches against a wall in two of the further rooms.
	var caches: int = 0
	for n: int in range(order.size() - 1, -1, -1):
		if caches >= 2:
			break
		var r: Rect2i = _rooms[order[n].x]
		var spots: Array[Vector2i] = []
		for z: int in range(r.position.y, r.end.y):
			for x: int in range(r.position.x, r.end.x):
				var edge: bool = x == r.position.x or x == r.end.x - 1 or z == r.position.y or z == r.end.y - 1
				if edge and _can_block(x, z):
					spots.append(Vector2i(x, z))
		if spots.is_empty():
			continue
		var s: Vector2i = _pick(spots)
		_put(s.x, s.y, CACHE)
		if _doors_reachable():
			caches += 1
		else:
			_put(s.x, s.y, FLOOR)


func _place_enemies(reach: PackedInt32Array) -> void:
	var order: Array[Vector2i] = _rooms_by_distance(reach)
	var mix: String = _p["mix"]
	var total: int = int(_p["enemies"])
	var weights: Array[float] = []
	var sum: float = 0.0
	for n: int in range(order.size()):
		var r: Rect2i = _rooms[order[n].x]
		var depth: float = float(n) / float(maxi(order.size() - 1, 1))
		var wgt: float = float(r.size.x * r.size.y) * (0.6 + depth)
		weights.append(wgt)
		sum += wgt
	for n2: int in range(order.size()):
		var room: Rect2i = _rooms[order[n2].x]
		var count: int = clampi(int(round(float(total) * weights[n2] / maxf(sum, 1.0))), 1, 7)
		var cells: Array[Vector2i] = _free_cells(room, reach, 8)
		for k: int in range(count):
			if cells.is_empty():
				break
			var c: Vector2i = _pick(cells)
			var e: String = mix[_rng.randi_range(0, mix.length() - 1)]
			if e == "b" and n2 == 0:
				e = "s"  # no bruiser in the first room
			_put(c.x, c.y, e.unicode_at(0))
			# Keep the next one off this tile's neighbours, so a group spreads out a little.
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				cells.erase(c + d)
	# A pair of guards in the boss room.
	var guards: Array[Vector2i] = []
	for c3: Vector2i in _free_cells(_rooms[1], reach, 8):
		var d3: int = maxi(absi(c3.x - _boss.x), absi(c3.y - _boss.y))
		if d3 >= 3 and d3 <= 5:
			guards.append(c3)
	for g: int in range(2):
		if guards.is_empty():
			break
		var gc: Vector2i = _pick(guards)
		_put(gc.x, gc.y, ("g" if g == 0 else "s").unicode_at(0))


# --- 5. Finishing ----------------------------------------------------------------------------

## A glowing vent now and then in a wall that faces open floor.
func _vents() -> void:
	for z: int in range(1, _h - 1):
		for x: int in range(1, _w - 1):
			if _at(x, z) == WALL and _is_floor(x, z + 1) and _at(x - 1, z) == WALL and _at(x + 1, z) == WALL:
				if _rng.randf() < 0.07:
					_g[_i(x, z)] = VENT


## Everything that matters can be reached from P; robots or loot that can't are removed, and the
## map fails if the boss or the pad can't.
func _final_check() -> bool:
	var reach: PackedInt32Array = _bfs(_start)
	if reach[_i(_boss.x, _boss.y)] < int(_p["min_path"]) or reach[_i(_exit.x, _exit.y)] < 0:
		return false
	for z: int in range(_h):
		for x: int in range(_w):
			var c: int = _at(x, z)
			var cs: String = char(c)
			if (ENEMIES.contains(cs) or c == KIT) and reach[_i(x, z)] < 0:
				_g[_i(x, z)] = FLOOR
			elif c == CRATE or c == CACHE or c == CONSOLE:
				var ok: bool = false
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = x + d.x
					var nz: int = z + d.y
					if nx >= 0 and nz >= 0 and nx < _w and nz < _h and reach[_i(nx, nz)] >= 0:
						ok = true
				if not ok and c != CONSOLE:
					_g[_i(x, z)] = FLOOR
	return true
