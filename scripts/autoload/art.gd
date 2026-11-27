extends Node

## Everything visual that isn't geometry: tile textures painted pixel by pixel at startup, shared
## materials, the floor and wall shaders, and the UI theme with the pixel font.
## Tile textures are TILE_PX square and drawn with nearest filtering for the 16-bit look.

const TILE_PX: int = 16
const FONT_PATH: String = "res://assets/fonts/PressStart2P-Regular.ttf"

# Colours per tileset. base/dark/light = main surface, rust = second surface,
# accent = paint (hazard stripes), glow = emissive colour (lights, slag, lava).
const PALETTES: Dictionary = {
	"ship": {"base": Color(0.36, 0.41, 0.5), "dark": Color(0.24, 0.27, 0.34),
		"light": Color(0.5, 0.56, 0.66), "rust": Color(0.3, 0.34, 0.44),
		"accent": Color(0.9, 0.7, 0.2), "glow": Color(0.3, 0.85, 1.0),
		"wall": Color(0.27, 0.31, 0.4), "top": Color(0.44, 0.49, 0.6),
		"sky": Color(0.01, 0.01, 0.03), "ambient": Color(0.55, 0.6, 0.75)},
	"foundry": {"base": Color(0.31, 0.32, 0.35), "dark": Color(0.19, 0.2, 0.23),
		"light": Color(0.43, 0.44, 0.47), "rust": Color(0.42, 0.3, 0.21),
		"accent": Color(0.86, 0.64, 0.14), "glow": Color(1.0, 0.5, 0.12),
		"wall": Color(0.22, 0.23, 0.27), "top": Color(0.38, 0.39, 0.43),
		"sky": Color(0.02, 0.015, 0.02), "ambient": Color(0.6, 0.55, 0.55)},
	"ash": {"base": Color(0.29, 0.25, 0.24), "dark": Color(0.17, 0.14, 0.14),
		"light": Color(0.4, 0.35, 0.32), "rust": Color(0.36, 0.24, 0.18),
		"accent": Color(0.95, 0.42, 0.08), "glow": Color(1.0, 0.42, 0.08),
		"wall": Color(0.21, 0.17, 0.16), "top": Color(0.36, 0.3, 0.27),
		"sky": Color(0.03, 0.01, 0.01), "ambient": Color(0.65, 0.52, 0.48)},
}

# Team colours for players 1-4.
const PLAYER_COLORS: Array[Color] = [
	Color(1.0, 0.55, 0.15), Color(0.25, 0.8, 1.0), Color(0.45, 0.95, 0.35), Color(0.85, 0.45, 1.0),
]

const FLOOR_SHADER: String = """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform sampler2D glow_tex : source_color, filter_nearest, hint_default_black;
uniform vec2 map_size = vec2(1.0);
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 uv = wpos.xz / map_size;
	ALBEDO = texture(albedo_tex, uv).rgb;
	vec3 g = texture(glow_tex, uv).rgb;
	float pulse = 0.7 + 0.3 * sin(TIME * 2.2 + wpos.x * 0.6 + wpos.z * 0.45);
	EMISSION = g * pulse * 1.8;
}
"""

# Walls map their textures in world space (sides by height, tops by x/z), and dither away any
# part of a wall that stands between the camera and a player so nobody gets lost behind one.
const WALL_SHADER: String = """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
uniform sampler2D side_tex : source_color, filter_nearest, repeat_enable;
uniform sampler2D top_tex : source_color, filter_nearest, repeat_enable;
uniform sampler2D glow_tex : source_color, filter_nearest, repeat_enable, hint_default_black;
uniform float tile = 2.0;
uniform float wall_h = 1.6;
uniform vec3 players[4];
uniform int player_count = 0;
uniform float cut_radius = 2.4;
varying vec3 wpos;
varying vec3 wnorm;
const float BAYER[16] = float[](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 back = INV_VIEW_MATRIX[2].xyz;
	float fade = 0.0;
	for (int i = 0; i < 4; i++) {
		if (i < player_count) {
			vec3 d = wpos - players[i];
			float nearer = dot(d, back);
			if (nearer > 0.6) {
				vec2 s = vec2(dot(d, right), dot(d, up) * 1.15);
				fade = max(fade, 1.0 - smoothstep(cut_radius * 0.55, cut_radius, length(s)));
			}
		}
	}
	int bi = (int(FRAGCOORD.y) % 4) * 4 + (int(FRAGCOORD.x) % 4);
	if (fade * 0.9 > (BAYER[bi] + 0.5) / 16.0) {
		discard;
	}
	vec3 col;
	vec3 glow = vec3(0.0);
	if (wnorm.y > 0.5) {
		col = texture(top_tex, wpos.xz / tile).rgb;
	} else {
		float u = abs(wnorm.x) > 0.5 ? wpos.z : wpos.x;
		vec2 uv = vec2(u / tile, (wall_h - wpos.y) / wall_h);
		col = texture(side_tex, uv).rgb;
		glow = texture(glow_tex, uv).rgb;
	}
	ALBEDO = col;
	EMISSION = glow * (0.8 + 0.2 * sin(TIME * 3.0 + wpos.x + wpos.z)) * 1.6;
}
"""

var font: FontFile
var theme: Theme
var floor_shader: Shader
var wall_shader: Shader
var _tilesets: Dictionary = {}  # tileset -> {key: Image}
var _mats: Dictionary = {}
var _meshes: Dictionary = {}


func _ready() -> void:
	floor_shader = Shader.new()
	floor_shader.code = FLOOR_SHADER
	wall_shader = Shader.new()
	wall_shader.code = WALL_SHADER
	font = load(FONT_PATH) as FontFile
	if font != null:
		font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		font.hinting = TextServer.HINTING_NONE
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		font.generate_mipmaps = false
	_build_theme()


func palette(tileset: String) -> Dictionary:
	return PALETTES.get(tileset, PALETTES["foundry"])


# --- Materials and meshes ---------------------------------------------------------------

## Shared flat-colour material with banded (toon) shading. emission > 0 makes it glow.
func mat(color: Color, emission: float = 0.0) -> StandardMaterial3D:
	var key: String = "%s|%.2f" % [color.to_html(), emission]
	if _mats.has(key):
		return _mats[key]
	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	m.metallic_specular = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	_mats[key] = m
	return m


## A new (unshared) see-through unshaded material, for shadows, telegraphs and flashes.
func alpha_mat(color: Color, glow: bool = false) -> StandardMaterial3D:
	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	if glow:
		m.emission_enabled = true
		m.emission = Color(color.r, color.g, color.b)
		m.emission_energy_multiplier = 1.5
	return m


func box(size: Vector3) -> BoxMesh:
	var key: String = "box%s" % size
	if not _meshes.has(key):
		var b: BoxMesh = BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]


func ball(radius: float, segments: int = 8) -> SphereMesh:
	var key: String = "ball%.3f_%d" % [radius, segments]
	if not _meshes.has(key):
		var s: SphereMesh = SphereMesh.new()
		s.radius = radius
		s.height = radius * 2.0
		s.radial_segments = segments
		s.rings = maxi(segments / 2, 3)
		_meshes[key] = s
	return _meshes[key]


func cylinder(top: float, bottom: float, height: float, segments: int = 10) -> CylinderMesh:
	var key: String = "cyl%.3f_%.3f_%.3f_%d" % [top, bottom, height, segments]
	if not _meshes.has(key):
		var c: CylinderMesh = CylinderMesh.new()
		c.top_radius = top
		c.bottom_radius = bottom
		c.height = height
		c.radial_segments = segments
		c.rings = 1
		_meshes[key] = c
	return _meshes[key]


## Adds a MeshInstance3D to parent and returns it.
func part(parent: Node3D, mesh: Mesh, material: Material, pos: Vector3,
		rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## A soft dark disc under a character (16-bit games fake shadows the same way).
func blob_shadow(parent: Node3D, radius: float) -> MeshInstance3D:
	var mi: MeshInstance3D = part(parent, cylinder(radius, radius, 0.02, 12),
		_shadow_mat(), Vector3(0.0, 0.03, 0.0))
	return mi


func _shadow_mat() -> StandardMaterial3D:
	if not _mats.has("shadow"):
		var m: StandardMaterial3D = alpha_mat(Color(0.0, 0.0, 0.0, 0.38))
		m.render_priority = -1
		_mats["shadow"] = m
	return _mats["shadow"]


func wall_material(tileset: String, window: bool) -> ShaderMaterial:
	var t: Dictionary = tiles(tileset)
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = wall_shader
	m.set_shader_parameter("side_tex", ImageTexture.create_from_image(t["win_side" if window else "wall_side"]))
	m.set_shader_parameter("top_tex", ImageTexture.create_from_image(t["wall_top"]))
	m.set_shader_parameter("glow_tex", ImageTexture.create_from_image(t["win_glow" if window else "wall_glow"]))
	m.set_shader_parameter("tile", Balance.TILE)
	m.set_shader_parameter("wall_h", Balance.WALL_H)
	return m


# --- Tile textures ----------------------------------------------------------------------

## The tile images for a tileset, painted on first use: floor0-2, detail (,), stripe (=), pit (~)
## and their *_glow masks, plus wall_side, wall_top, wall_glow, win_side, win_glow.
func tiles(tileset: String) -> Dictionary:
	if _tilesets.has(tileset):
		return _tilesets[tileset]
	var p: Dictionary = palette(tileset)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(tileset)
	var t: Dictionary = {}
	var black: Image = _img(Color(0, 0, 0, 1))
	if tileset == "ash":
		t["floor0"] = _rock_floor(p, rng, 0)
		t["floor1"] = _rock_floor(p, rng, 1)
		t["floor2"] = _rock_floor(p, rng, 2)
		t["detail"] = _ash_drift(p, rng)
		var crack: Array[Image] = _cracks(p, rng)
		t["stripe"] = crack[0]
		t["stripe_glow"] = crack[1]
		var lava: Array[Image] = _lava(p, rng)
		t["pit"] = lava[0]
		t["pit_glow"] = lava[1]
		t["wall_side"] = _rock_wall(p, rng)
		t["wall_top"] = _rock_top(p, rng)
		t["wall_glow"] = black
		var seep: Array[Image] = _lava_seep(p, rng, t["wall_side"])
		t["win_side"] = seep[0]
		t["win_glow"] = seep[1]
	else:
		t["floor0"] = _plate(p, rng, false)
		t["floor1"] = _plate(p, rng, true)
		t["floor2"] = _tread(p, rng)
		t["detail"] = _grate(p, rng)
		t["stripe"] = _stripes(p, rng)
		t["stripe_glow"] = black
		var pit: Array[Image] = _slag(p, rng) if tileset == "foundry" else _void(rng)
		t["pit"] = pit[0]
		t["pit_glow"] = pit[1]
		var wall: Array[Image] = _metal_wall(p, rng, tileset == "ship")
		t["wall_side"] = wall[0]
		t["wall_glow"] = wall[1]
		t["wall_top"] = _wall_top(p, rng)
		var win: Array[Image] = _window(p, rng) if tileset == "ship" else _vent(p, rng, t["wall_side"])
		t["win_side"] = win[0]
		t["win_glow"] = win[1]
	if not t.has("stripe_glow"):
		t["stripe_glow"] = black
	t["black"] = black
	_tilesets[tileset] = t
	return t


func _img(c: Color) -> Image:
	var im: Image = Image.create(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8)
	im.fill(c)
	return im


func _shade(c: Color, d: float) -> Color:
	return Color(clampf(c.r + d, 0.0, 1.0), clampf(c.g + d, 0.0, 1.0), clampf(c.b + d, 0.0, 1.0), c.a)


func _speckle(im: Image, rng: RandomNumberGenerator, amount: float, chance: float) -> void:
	for y: int in range(TILE_PX):
		for x: int in range(TILE_PX):
			if rng.randf() < chance:
				im.set_pixel(x, y, _shade(im.get_pixel(x, y), rng.randf_range(-amount, amount)))


func _bevel(im: Image, light: Color, dark: Color) -> void:
	var n: int = TILE_PX - 1
	for i: int in range(TILE_PX):
		im.set_pixel(i, 0, light)
		im.set_pixel(0, i, light)
		im.set_pixel(i, n, dark)
		im.set_pixel(n, i, dark)


func _rivet(im: Image, x: int, y: int, p: Dictionary) -> void:
	im.set_pixel(x, y, _shade(p["light"], 0.12))
	im.set_pixel(x + 1, y + 1, p["dark"])


func _plate(p: Dictionary, rng: RandomNumberGenerator, split: bool) -> Image:
	var im: Image = _img(p["base"])
	_speckle(im, rng, 0.025, 0.45)
	if split:
		for i: int in range(TILE_PX):
			im.set_pixel(i, 7, p["dark"])
			im.set_pixel(i, 8, p["light"])
		for y: int in range(9, TILE_PX):
			im.set_pixel(7, y, p["dark"])
			im.set_pixel(8, y, p["light"])
	_bevel(im, p["light"], p["dark"])
	for c: Vector2i in [Vector2i(2, 2), Vector2i(12, 2), Vector2i(2, 12), Vector2i(12, 12)]:
		_rivet(im, c.x, c.y, p)
	return im


func _tread(p: Dictionary, rng: RandomNumberGenerator) -> Image:
	var im: Image = _img(p["rust"])
	_speckle(im, rng, 0.03, 0.5)
	for y: int in range(1, TILE_PX - 1, 4):
		for x: int in range(1, TILE_PX - 1, 4):
			var flip: bool = ((x + y) / 4) % 2 == 0
			var a: Vector2i = Vector2i(x, y) if flip else Vector2i(x + 2, y)
			var b: Vector2i = Vector2i(x + 2, y + 2) if flip else Vector2i(x, y + 2)
			im.set_pixel(a.x, a.y, _shade(p["rust"], 0.12))
			im.set_pixel((a.x + b.x) / 2, (a.y + b.y) / 2, _shade(p["rust"], 0.08))
			im.set_pixel(b.x, b.y, _shade(p["rust"], -0.08))
	_bevel(im, _shade(p["rust"], 0.08), p["dark"])
	return im


func _grate(p: Dictionary, rng: RandomNumberGenerator) -> Image:
	var im: Image = _img(_shade(p["dark"], -0.08))
	for y: int in range(TILE_PX):
		for x: int in range(TILE_PX):
			if x % 4 == 0 or y % 4 == 0:
				im.set_pixel(x, y, p["base"] if (x % 4 == 0) else _shade(p["base"], -0.05))
			elif rng.randf() < 0.08:
				im.set_pixel(x, y, _shade(p["dark"], 0.04))
	_bevel(im, p["light"], p["dark"])
	return im


func _stripes(p: Dictionary, rng: RandomNumberGenerator) -> Image:
	var im: Image = _img(p["accent"])
	for y: int in range(TILE_PX):
		for x: int in range(TILE_PX):
			var band: bool = ((x + y) / 4) % 2 == 0
			var c: Color = p["accent"] if band else Color(0.1, 0.09, 0.08)
			if rng.randf() < 0.18:
				c = _shade(c, rng.randf_range(-0.12, 0.05))
			im.set_pixel(x, y, c)
	_bevel(im, p["light"], p["dark"])
	return im


func _slag(p: Dictionary, rng: RandomNumberGenerator) -> Array[Image]:
	var im: Image = _img(Color(0.06, 0.04, 0.04))
	var gl: Image = _img(Color(0, 0, 0))
	var ph: float = rng.randf() * TAU
	for y: int in range(TILE_PX):
		for x: int in range(TILE_PX):
			var v: float = sin(float(x) * 0.8 + ph) * cos(float(y) * 0.6 + ph * 0.5) + rng.randf_range(-0.35, 0.35)
			if v > 0.45:
				var hot: Color = Color(1.0, 0.62, 0.18) if v > 0.8 else Color(0.8, 0.3, 0.08)
				im.set_pixel(x, y, hot)
				gl.set_pixel(x, y, hot * 0.9)
			elif v > 0.1:
				im.set_pixel(x, y, Color(0.22, 0.08, 0.05))
	return [im, gl]


func _void(rng: RandomNumberGenerator) -> Array[Image]:
	var im: Image = _img(Color(0.01, 0.01, 0.03))
	var gl: Image = _img(Color(0, 0, 0))
	for i: int in range(3):
		var x: int = rng.randi_range(0, TILE_PX - 1)
		var y: int = rng.randi_range(0, TILE_PX - 1)
		im.set_pixel(x, y, Color(0.8, 0.85, 1.0))
		gl.set_pixel(x, y, Color(0.5, 0.5, 0.6))
	return [im, gl]


func _metal_wall(p: Dictionary, rng: RandomNumberGenerator, clean: bool) -> Array[Image]:
	var im: Image = _img(p["wall"])
	var gl: Image = _img(Color(0, 0, 0))
	_speckle(im, rng, 0.02, 0.4)
	for x: int in range(TILE_PX):
		im.set_pixel(x, 0, p["top"])
		im.set_pixel(x, 1, _shade(p["wall"], 0.08))
		im.set_pixel(x, 6, _shade(p["wall"], -0.07))
		im.set_pixel(x, 7, _shade(p["wall"], 0.05))
		im.set_pixel(x, TILE_PX - 1, _shade(p["wall"], -0.1))
		im.set_pixel(x, TILE_PX - 2, _shade(p["wall"], -0.06))
	for y: int in range(2, TILE_PX - 2):
		im.set_pixel(0, y, _shade(p["wall"], 0.06))
		im.set_pixel(7, y, _shade(p["wall"], -0.08))
		im.set_pixel(8, y, _shade(p["wall"], 0.06))
	if clean:
		# Ship bulkheads have a strip light.
		for x: int in range(2, TILE_PX - 2):
			im.set_pixel(x, 4, p["glow"])
			gl.set_pixel(x, 4, p["glow"] * 0.8)
	else:
		# Foundry walls: a worn hazard band near the floor.
		for y: int in range(10, 13):
			for x: int in range(TILE_PX):
				var band: bool = ((x + y) / 3) % 2 == 0
				var c: Color = p["accent"] if band else Color(0.1, 0.09, 0.08)
				if rng.randf() < 0.25:
					c = _shade(c, -0.15)
				im.set_pixel(x, y, c)
		_rivet(im, 3, 3, p)
		_rivet(im, 11, 3, p)
	return [im, gl]


func _wall_top(p: Dictionary, rng: RandomNumberGenerator) -> Image:
	var im: Image = _img(p["top"])
	_speckle(im, rng, 0.025, 0.4)
	_bevel(im, _shade(p["top"], 0.1), _shade(p["top"], -0.12))
	for i: int in range(3, TILE_PX - 3):
		im.set_pixel(i, 3, _shade(p["top"], -0.06))
		im.set_pixel(i, TILE_PX - 4, _shade(p["top"], 0.05))
	return im


func _window(p: Dictionary, rng: RandomNumberGenerator) -> Array[Image]:
	var im: Image = _metal_wall(p, rng, false)[0]
	var gl: Image = _img(Color(0, 0, 0))
	for y: int in range(3, 12):
		for x: int in range(2, TILE_PX - 2):
			var edge: bool = y == 3 or y == 11 or x == 2 or x == TILE_PX - 3
			var c: Color = p["light"] if edge else Color(0.04, 0.06, 0.16)
			if not edge and rng.randf() < 0.06:
				c = Color(0.85, 0.9, 1.0)
				gl.set_pixel(x, y, Color(0.6, 0.65, 0.8))
			elif not edge:
				gl.set_pixel(x, y, Color(0.02, 0.05, 0.15))
			im.set_pixel(x, y, c)
	return [im, gl]


func _vent(p: Dictionary, rng: RandomNumberGenerator, base: Image) -> Array[Image]:
	var im: Image = base.duplicate() as Image
	var gl: Image = _img(Color(0, 0, 0))
	for y: int in range(3, 10):
		for x: int in range(3, TILE_PX - 3):
			if y % 2 == 1:
				im.set_pixel(x, y, p["glow"])
				gl.set_pixel(x, y, p["glow"] * (0.6 + rng.randf() * 0.3))
			else:
				im.set_pixel(x, y, p["dark"])
	return [im, gl]


func _rock_floor(p: Dictionary, rng: RandomNumberGenerator, variant: int) -> Image:
	var im: Image = _img(p["base"])
	_speckle(im, rng, 0.04, 0.6)
	var blobs: int = 3 + variant
	for b: int in range(blobs):
		var cx: float = rng.randf_range(0.0, float(TILE_PX))
		var cy: float = rng.randf_range(0.0, float(TILE_PX))
		var r: float = rng.randf_range(1.5, 3.5)
		var d: float = -0.05 if b % 2 == 0 else 0.04
		for y: int in range(TILE_PX):
			for x: int in range(TILE_PX):
				var dx: float = wrapf(float(x) - cx, -8.0, 8.0)
				var dy: float = wrapf(float(y) - cy, -8.0, 8.0)
				if dx * dx + dy * dy < r * r:
					im.set_pixel(x, y, _shade(im.get_pixel(x, y), d))
	for i: int in range(2 + variant):
		var x: int = rng.randi_range(1, TILE_PX - 2)
		var y: int = rng.randi_range(1, TILE_PX - 2)
		im.set_pixel(x, y, p["light"])
		im.set_pixel(x + 1, y + 1, p["dark"])
	return im


func _ash_drift(p: Dictionary, rng: RandomNumberGenerator) -> Image:
	var im: Image = _rock_floor(p, rng, 0)
	for y: int in range(TILE_PX):
		for x: int in range(TILE_PX):
			if rng.randf() < 0.35:
				im.set_pixel(x, y, Color(0.5, 0.47, 0.45).lerp(im.get_pixel(x, y), 0.4))
	return im


func _cracks(p: Dictionary, rng: RandomNumberGenerator) -> Array[Image]:
	var im: Image = _rock_floor(p, rng, 1)
	var gl: Image = _img(Color(0, 0, 0))
	for c: int in range(2):
		var x: int = rng.randi_range(0, TILE_PX - 1)
		var y: int = 0 if c == 0 else rng.randi_range(0, TILE_PX - 1)
		for s: int in range(TILE_PX + 4):
			var hot: Color = p["glow"] if s % 3 != 0 else Color(1.0, 0.8, 0.3)
			im.set_pixel(x, y, hot)
			gl.set_pixel(x, y, hot * 0.8)
			if x + 1 < TILE_PX:
				im.set_pixel(x + 1, y, p["dark"])
			if c == 0:
				y += 1
				x = clampi(x + rng.randi_range(-1, 1), 0, TILE_PX - 1)
			else:
				x += 1
				y = clampi(y + rng.randi_range(-1, 1), 0, TILE_PX - 1)
			if x >= TILE_PX or y >= TILE_PX:
				break
	return [im, gl]


func _lava(p: Dictionary, rng: RandomNumberGenerator) -> Array[Image]:
	var im: Image = _img(p["glow"])
	var gl: Image = _img(Color(0, 0, 0))
	var ph: float = rng.randf() * TAU
	for y: int in range(TILE_PX):
		for x: int in range(TILE_PX):
			var v: float = sin(float(x) * 0.7 + sin(float(y) * 0.5 + ph) * 2.0) + rng.randf_range(-0.3, 0.3)
			var c: Color = Color(1.0, 0.82, 0.32) if v > 0.6 else (p["glow"] if v > -0.5 else Color(0.55, 0.12, 0.04))
			im.set_pixel(x, y, c)
			gl.set_pixel(x, y, c * (0.9 if v > -0.5 else 0.35))
	return [im, gl]


func _rock_wall(p: Dictionary, rng: RandomNumberGenerator) -> Image:
	var im: Image = _img(p["wall"])
	var y: int = 0
	var band: int = 0
	while y < TILE_PX:
		var h: int = rng.randi_range(2, 4)
		var c: Color = _shade(p["wall"], 0.05 if band % 2 == 0 else -0.04)
		for yy: int in range(y, mini(y + h, TILE_PX)):
			for x: int in range(TILE_PX):
				im.set_pixel(x, yy, c)
		if y > 0:
			for x: int in range(TILE_PX):
				if rng.randf() < 0.7:
					im.set_pixel(x, y, _shade(p["wall"], -0.09))
		y += h
		band += 1
	_speckle(im, rng, 0.05, 0.5)
	for x: int in range(TILE_PX):
		im.set_pixel(x, 0, p["top"])
	return im


func _rock_top(p: Dictionary, rng: RandomNumberGenerator) -> Image:
	var im: Image = _img(p["top"])
	_speckle(im, rng, 0.06, 0.7)
	for i: int in range(5):
		var x: int = rng.randi_range(1, TILE_PX - 3)
		var y: int = rng.randi_range(1, TILE_PX - 3)
		im.set_pixel(x, y, _shade(p["top"], 0.1))
		im.set_pixel(x + 1, y, _shade(p["top"], 0.06))
		im.set_pixel(x + 1, y + 1, _shade(p["top"], -0.1))
	return im


func _lava_seep(p: Dictionary, rng: RandomNumberGenerator, base: Image) -> Array[Image]:
	var im: Image = base.duplicate() as Image
	var gl: Image = _img(Color(0, 0, 0))
	var x: int = rng.randi_range(4, TILE_PX - 5)
	for y: int in range(2, TILE_PX):
		im.set_pixel(x, y, p["glow"])
		gl.set_pixel(x, y, p["glow"])
		if y > 9:
			im.set_pixel(x + 1, y, Color(1.0, 0.8, 0.3))
			gl.set_pixel(x + 1, y, Color(1.0, 0.7, 0.3))
		x = clampi(x + rng.randi_range(-1, 1), 1, TILE_PX - 2)
	return [im, gl]


# --- UI theme ---------------------------------------------------------------------------

func _build_theme() -> void:
	theme = Theme.new()
	if font != null:
		theme.default_font = font
	theme.default_font_size = 8
	var panel: StyleBoxFlat = StyleBoxFlat.new()
	panel.bg_color = Color(0.05, 0.08, 0.22, 0.95)
	panel.border_color = Color(0.8, 0.84, 0.96)
	panel.set_border_width_all(2)
	panel.set_content_margin_all(8)
	panel.shadow_color = Color(0, 0, 0, 0.5)
	panel.shadow_size = 0
	panel.shadow_offset = Vector2(3, 3)
	theme.set_stylebox("panel", "PanelContainer", panel)
	theme.set_stylebox("panel", "Panel", panel)
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = Color(0, 0, 0, 0)
	normal.content_margin_left = 6
	normal.content_margin_right = 6
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4
	var hi: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	hi.bg_color = Color(0.22, 0.32, 0.72)
	hi.border_color = Color(1.0, 0.85, 0.3)
	hi.border_width_left = 2
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hi)
	theme.set_stylebox("pressed", "Button", hi)
	theme.set_stylebox("focus", "Button", hi)
	theme.set_stylebox("hover_pressed", "Button", hi)
	theme.set_stylebox("disabled", "Button", normal)
	theme.set_color("font_color", "Button", Color(0.9, 0.92, 1.0))
	theme.set_color("font_hover_color", "Button", Color(1, 1, 1))
	theme.set_color("font_focus_color", "Button", Color(1, 1, 1))
	theme.set_color("font_pressed_color", "Button", Color(1, 1, 0.8))
	theme.set_color("font_hover_pressed_color", "Button", Color(1, 1, 0.8))
	theme.set_color("font_disabled_color", "Button", Color(0.5, 0.52, 0.6))
	theme.set_color("font_color", "Label", Color(0.92, 0.94, 1.0))
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.8))
	theme.set_constant("shadow_offset_x", "Label", 1)
	theme.set_constant("shadow_offset_y", "Label", 1)
	theme.set_constant("line_spacing", "Label", 3)
	theme.set_constant("separation", "VBoxContainer", 2)
	theme.set_constant("separation", "HBoxContainer", 6)
