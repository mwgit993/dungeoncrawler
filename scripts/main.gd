class_name Main
extends Node

## Runs the game loop: the ship hub, deploying to a mission, extraction or failure, and back.
## Owns the world (current LevelMap, the player bots, the camera), the HUD and its menus,
## drop-in co-op (extra controllers press START), pausing, and the headless smoke test.
##
## Loop: the Ark (hub) -> mission table -> map -> destroy the boss -> extraction pad -> results
## -> back on the Ark to spend scrap at the stations. Clearing a map unlocks the next map and a
## station, and raises that map's threat tier for the next run.

var world: Node3D
var players_root: Node3D
var camera: CameraRig
var hud: Hud
var level: LevelMap = null
var players: Array[GorillaBot] = []
var mode: String = "hub"     # hub, mission, results
var mission_id: String = ""
var mission_scrap: int = 0
var mission_kills: int = 0
var mission_time: float = 0.0
var paused: bool = false
var _fail_t: float = -1.0
var _busy: bool = false
var _pad_start_prev: Dictionary = {}
var _smoke: bool = false
var _smoke_fail: Array[String] = []


func _ready() -> void:
	_smoke = "--smoke-test" in OS.get_cmdline_user_args()
	if _smoke:
		Game.use_smoke_save()
	world = Node3D.new()
	world.name = "World"
	add_child(world)
	players_root = Node3D.new()
	players_root.name = "Players"
	world.add_child(players_root)
	camera = CameraRig.new()
	camera.name = "Camera"
	world.add_child(camera)
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.setup(self)
	add_player(true, 0)
	if _smoke:
		_run_smoke_test.call_deferred()
		return
	go_hub(true)


# --- Players ----------------------------------------------------------------------------

func add_player(uses_kbm: bool, pad_id: int) -> GorillaBot:
	var p: GorillaBot = GorillaBot.new()
	p.setup(level, players.size(), uses_kbm, pad_id)
	players_root.add_child(p)
	players.append(p)
	p.died.connect(_on_player_died)
	camera.targets = players
	if level != null:
		var anchor: Vector3 = level.start_pos
		for other: GorillaBot in players:
			if other != p and other.alive:
				anchor = other.global_position
				break
		p.move_level(level, _free_spot_near(anchor, players.size() - 1))
		level.set_player_count(players.size())
		hud.toast("PLAYER %d JOINED" % players.size(), "Enemies scale up for %d bots" % players.size(), p.color, 2.5)
		Sfx.play("unlock", -8.0)
	return p


func _free_spot_near(anchor: Vector3, index: int) -> Vector3:
	var offsets: Array[Vector3] = [Vector3.ZERO, Vector3(1.2, 0, 0), Vector3(0, 0, 1.2), Vector3(1.2, 0, 1.2),
		Vector3(-1.2, 0, 0), Vector3(0, 0, -1.2)]
	for i: int in range(offsets.size()):
		var o: Vector3 = offsets[(index + i) % offsets.size()]
		if level.walkable(LevelMap.to_cell(anchor + o)):
			return anchor + o
	return anchor


func _pad_taken(pad_id: int) -> bool:
	for p: GorillaBot in players:
		if p.pad == pad_id:
			return true
	return false


func _poll_joins() -> void:
	for id: int in Input.get_connected_joypads():
		var now: bool = Input.is_joy_button_pressed(id, JOY_BUTTON_START)
		var was: bool = bool(_pad_start_prev.get(id, false))
		_pad_start_prev[id] = now
		if now and not was and not _pad_taken(id) and players.size() < 4 and mode != "results" and not paused and not _busy:
			add_player(false, id)


func _set_players_input(on: bool) -> void:
	for p: GorillaBot in players:
		p.input_enabled = on


func _on_player_died(p: GorillaBot) -> void:
	p.respawn_left = Balance.RESPAWN_TIME


# --- Levels -----------------------------------------------------------------------------

func _load_level(def: Dictionary, tier: int) -> void:
	if level != null:
		world.remove_child(level)
		level.queue_free()
	level = LevelMap.new()
	level.build(def, tier, players.size())
	world.add_child(level)
	level.players = players
	level.scrap_collected.connect(_on_scrap)
	level.enemy_died.connect(_on_enemy_died)
	level.boss_woke.connect(_on_boss_woke)
	level.boss_died.connect(_on_boss_died)
	level.shake_requested.connect(camera.add_shake)
	for i: int in range(players.size()):
		var p: GorillaBot = players[i]
		p.move_level(level, _free_spot_near(level.start_pos, i))
		p.reset_stats()
		p.respawn_left = 0.0
	camera.targets = players
	camera.snap_to(level.start_pos)
	hud.set_prompt("")


## Fades out, runs `change`, fades back in. Instant in the smoke test.
func _transition(change: Callable) -> void:
	if _smoke:
		change.call()
		return
	if _busy:
		return
	_busy = true
	_set_players_input(false)
	await hud.fade_to(1.0, 0.3).finished
	change.call()
	await get_tree().process_frame
	_set_players_input(true)
	await hud.fade_to(0.0, 0.35).finished
	_busy = false


func go_hub(first: bool = false) -> void:
	mode = "hub"
	mission_id = ""
	_fail_t = -1.0
	_load_level(Maps.HUB, 1)
	_refresh_stations()
	if first:
		hud.set_fade(1.0)
		hud.fade_to(0.0, 0.6)
		hud.toast("DUNGEON CRAWLER", "Walk to the MISSION TABLE to deploy", Color(1.0, 0.85, 0.4), 4.0)
	var news: Array[String] = Game.take_new_unlocks()
	if not news.is_empty():
		var names: PackedStringArray = PackedStringArray()
		for id: String in news:
			if Station.TITLES.has(id):
				names.append(String(Station.TITLES[id]))
			else:
				names.append(String(Maps.mission(id).get("name", id)))
		hud.toast("UNLOCKED!", " + ".join(names), Color(0.5, 1.0, 0.6), 4.5)
		Sfx.play("unlock", -4.0)
	Game.save_game()


func _refresh_stations() -> void:
	for st: Station in level.stations:
		st.set_unlocked(Game.station_unlocked(st.station_id))


func start_mission(id: String) -> void:
	if not Game.mission_unlocked(id):
		Sfx.play("cant", -6.0)
		return
	var def: Dictionary = Maps.mission(id)
	if def.is_empty():
		return
	mode = "mission"
	mission_id = id
	mission_scrap = 0
	mission_kills = 0
	mission_time = 0.0
	_fail_t = -1.0
	_load_level(def, Game.mission_tier(id))
	if Game.shield_cell:
		for p: GorillaBot in players:
			p.shield = Balance.SHIELD_CELL_HP
		Game.shield_cell = false
	Game.save_game()
	Sfx.play("warp", -6.0)
	hud.toast(String(def["name"]), String(def["subtitle"]), Color(1.0, 0.85, 0.4), 3.5)


func objective_text() -> String:
	if level == null:
		return ""
	if level.is_hub:
		return "DEPLOY FROM THE MISSION TABLE"
	if level.exit_active:
		return "GET TO THE EXTRACTION PAD"
	if level.boss != null:
		return "DESTROY %s" % level.boss.display_name
	return ""


# --- Frame update -----------------------------------------------------------------------

func _process(delta: float) -> void:
	_poll_joins()
	if level == null or paused or _busy:
		return
	if hud.is_menu_open():
		hud.set_prompt("")
		return
	for p: GorillaBot in players:
		if p.pause_pressed:
			open_pause()
			return
	match mode:
		"hub":
			_update_hub()
		"mission":
			_update_mission(minf(delta, 0.1))


func _update_hub() -> void:
	var best: Station = null
	var who: GorillaBot = null
	var best_d: float = Station.INTERACT_RANGE
	for p: GorillaBot in players:
		for st: Station in level.stations:
			var d: float = p.global_position.distance_to(st.global_position)
			if d < best_d:
				best_d = d
				best = st
				who = p
	if best == null:
		hud.set_prompt("")
		return
	var key: String = "Y" if who.using_pad else "E"
	hud.set_prompt("%s  %s" % [key, best.title()] if best.unlocked else "%s  %s (LOCKED)" % [key, best.title()])
	for p2: GorillaBot in players:
		if p2.interact_pressed and p2.global_position.distance_to(best.global_position) < Station.INTERACT_RANGE + 0.5:
			use_station(best)
			return


func use_station(st: Station) -> void:
	if not st.unlocked:
		var req: String = String(Balance.STATION_UNLOCK.get(st.station_id, ""))
		hud.toast("LOCKED", "Clear %s to open the %s" % [String(Maps.mission(req).get("name", req)), st.title()], Color(1.0, 0.45, 0.4), 2.5)
		Sfx.play("cant", -6.0)
		return
	open_station_menu(st.station_id)


func _update_mission(dt: float) -> void:
	mission_time += dt
	hud.set_prompt("")
	var alive: Array[GorillaBot] = level.alive_players()
	for p: GorillaBot in players:
		if p.alive or alive.is_empty() or players.size() == 1:
			continue
		p.respawn_left -= dt
		if p.respawn_left <= 0.0:
			var buddy: GorillaBot = alive[randi() % alive.size()]
			p.revive(_free_spot_near(buddy.global_position, p.slot))
	if alive.is_empty():
		if _fail_t < 0.0:
			_fail_t = 2.0
		_fail_t -= dt
		if _fail_t <= 0.0:
			mission_failed(false)
		return
	if level.exit_active:
		for p2: GorillaBot in alive:
			if p2.global_position.distance_to(level.exit_pos) < 1.7:
				mission_complete()
				return


func mission_complete() -> void:
	mode = "results"
	Game.clears[mission_id] = Game.clear_count(mission_id) + 1
	Game.save_game()
	_set_players_input(false)
	Sfx.play("unlock", -4.0)
	var mins: int = int(mission_time) / 60
	var secs: int = int(mission_time) % 60
	var desc: String = "SCRAP +%d   ROBOTS %d   TIME %d:%02d\nNext run here: THREAT %d" % [
		mission_scrap, mission_kills, mins, secs, Game.mission_tier(mission_id)]
	var entries: Array[Dictionary] = [{"id": "ok", "label": "RETURN TO THE ARK", "desc": desc}]
	hud.open_menu("results", "MISSION COMPLETE", entries, _on_results_pick)


func mission_failed(abandoned: bool) -> void:
	mode = "results"
	var kept: int = int(round(float(mission_scrap) * Balance.FAIL_SCRAP_KEPT))
	Game.add_scrap(-(mission_scrap - kept))
	Game.save_game()
	_set_players_input(false)
	Sfx.play("die", -4.0)
	var desc: String = "Salvage recovered: %d of %d scrap.\nROBOTS %d" % [kept, mission_scrap, mission_kills]
	var entries: Array[Dictionary] = [{"id": "ok", "label": "RETURN TO THE ARK", "desc": desc}]
	hud.open_menu("results", "MISSION ABANDONED" if abandoned else "BOTS DESTROYED", entries, _on_results_pick)


func _on_results_pick(_id: String) -> void:
	hud.close_menu()
	paused = false
	world.process_mode = Node.PROCESS_MODE_INHERIT
	_transition(_back_to_hub)


func _back_to_hub() -> void:
	go_hub(false)
	_set_players_input(true)


func _on_scrap(amount: int) -> void:
	Game.add_scrap(amount)
	if mode == "mission":
		mission_scrap += amount


func _on_enemy_died(_e: RobotEnemy) -> void:
	mission_kills += 1


func _on_boss_woke(e: RobotEnemy) -> void:
	hud.toast("WARNING", e.display_name + " IS ONLINE", Color(1.0, 0.35, 0.3), 2.5)


func _on_boss_died(e: RobotEnemy) -> void:
	hud.toast("%s DESTROYED" % e.display_name, "The extraction pad is powering up", Color(0.5, 1.0, 0.9), 4.0)


# --- Menus ------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_F11:
		Game.toggle_fullscreen()
		return
	if hud.is_menu_open():
		if event.is_action_pressed("ui_cancel") and hud.menu_kind != "results":
			close_menus()
			get_viewport().set_input_as_handled()
		return
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		open_pause()
		get_viewport().set_input_as_handled()


func close_menus() -> void:
	hud.close_menu()
	paused = false
	world.process_mode = Node.PROCESS_MODE_INHERIT
	_set_players_input(true)
	Sfx.play("ui", -12.0)


func _footer() -> String:
	return "SCRAP %d          ESC / B: BACK" % Game.scrap


func open_station_menu(id: String) -> void:
	_set_players_input(false)
	match id:
		"quartermaster":
			hud.open_menu(id, "QUARTERMASTER", _shop_entries(), _on_shop_pick, _footer())
		"augments":
			hud.open_menu(id, "AUGMENT BAY", _aug_entries(), _on_aug_pick, _footer())
		"lab":
			hud.open_menu(id, "WEAPONS LAB", _lab_entries(), _on_lab_pick, _footer())
		"missions":
			hud.open_menu(id, "MISSION TABLE", _mission_entries(), _on_mission_pick, _footer())


func _shop_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in Balance.SHOP:
		var id: String = String(e["id"])
		var row: Dictionary = {"id": id, "label": String(e["name"]), "enabled": true}
		var desc: String = String(e["desc"])
		match id:
			"kit":
				desc = desc % int(Balance.KIT_HEAL) + " Carrying %d/%d." % [Game.kits, Game.kit_max()]
				row["right"] = "FULL" if Game.kits >= Game.kit_max() else str(Balance.price(e, 0))
				row["enabled"] = Game.kits < Game.kit_max()
			"kit_rack":
				var owned: int = Game.kit_racks
				var maxed: bool = owned >= int(e.get("max", 3))
				desc += " Level %d/%d." % [owned, int(e.get("max", 3))]
				row["right"] = "MAX" if maxed else str(Balance.price(e, owned))
				row["enabled"] = not maxed
			"shield":
				desc = desc % int(Balance.SHIELD_CELL_HP)
				row["right"] = "READY" if Game.shield_cell else str(Balance.price(e, 0))
				row["enabled"] = not Game.shield_cell
		row["desc"] = desc
		out.append(row)
	return out


func _aug_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in Balance.AUGMENTS:
		var id: String = String(e["id"])
		var lvl: int = Game.aug(id)
		var mx: int = int(e.get("max", 5))
		var maxed: bool = lvl >= mx
		var desc: String = String(e["desc"]) % int(e.get("per", 0)) + " Level %d/%d." % [lvl, mx]
		out.append({"id": id, "label": "%s %s" % [String(e["name"]), "*".repeat(lvl)],
			"right": "MAX" if maxed else str(Balance.price(e, lvl)), "desc": desc, "enabled": not maxed})
	return out


func _lab_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in Balance.LAB:
		var id: String = String(e["id"])
		var owned: bool = Game.has_mod(id)
		out.append({"id": id, "label": String(e["name"]), "right": "OWNED" if owned else str(Balance.price(e, 0)),
			"desc": String(e["desc"]), "enabled": not owned})
	return out


func _mission_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in Maps.MISSIONS:
		var id: String = String(m["id"])
		var open: bool = Game.mission_unlocked(id)
		var desc: String = String(m["subtitle"])
		if open:
			desc += " Cleared %d times." % Game.clear_count(id) if Game.clear_count(id) != 1 else " Cleared once."
		else:
			var req: String = String(Balance.MISSION_UNLOCK.get(id, ""))
			desc = "Clear %s to unlock." % String(Maps.mission(req).get("name", req))
		out.append({"id": id, "label": String(m["name"]), "right": "THREAT %d" % Game.mission_tier(id) if open else "LOCKED",
			"desc": desc, "enabled": open})
	return out


func _buy(cost: int) -> bool:
	if Game.spend(cost):
		Sfx.play("buy", -6.0)
		return true
	Sfx.play("cant", -6.0)
	return false


func _after_purchase(entries: Array[Dictionary]) -> void:
	Game.save_game()
	for p: GorillaBot in players:
		if level != null and level.is_hub:
			p.reset_stats()
	hud.refresh_menu(entries, _footer())


func _on_shop_pick(id: String) -> void:
	var e: Dictionary = _entry(Balance.SHOP, id)
	match id:
		"kit":
			if Game.kits < Game.kit_max() and _buy(Balance.price(e, 0)):
				Game.kits += 1
		"kit_rack":
			if Game.kit_racks < int(e.get("max", 3)) and _buy(Balance.price(e, Game.kit_racks)):
				Game.kit_racks += 1
		"shield":
			if not Game.shield_cell and _buy(Balance.price(e, 0)):
				Game.shield_cell = true
	_after_purchase(_shop_entries())


func _on_aug_pick(id: String) -> void:
	var e: Dictionary = _entry(Balance.AUGMENTS, id)
	var lvl: int = Game.aug(id)
	if lvl < int(e.get("max", 5)) and _buy(Balance.price(e, lvl)):
		Game.augments[id] = lvl + 1
	_after_purchase(_aug_entries())


func _on_lab_pick(id: String) -> void:
	var e: Dictionary = _entry(Balance.LAB, id)
	if not Game.has_mod(id) and _buy(Balance.price(e, 0)):
		Game.mods[id] = true
	_after_purchase(_lab_entries())


func _on_mission_pick(id: String) -> void:
	if not Game.mission_unlocked(id):
		Sfx.play("cant", -6.0)
		return
	hud.close_menu()
	if _smoke:
		start_mission(id)
		_set_players_input(true)
		return
	_transition(start_mission.bind(id))


func _entry(table: Array[Dictionary], id: String) -> Dictionary:
	for e: Dictionary in table:
		if String(e["id"]) == id:
			return e
	return {}


func open_pause() -> void:
	if mode == "results" or hud.is_menu_open() or _busy:
		return
	paused = true
	world.process_mode = Node.PROCESS_MODE_DISABLED
	_set_players_input(false)
	hud.open_menu("pause", "PAUSED", _pause_entries(), _on_pause_pick)


func _pause_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"id": "resume", "label": "RESUME", "desc": "Back to it."}]
	out.append({"id": "fullscreen", "label": "FULLSCREEN", "right": "ON" if Game.fullscreen else "OFF", "desc": "F11 also toggles it."})
	out.append({"id": "sfx", "label": "SOUND", "right": "%d%%" % int(round(Game.sfx_volume * 100.0)), "desc": "Sound effect volume."})
	if mode == "mission":
		out.append({"id": "abandon", "label": "ABANDON MISSION",
			"desc": "Return to the Ark, keeping %d%% of this run's scrap." % int(Balance.FAIL_SCRAP_KEPT * 100.0)})
	out.append({"id": "quit", "label": "QUIT GAME", "desc": "Progress is saved."})
	return out


func _on_pause_pick(id: String) -> void:
	match id:
		"resume":
			close_menus()
		"fullscreen":
			Game.toggle_fullscreen()
			hud.refresh_menu(_pause_entries())
		"sfx":
			Game.sfx_volume = 0.0 if Game.sfx_volume >= 0.99 else minf(Game.sfx_volume + 0.2, 1.0)
			Game.save_game()
			Sfx.play("ui", -6.0)
			hud.refresh_menu(_pause_entries())
		"abandon":
			hud.close_menu()
			paused = false
			world.process_mode = Node.PROCESS_MODE_INHERIT
			mission_failed(true)
		"quit":
			Game.save_game()
			get_tree().quit()


# --- Smoke test -------------------------------------------------------------------------
# Run: godot --headless --path . --quit-after 30 -- --smoke-test
# It drives the whole loop with direct calls and a fixed-step simulation (LevelMap.simulate),
# against its own save file, and prints DUNGEON_SMOKE_TEST_PASSED when everything holds.

func _check(ok: bool, what: String) -> void:
	if not ok:
		_smoke_fail.append(what)
		push_error("SMOKE CHECK FAILED: " + what)


func _station(id: String) -> Station:
	for st: Station in level.stations:
		if st.station_id == id:
			return st
	return null


func _run_smoke_test() -> void:
	var p1: GorillaBot = players[0]
	p1.scripted = true
	_smoke_check_maps()
	_smoke_hub(p1)
	_smoke_rigs(p1)
	_smoke_foundry(p1)
	_smoke_upgrades(p1)
	_smoke_ashfall(p1)
	_smoke_mods(p1)
	_smoke_coop(p1)
	_smoke_save_and_pause()
	# A couple of real frames so every draw/process path runs once.
	for i: int in range(3):
		await get_tree().process_frame
	if _smoke_fail.is_empty():
		print("DUNGEON_SMOKE_TEST_PASSED")
		get_tree().quit(0)
	else:
		push_error("Smoke test failed %d check(s)" % _smoke_fail.size())
		get_tree().quit(1)


func _smoke_check_maps() -> void:
	var legend: String = "#w.,=~otc$+PXsgbBQALM"
	var all_maps: Array[Dictionary] = [Maps.HUB]
	all_maps.append_array(Maps.MISSIONS)
	for m: Dictionary in all_maps:
		var rows: Array = m["rows"]
		var width: int = String(rows[0]).length()
		var starts: int = 0
		var bosses: int = 0
		var exits: int = 0
		for r: Variant in rows:
			var line: String = String(r)
			_check(line.length() == width, "%s: every row is %d wide" % [m["id"], width])
			for c: String in line:
				_check(legend.contains(c), "%s: unknown map character '%s'" % [m["id"], c])
			starts += line.count("P")
			bosses += line.count("B")
			exits += line.count("X")
		_check(starts == 1, "%s has exactly one P" % m["id"])
		if String(m["id"]) != "hub":
			_check(bosses == 1 and exits == 1, "%s has one boss and one extraction pad" % m["id"])
			_check(Balance.ENEMIES.has(String(m["boss"])), "%s boss exists in Balance" % m["id"])
			_check(Balance.MISSION_TIER.has(String(m["id"])) and Balance.MISSION_UNLOCK.has(String(m["id"])), "%s has a tier and unlock rule" % m["id"])


## Every character model builds, uses the outlined character material, stands about as tall as
## it should, flashes when hit and plays its attack animations.
func _smoke_rigs(p1: GorillaBot) -> void:
	var dt: float = 1.0 / 60.0
	var g: GorillaRig = p1.rig
	_check(g != null and g.sculpted_parts() >= 8, "gorilla rig has its sculpted parts")
	_check(g.visual_height() > 1.6 and g.visual_height() < 2.6, "gorilla rig is about 2 m tall (%.2f)" % g.visual_height())
	g.hurt(Vector3.RIGHT)
	_check(g.flashing(), "gorilla rig flashes when hurt")
	g.slam()
	var squashed: bool = false
	for i: int in range(40):
		g.animate(dt, Vector3.ZERO, Vector3.FORWARD, 1.0)
		squashed = squashed or g.root.scale.y < 0.97
	_check(squashed and not g.flashing(), "gorilla slam squashes the body and the flash fades")
	g.punch(0)
	g.fire()
	g.dash()
	for i2: int in range(30):
		g.animate(dt, Vector3(4.0, 0.0, 2.0), Vector3.RIGHT, 0.5)
	g.knock_down()
	for i3: int in range(30):
		g.animate_down(dt)
	g.revive()
	g.animate(dt, Vector3.ZERO, Vector3.FORWARD, 1.0)
	var heights: Dictionary = {"scuttler": [0.4, 1.0], "gunner": [1.2, 2.0], "bruiser": [1.7, 2.6],
		"foreman": [2.4, 3.6], "warden": [2.6, 3.8]}
	var strikes: Dictionary = {"scuttler": "bite", "gunner": "burst", "bruiser": "slam", "foreman": "slam", "warden": "nova"}
	for kind: String in Balance.ENEMIES.keys():
		_check(heights.has(kind) and strikes.has(kind), "%s has rig checks in _smoke_rigs" % kind)
		var e: RobotEnemy = level.spawn_enemy(kind, p1.global_position + Vector3(40.0, 0.0, 40.0), false)
		e.awake = true  # so the test hit below doesn't wake it (a boss would raise the HUD warning)
		var r: EnemyRig = e.rig
		_check(r != null and r.sculpted_parts() >= 1, "%s rig has sculpted parts" % kind)
		var hgt: Array = heights.get(kind, [0.0, 99.0])
		_check(r.visual_height() > float(hgt[0]) and r.visual_height() < float(hgt[1]), "%s rig height %.2f" % [kind, r.visual_height()])
		e.take_damage(1.0, Vector3.RIGHT, 0.0)
		_check(r.flashing(), "%s flashes when hit" % kind)
		var act: String = String(strikes.get(kind, "slam"))
		for i4: int in range(20):
			r.animate(dt, 1.0, RobotEnemy.State.CHASE, 0.0, "", 2, false)
			r.animate(dt, 0.0, RobotEnemy.State.WINDUP, float(i4) / 20.0, act, 2, true)
		r.shot()
		r.animate(dt, 0.0, RobotEnemy.State.RECOVER, 0.0, act, 2, false)
		_check(r.striking() == act, "%s plays its %s strike" % [kind, act])
		for i5: int in range(40):
			r.animate(dt, 0.0, RobotEnemy.State.SLEEP, 0.0, "", 1, false)
		_check(not r.flashing() and r.striking() == "", "%s settles after the strike" % kind)
		level.enemies.erase(e)
		e.queue_free()


func _smoke_hub(p1: GorillaBot) -> void:
	go_hub(true)
	_check(level != null and level.is_hub, "hub loads")
	_check(level.stations.size() == 4, "hub has 4 stations")
	_check(_station("missions").unlocked and _station("quartermaster").unlocked, "mission table and vendor open at start")
	_check(not _station("augments").unlocked and not _station("lab").unlocked, "augmenters start locked")
	_check(level.walkable(LevelMap.to_cell(p1.global_position)), "player starts on a walkable tile")
	# Walk up to the quartermaster and interact.
	var qm: Station = _station("quartermaster")
	p1.global_position = qm.global_position + qm.global_transform.basis.z * 1.8
	p1.interact_pressed = true
	_update_hub()
	_check(hud.is_menu_open() and hud.menu_kind == "quartermaster", "interacting opens the quartermaster")
	Game.scrap = 0
	hud.press("kit")
	_check(Game.kits == 2 and Game.scrap == 0, "can't buy without scrap")
	Game.scrap = 1000
	hud.press("kit")
	_check(Game.kits == 3, "buy a repair kit")
	hud.press("kit")
	_check(Game.kits == 3, "kit rack is full at 3")
	hud.press("kit_rack")
	_check(Game.kit_racks == 1 and Game.kit_max() == 4, "kit rack adds capacity")
	hud.press("shield")
	_check(Game.shield_cell, "shield cell bought")
	close_menus()
	_check(not hud.is_menu_open() and p1.input_enabled, "menu closes and input returns")
	# Locked station refuses.
	var aug: Station = _station("augments")
	p1.global_position = aug.global_position + aug.global_transform.basis.z * 1.8
	p1.interact_pressed = true
	_update_hub()
	_check(not hud.is_menu_open(), "locked augment bay doesn't open")
	# Mission table: Ashfall locked, Foundry deploys.
	open_station_menu("missions")
	_check(hud.menu_button_count() == Maps.MISSIONS.size(), "mission table lists every mission")
	hud.press("ashfall")
	_check(mode == "hub", "locked mission can't be started")
	hud.press("foundry")
	_check(mode == "mission" and level.id == "foundry", "foundry deploys from the mission table")


func _count_chars(chars: String) -> int:
	var n: int = 0
	for r: String in level.rows:
		for c: String in r:
			if chars.contains(c):
				n += 1
	return n


func _smoke_foundry(p1: GorillaBot) -> void:
	_check(p1.shield == Balance.SHIELD_CELL_HP and not Game.shield_cell, "shield cell applies once")
	_check(level.enemies.size() == _count_chars("sgbB"), "every enemy on the map spawns")
	_check(level.props.size() == _count_chars("c$"), "every crate and cache spawns")
	_check(level.boss != null and level.boss.kind == "foreman", "foundry boss is the foreman")
	_check(level.has_exit and not level.exit_active, "extraction pad starts powered down")
	_check(level.find_path(level.start_pos, level.boss.global_position).size() > 0, "boss is reachable from the start")
	var east: Vector3 = Vector3(1.0, 0.0, 0.0)
	var base: Vector3 = level.start_pos
	# Smash a scuttler to death and collect its scrap.
	p1.global_position = base
	var s: RobotEnemy = level.spawn_enemy("scuttler", base + east * 1.4, true)
	p1.sim = {"aim": east, "melee": true}
	level.simulate(2.5)
	_check(not s.alive, "smashing kills a scuttler")
	p1.sim = {}
	var before: int = mission_scrap
	level.simulate(2.0)
	_check(mission_scrap > before or level.pickups.get_child_count() > 0, "scrap drops")
	# Mouth cannon hits at range.
	p1.global_position = base
	var g: RobotEnemy = level.spawn_enemy("gunner", base + east * 7.0, false)
	p1.sim = {"aim": east, "cannon": true}
	var energy0: float = p1.energy
	level.simulate(0.3)
	_check(g.hp < g.max_hp, "cannon bolts hit at range")
	_check(level.counters.get("player_bolts", 0) > 0 and p1.energy < energy0 + 1.0, "cannon uses energy")
	# Gunner shoots back, scuttler bites, bruiser slams.
	p1.sim = {}
	g.wake()
	level.simulate(3.0)
	_check(int(level.counters.get("enemy_bolts", 0)) > 0, "gunners fire bursts")
	var hp0: float = p1.hp + p1.shield
	var b: RobotEnemy = level.spawn_enemy("bruiser", base + east * 2.0, true)
	level.simulate(3.0)
	_check(int(level.counters.get("enemy_slams", 0)) > 0, "bruisers slam")
	_check(p1.hp + p1.shield < hp0 or not p1.alive, "enemies hurt the player")
	for e: RobotEnemy in [g, b]:
		if e.alive:
			e.take_damage(99999.0, east, 0.0)
	# Dash: fast, and dodges hits.
	p1.reset_stats()
	p1.global_position = base
	p1.sim = {"move": Vector2(1.0, 0.0), "dash": true}
	level.simulate(0.1)
	_check(p1.is_dashing(), "dash starts")
	_check(not p1.take_damage(10.0, base), "dashing dodges damage")
	level.simulate(0.3)
	_check(p1.global_position.distance_to(base) > 2.0, "dash covers ground")
	# Repair kit.
	p1.sim = {}
	level.simulate(0.6)
	p1.hp = 20.0
	var kits0: int = Game.kits
	p1.sim = {"kit": true}
	level.simulate(0.05)
	_check(p1.hp > 20.0 and Game.kits == kits0 - 1, "repair kit heals and is used up")
	p1.sim = {}
	# Boss: charge, summon (capped), then destroy it.
	var boss: RobotEnemy = level.boss
	p1.reset_stats()
	p1.global_position = boss.global_position + Vector3(0.0, 0.0, 7.0)
	if not level.walkable(LevelMap.to_cell(p1.global_position)):
		p1.global_position = boss.global_position + Vector3(-7.0, 0.0, 0.0)
	boss.wake()
	boss._special_t = 0.0
	level.simulate(2.5)
	_check(int(level.counters.get("charges", 0)) > 0, "foreman charges")
	for i: int in range(6):
		boss._summon_t = 0.0
		p1.reset_stats()
		level.simulate(0.3)
	_check(boss.minion_count() > 0 and boss.minion_count() <= int(Balance.ENEMIES["foreman"]["max_minions"]), "foreman summons, capped")
	boss.take_damage(boss.hp * 0.6, east, 0.0)
	_check(boss.phase == 2 or not boss.alive, "boss enters phase 2 below half HP")
	boss.take_damage(99999.0, east, 0.0)
	_check(not boss.alive and level.exit_active, "killing the boss powers the extraction pad")
	# Extract.
	p1.reset_stats()
	p1.global_position = level.exit_pos
	_update_mission(0.016)
	_check(mode == "results" and Game.clear_count("foundry") == 1, "standing on the pad completes the mission")
	hud.press("ok")
	_check(mode == "hub" and not hud.is_menu_open(), "results return to the Ark")
	_check(Game.seen_unlocks.has("augments") and Game.seen_unlocks.has("ashfall"), "clearing the foundry unlocks the augment bay and Ashfall")
	_check(_station("augments").unlocked and not _station("lab").unlocked, "augment bay opens, lab stays locked")
	_check(Game.mission_tier("foundry") == 2, "foundry threat rises after a clear")


func _smoke_upgrades(p1: GorillaBot) -> void:
	Game.scrap = 100000
	open_station_menu("augments")
	_check(hud.menu_kind == "augments", "augment bay opens once unlocked")
	var arms0: float = Game.melee_mult()
	hud.press("arms")
	_check(Game.aug("arms") == 1 and Game.melee_mult() > arms0, "hydraulic arms raise smash damage")
	hud.press("plating")
	_check(is_equal_approx(p1.max_hp, Balance.PLAYER_HP + 20.0), "titan plating raises max HP")
	var spent: int = Game.scrap
	for i: int in range(8):
		hud.press("servos")
	_check(Game.aug("servos") == 4, "augments stop at their max level")
	_check(Game.scrap < spent, "augments cost scrap")
	hud.press("capacitor")
	_check(is_equal_approx(p1.energy_max, Balance.ENERGY_MAX + 20.0), "capacitor raises max energy")
	close_menus()


func _smoke_ashfall(p1: GorillaBot) -> void:
	start_mission("ashfall")
	_check(mode == "mission" and level.id == "ashfall", "ashfall deploys")
	_check(level.tier == 2 and level.boss != null and level.boss.kind == "warden", "ashfall is threat 2 with the warden")
	_check(level.find_path(level.start_pos, level.boss.global_position).size() > 0, "warden is reachable from the start")
	var sc: RobotEnemy = level.spawn_enemy("scuttler", level.start_pos + Vector3(30.0, 0.0, 0.0), false)
	_check(is_equal_approx(sc.max_hp, float(Balance.ENEMIES["scuttler"]["hp"]) * Balance.hp_mult(2, 1)), "threat tier scales enemy HP")
	# Every kind runs its behaviour for a while next to the player.
	p1.global_position = level.start_pos
	for kind: String in ["scuttler", "gunner", "bruiser", "foreman", "warden"]:
		var e: RobotEnemy = level.spawn_enemy(kind, level.start_pos + Vector3(2.5, 0.0, -1.5), true)
		for i: int in range(4):
			p1.reset_stats()
			level.simulate(0.5)
		_check(is_instance_valid(e), "%s survives a few seconds of AI without errors" % kind)
		if e.alive:
			e.take_damage(999999.0, Vector3.RIGHT, 0.0)
	# Warden's bolt rings.
	var w: RobotEnemy = level.boss
	p1.reset_stats()
	p1.global_position = w.global_position + Vector3(0.0, 0.0, 5.0)
	if not level.walkable(LevelMap.to_cell(p1.global_position)):
		p1.global_position = w.global_position + Vector3(0.0, 0.0, 3.0)
	var bolts0: int = int(level.counters.get("enemy_bolts", 0))
	w.wake()
	w._special_t = 0.0
	level.simulate(1.2)
	_check(int(level.counters.get("enemy_bolts", 0)) - bolts0 >= int(Balance.ENEMIES["warden"]["nova"]), "warden fires a ring of bolts")
	w.take_damage(999999.0, Vector3.RIGHT, 0.0)
	p1.reset_stats()
	p1.global_position = level.exit_pos
	_update_mission(0.016)
	hud.press("ok")
	_check(_station("lab").unlocked, "clearing Ashfall opens the weapons lab")


func _smoke_mods(p1: GorillaBot) -> void:
	open_station_menu("lab")
	for e: Dictionary in Balance.LAB:
		hud.press(String(e["id"]))
		_check(Game.has_mod(String(e["id"])), "lab sells %s" % e["id"])
	close_menus()
	start_mission("foundry")
	var east: Vector3 = Vector3(1.0, 0.0, 0.0)
	var base: Vector3 = level.start_pos
	p1.global_position = base
	# Splitter: three bolts per shot.
	var shots0: int = int(level.counters.get("player_bolts", 0))
	p1.sim = {"aim": east, "cannon": true}
	level.simulate(0.02)
	p1.sim = {}
	_check(int(level.counters.get("player_bolts", 0)) - shots0 == 3, "splitter jaw fires 3 bolts")
	# Arc teeth: a bolt hit jumps to a second robot.
	var a: RobotEnemy = level.spawn_enemy("bruiser", base + east * 5.0, false)
	var b: RobotEnemy = level.spawn_enemy("bruiser", base + east * 5.0 + Vector3(0.0, 0.0, 2.5), false)
	level.simulate(1.0)
	_check(b.hp < b.max_hp, "arc teeth chain to a nearby robot")
	a.take_damage(999999.0, east, 0.0)
	b.take_damage(999999.0, east, 0.0)
	# Seismic fists: the combo slam stuns.
	p1.reset_stats()
	p1.global_position = base
	var s: RobotEnemy = level.spawn_enemy("bruiser", base + east * 1.8, false)
	s.max_hp = 99999.0
	s.hp = 99999.0
	p1.sim = {"aim": east, "melee": true}
	level.simulate(1.3)
	p1.sim = {}
	_check(s._stun > 0.0 or s.hit_recent < 1.3, "seismic slam lands")
	s.take_damage(9999999.0, east, 0.0)
	# Magnet core: scrap comes from further away.
	p1.reset_stats()
	var k: Pickup = level.spawn_pickup("scrap", base + east * (Balance.PICKUP_RADIUS * 2.2), 5)
	p1.global_position = base
	var scrap0: int = Game.scrap
	level.simulate(1.5)
	_check(Game.scrap > scrap0 or not is_instance_valid(k), "magnet core pulls distant scrap")


func _smoke_coop(p1: GorillaBot) -> void:
	var e: RobotEnemy = level.spawn_enemy("gunner", level.start_pos + Vector3(30.0, 0.0, 0.0), false)
	var hp1: float = e.max_hp
	for i: int in range(3):
		add_player(false, 10 + i)
	_check(players.size() == 4 and level.player_count == 4, "three more bots join")
	_check(is_equal_approx(e.max_hp, hp1 * Balance.COOP_HP[4] / Balance.COOP_HP[1]), "enemy HP scales with player count")
	for p: GorillaBot in players:
		p.scripted = true
	players[3].global_position = level.start_pos + Vector3(30.0, 0.0, 0.0)
	for i: int in range(60):
		camera._process(1.0 / 60.0)
	_check(camera.size > Balance.CAMERA_SIZE, "camera zooms out to fit spread-out players")
	# A downed co-op bot reboots next to a teammate.
	var p2: GorillaBot = players[1]
	p2.take_damage(99999.0, p2.global_position)
	_check(not p2.alive, "co-op bot can go down")
	_update_mission(Balance.RESPAWN_TIME + 0.1)
	_check(p2.alive, "downed bot reboots next to a teammate")
	# Everyone down: mission fails and keeps part of the scrap.
	mission_scrap = 100
	Game.scrap = 1000
	for p: GorillaBot in players:
		p.reset_stats()
		p.take_damage(99999.0, p.global_position)
	_update_mission(1.0)
	_update_mission(1.1)
	_check(mode == "results" and Game.scrap == 1000 - 50, "a wipe ends the mission and keeps half its scrap")
	hud.press("ok")
	# Back to one player for the rest.
	while players.size() > 1:
		var extra: GorillaBot = players.pop_back()
		extra.queue_free()
	level.set_player_count(1)
	camera.targets = players
	_check(mode == "hub" and p1.alive, "back on the Ark after a wipe")


func _smoke_save_and_pause() -> void:
	Game.save_game()
	var scrap: int = Game.scrap
	var clears: Dictionary = Game.clears.duplicate()
	var augs: Dictionary = Game.augments.duplicate()
	Game.reset_progress()
	Game.load_game()
	_check(Game.scrap == scrap and Game.clears == clears and Game.augments == augs and Game.has_mod("splitter"), "save and load round-trip")
	_check(Game.save_path.contains("smoke"), "smoke test uses its own save file")
	open_pause()
	_check(paused and world.process_mode == Node.PROCESS_MODE_DISABLED and hud.menu_kind == "pause", "pause freezes the world")
	close_menus()
	_check(not paused and world.process_mode == Node.PROCESS_MODE_INHERIT, "resume unfreezes")
