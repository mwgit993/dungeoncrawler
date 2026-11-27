class_name Hud
extends CanvasLayer

## Everything drawn over the world, in the 640x360 pixel space: player panels, scrap, objective,
## boss bar, HP bars over hurt robots, prompts and toasts, plus the menus (stations, mission
## table, pause, results), which are real Buttons so mouse, keyboard and controller all work.

const MENU_W: int = 340
const ROW_CHARS: int = 36

var main: Main
var _overlay: Control
var _font: Font
var _toast: String = ""
var _toast_sub: String = ""
var _toast_t: float = 0.0
var _toast_col: Color = Color.WHITE
var _prompt: String = ""
var _fade: ColorRect

var _menu: PanelContainer
var _menu_title: Label
var _menu_list: VBoxContainer
var _menu_desc: Label
var _menu_footer: Label
var _menu_entries: Array[Dictionary] = []
var _menu_cb: Callable = Callable()
var menu_kind: String = ""


func setup(m: Main) -> void:
	main = m
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = Art.font if Art.font != null else ThemeDB.fallback_font
	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Art.theme
	add_child(root)
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	root.add_child(_overlay)
	_build_menu(root)
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_fade)


func _process(delta: float) -> void:
	_toast_t = maxf(_toast_t - delta, 0.0)
	_overlay.queue_redraw()


func toast(text: String, sub: String = "", color: Color = Color(1.0, 0.9, 0.5), time: float = 3.2) -> void:
	_toast = text
	_toast_sub = sub
	_toast_col = color
	_toast_t = time


func set_prompt(text: String) -> void:
	_prompt = text


func fade_to(alpha: float, time: float) -> Tween:
	var tw: Tween = create_tween()
	tw.tween_property(_fade, "color:a", alpha, time)
	return tw


func set_fade(alpha: float) -> void:
	_fade.color.a = alpha


# --- Overlay drawing --------------------------------------------------------------------

func _text(pos: Vector2, text: String, color: Color, size: int = 8, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	_overlay.draw_string(_font, pos + Vector2(1, 1), text, align, width, size, Color(0, 0, 0, 0.85 * color.a))
	_overlay.draw_string(_font, pos, text, align, width, size, color)


func _bar(rect: Rect2, frac: float, fill: Color, back: Color = Color(0.08, 0.08, 0.12, 0.9)) -> void:
	_overlay.draw_rect(rect.grow(1.0), Color(0, 0, 0, 0.9))
	_overlay.draw_rect(rect, back)
	if frac > 0.0:
		_overlay.draw_rect(Rect2(rect.position, Vector2(maxf(1.0, rect.size.x * clampf(frac, 0.0, 1.0)), rect.size.y)), fill)


func _draw_overlay() -> void:
	if main == null or main.level == null:
		return
	var lvl: LevelMap = main.level
	var cam: Camera3D = main.camera
	# Hurt robots get a small HP bar for a few seconds.
	if cam != null:
		for e: RobotEnemy in lvl.enemies:
			if not e.alive or e.is_boss or e.hit_recent > 3.0 or cam.is_position_behind(e.global_position):
				continue
			var sp: Vector2 = cam.unproject_position(e.global_position + Vector3(0.0, 1.6 + e.radius, 0.0))
			_bar(Rect2(sp + Vector2(-11, 0), Vector2(22, 2)), e.hp / e.max_hp, Color(1.0, 0.3, 0.25))
		# Co-op tags over each bot.
		if main.players.size() > 1:
			for p: GorillaBot in main.players:
				var tp: Vector2 = cam.unproject_position(p.global_position + Vector3(0.0, 2.6, 0.0))
				var label: String = "P%d" % (p.slot + 1) if p.alive else "P%d %d" % [p.slot + 1, int(ceil(p.respawn_left))]
				_text(tp + Vector2(-20, 0), label, p.color, 8, HORIZONTAL_ALIGNMENT_CENTER, 40)
	# Top left: where we are and what to do.
	_text(Vector2(8, 14), String(lvl.def.get("name", "")), Color(1.0, 0.92, 0.6))
	var obj: String = main.objective_text()
	if obj != "":
		_text(Vector2(8, 26), obj, Color(0.8, 0.85, 0.95))
	# Top right: scrap.
	var scrap_txt: String = "SCRAP %d" % Game.scrap
	_overlay.draw_rect(Rect2(640 - 16 - scrap_txt.length() * 8 - 12, 7, 8, 8), Color(1.0, 0.8, 0.3))
	_overlay.draw_rect(Rect2(640 - 16 - scrap_txt.length() * 8 - 10, 9, 4, 4), Color(0.3, 0.22, 0.1))
	_text(Vector2(0, 14), scrap_txt, Color(1.0, 0.85, 0.4), 8, HORIZONTAL_ALIGNMENT_RIGHT, 632)
	if not lvl.is_hub:
		_text(Vector2(0, 26), "THREAT %d" % lvl.tier, Color(1.0, 0.5, 0.4), 8, HORIZONTAL_ALIGNMENT_RIGHT, 632)
	# Boss bar.
	var b: RobotEnemy = lvl.boss
	if b != null and is_instance_valid(b) and b.alive and b.awake:
		_text(Vector2(0, 46), b.display_name, Color(1.0, 0.45, 0.35), 8, HORIZONTAL_ALIGNMENT_CENTER, 640)
		_bar(Rect2(190, 52, 260, 6), b.hp / b.max_hp, Color(0.95, 0.25, 0.2) if b.phase == 1 else Color(1.0, 0.55, 0.1))
	# Player panels along the bottom.
	for p2: GorillaBot in main.players:
		_draw_player_panel(p2)
	# Prompt and toast.
	if _prompt != "" and not is_menu_open():
		var w: float = float(_prompt.length() * 8 + 16)
		_overlay.draw_rect(Rect2(320.0 - w * 0.5, 298, w, 16), Color(0.03, 0.05, 0.15, 0.85))
		_overlay.draw_rect(Rect2(320.0 - w * 0.5, 298, w, 16), Color(0.8, 0.84, 0.96), false, 1.0)
		_text(Vector2(0, 310), _prompt, Color(1, 1, 1), 8, HORIZONTAL_ALIGNMENT_CENTER, 640)
	if _toast_t > 0.0:
		var a: float = clampf(_toast_t / 0.5, 0.0, 1.0)
		_text(Vector2(0, 92), _toast, Color(_toast_col.r, _toast_col.g, _toast_col.b, a), 16, HORIZONTAL_ALIGNMENT_CENTER, 640)
		if _toast_sub != "":
			_text(Vector2(0, 108), _toast_sub, Color(0.9, 0.92, 1.0, a), 8, HORIZONTAL_ALIGNMENT_CENTER, 640)
	if lvl.is_hub and main.players.size() < 4 and not is_menu_open():
		_text(Vector2(0, 352), "EXTRA CONTROLLERS: PRESS START TO JOIN", Color(0.6, 0.65, 0.8, 0.8), 8, HORIZONTAL_ALIGNMENT_RIGHT, 632)


func _draw_player_panel(p: GorillaBot) -> void:
	var x: float = 8.0 + float(p.slot) * 132.0
	var y: float = 322.0 if not main.level.is_hub else 312.0
	_overlay.draw_rect(Rect2(x - 3, y - 11, 126, 34), Color(0.03, 0.05, 0.15, 0.75))
	_text(Vector2(x, y - 1), "P%d" % (p.slot + 1), p.color)
	if not p.alive:
		_text(Vector2(x + 24, y - 1), "DOWN" if main.players.size() == 1 else "REBOOT %d" % int(ceil(p.respawn_left)), Color(1.0, 0.4, 0.35))
	else:
		_text(Vector2(x + 24, y - 1), "%d/%d" % [int(ceil(p.hp)), int(p.max_hp)], Color(0.9, 0.95, 1.0))
	var hp_col: Color = Color(0.35, 0.95, 0.4) if p.hp > p.max_hp * 0.35 else Color(1.0, 0.3, 0.25)
	_bar(Rect2(x, y + 3, 116, 5), p.hp / p.max_hp, hp_col)
	if p.shield > 0.0:
		_overlay.draw_rect(Rect2(x, y + 3, 116.0 * clampf(p.shield / Balance.SHIELD_CELL_HP, 0.0, 1.0), 2), Color(0.4, 0.85, 1.0))
	_bar(Rect2(x, y + 11, 80, 3), p.energy / p.energy_max, Color(1.0, 0.65, 0.2))
	# Dash pip and kit count.
	var ready: bool = p.dash_ready() >= 1.0
	_overlay.draw_rect(Rect2(x + 86, y + 10, 5, 5), Color(0.4, 0.9, 1.0) if ready else Color(0.2, 0.25, 0.35))
	_overlay.draw_rect(Rect2(x + 97, y + 10, 5, 5), Color(0.3, 0.95, 0.45))
	_overlay.draw_rect(Rect2(x + 99, y + 10, 1, 5), Color(1, 1, 1))
	_overlay.draw_rect(Rect2(x + 97, y + 12, 5, 1), Color(1, 1, 1))
	_text(Vector2(x + 105, y + 16), str(Game.kits), Color(0.9, 1.0, 0.9))


# --- Menus ------------------------------------------------------------------------------

func _build_menu(root: Control) -> void:
	_menu = PanelContainer.new()
	_menu.custom_minimum_size = Vector2(MENU_W, 0)
	_menu.visible = false
	root.add_child(_menu)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_menu.add_child(box)
	_menu_title = Label.new()
	_menu_title.add_theme_font_size_override("font_size", 16)
	_menu_title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	_menu_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_menu_title)
	_menu_list = VBoxContainer.new()
	_menu_list.add_theme_constant_override("separation", 1)
	box.add_child(_menu_list)
	_menu_desc = Label.new()
	_menu_desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	_menu_desc.custom_minimum_size = Vector2(MENU_W - 20, 28)
	_menu_desc.add_theme_color_override("font_color", Color(0.75, 0.82, 1.0))
	box.add_child(_menu_desc)
	_menu_footer = Label.new()
	_menu_footer.add_theme_color_override("font_color", Color(0.6, 0.65, 0.8))
	box.add_child(_menu_footer)


## entries: [{id, label, right, desc, enabled}]. cb(id) runs when one is chosen.
func open_menu(kind: String, title: String, entries: Array[Dictionary], cb: Callable, footer: String = "") -> void:
	menu_kind = kind
	_menu_cb = cb
	_toast_t = 0.0
	_menu_title.text = title
	_menu_footer.text = footer
	_menu.visible = true
	_fill_menu(entries, 0)
	Sfx.play("ui", -10.0)


func refresh_menu(entries: Array[Dictionary], footer: String = "") -> void:
	var focus_i: int = 0
	for i: int in range(_menu_list.get_child_count()):
		var b: Control = _menu_list.get_child(i) as Control
		if b != null and b.has_focus():
			focus_i = i
	if footer != "":
		_menu_footer.text = footer
	_fill_menu(entries, focus_i)


func _fill_menu(entries: Array[Dictionary], focus_i: int) -> void:
	_menu_entries = entries
	for c: Node in _menu_list.get_children():
		_menu_list.remove_child(c)
		c.queue_free()
	var first: Button = null
	var want: Button = null
	for i: int in range(entries.size()):
		var e: Dictionary = entries[i]
		var b: Button = Button.new()
		var label: String = String(e.get("label", ""))
		var right: String = String(e.get("right", ""))
		b.text = label + right.lpad(maxi(ROW_CHARS - label.length(), right.length() + 1))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = not bool(e.get("enabled", true))
		b.focus_mode = Control.FOCUS_ALL
		var id: String = String(e.get("id", ""))
		var desc: String = String(e.get("desc", ""))
		b.pressed.connect(_on_pick.bind(id))
		b.focus_entered.connect(_on_focus.bind(desc))
		b.mouse_entered.connect(b.grab_focus)
		_menu_list.add_child(b)
		if first == null:
			first = b
		if i == focus_i:
			want = b
	# Disabled rows still take focus so their description (e.g. what unlocks them) can be read.
	var target: Button = want if want != null else first
	_menu.reset_size()
	_menu.position = (Vector2(640, 360) - _menu.get_combined_minimum_size()) * 0.5
	if target != null:
		_focus_later.call_deferred(target)
		_on_focus(String(entries[clampi(focus_i, 0, entries.size() - 1)].get("desc", "")))


func _focus_later(b: Button) -> void:
	if is_instance_valid(b) and b.is_inside_tree() and b.visible:
		b.grab_focus()


func _on_focus(desc: String) -> void:
	_menu_desc.text = desc


func _on_pick(id: String) -> void:
	if _menu_cb.is_valid():
		_menu_cb.call(id)


func close_menu() -> void:
	_menu.visible = false
	menu_kind = ""
	_menu_cb = Callable()
	for c: Node in _menu_list.get_children():
		_menu_list.remove_child(c)
		c.queue_free()


func is_menu_open() -> bool:
	return _menu.visible


func menu_button_count() -> int:
	return _menu_list.get_child_count()


## Presses the menu row with this id (smoke test).
func press(id: String) -> void:
	_on_pick(id)
