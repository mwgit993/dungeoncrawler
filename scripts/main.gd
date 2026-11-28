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
var forced_seed: int = 0     # nonzero: every mission uses this map seed (the smoke test sets it)
var paused: bool = false
var _fail_t: float = -1.0
var _busy: bool = false
var _pad_start_prev: Dictionary = {}
var _smoke: bool = false
var _smoke_fail: Array[String] = []


func _ready() -> void:
	Net.main = self
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
	p.setup(level, _free_slot(), uses_kbm, pad_id)
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
		hud.toast("PLAYER %d JOINED" % (p.slot + 1), "Enemies scale up for %d bots" % players.size(), p.color, 2.5)
		Sfx.play("unlock", -8.0)
	return p


## The lowest P1-P4 slot no bot is using (online players can leave from the middle).
func _free_slot() -> int:
	for s: int in range(4):
		if _player_by_slot(s) == null:
			return s
	return players.size()


func _player_by_slot(s: int) -> GorillaBot:
	for p: GorillaBot in players:
		if p.slot == s:
			return p
	return null


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
	if Net.is_client():
		return
	for id: int in Input.get_connected_joypads():
		var now: bool = Input.is_joy_button_pressed(id, JOY_BUTTON_START)
		var was: bool = bool(_pad_start_prev.get(id, false))
		_pad_start_prev[id] = now
		if now and not was and not _pad_taken(id) and players.size() < 4 and mode != "results" and not paused and not _busy:
			add_player(false, id)


func _set_players_input(on: bool) -> void:
	for p: GorillaBot in players:
		if p.net_mode != "remote": # a client's bot follows that client, not our menus
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
	Net.level_changed()


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
	# A new layout every run (the smoke test pins the seed).
	var seed_value: int = forced_seed if forced_seed != 0 else 1 + (randi() & 0x3fffffff)
	var def: Dictionary = Maps.mission_def(id, seed_value)
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
	if Net.is_client():
		_update_client()
		return
	if level == null or _busy:
		return
	# Online, the game keeps going for everyone while the host has a menu open.
	if paused and not Net.online():
		return
	if hud.is_menu_open():
		hud.set_prompt("")
		if mode == "mission" and Net.online():
			_update_mission(minf(delta, 0.1))
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
	# Online players can't open the Ark's stations: the host's save runs them.
	for rp: GorillaBot in players:
		if rp.net_mode == "remote" and rp.interact_pressed:
			Net.ev_to(rp.slot, "toast", ["HOST ONLY", "The host runs the Ark's stations and picks the mission", Color(1.0, 0.7, 0.4), 2.5])
	var best: Station = null
	var who: GorillaBot = null
	var best_d: float = Station.INTERACT_RANGE
	for p: GorillaBot in players:
		if p.net_mode == "remote":
			continue
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
		if p2.net_mode != "remote" and p2.interact_pressed and p2.global_position.distance_to(best.global_position) < Station.INTERACT_RANGE + 0.5:
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
	Net.ev("results", ["MISSION COMPLETE", desc])


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
	Net.ev("results", ["MISSION ABANDONED" if abandoned else "BOTS DESTROYED", desc])


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
	Net.team_changed()
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
	if hud.is_menu_open() or _busy or (mode == "results" and not Net.is_client()):
		return
	paused = true
	# Online, pausing only opens the menu: the game goes on for everyone else.
	if not Net.online():
		world.process_mode = Node.PROCESS_MODE_DISABLED
	_set_players_input(false)
	hud.open_menu("pause", "PAUSED", _pause_entries(), _on_pause_pick)


func _pause_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"id": "resume", "label": "RESUME", "desc": "Back to it."}]
	out.append({"id": "fullscreen", "label": "FULLSCREEN", "right": "ON" if Game.fullscreen else "OFF", "desc": "F11 also toggles it."})
	out.append({"id": "sfx", "label": "SOUND", "right": "%d%%" % int(round(Game.sfx_volume * 100.0)), "desc": "Sound effect volume."})
	out.append_array(_online_entries())
	if mode == "mission" and not Net.is_client():
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
		"host", "join", "stop_host", "leave", "hosting":
			_on_online_pick(id)
		"quit":
			Game.save_game()
			get_tree().quit()


# --- Online co-op (see Net) -------------------------------------------------------------

func _online_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var port_note: String = "UDP port %d" % Net.PORT
	if Net.is_client():
		out.append({"id": "leave", "label": "LEAVE ONLINE GAME", "desc": "Back to your own Ark and save. You can drop back in any time."})
	elif Net.is_host():
		var ips: String = ", ".join(Net.local_ips())
		out.append({"id": "hosting", "label": "HOSTING ONLINE", "right": "%d JOINED" % Net.client_count(),
			"desc": "Friends pick JOIN ONLINE GAME and type one of your addresses: %s (%s)." % [ips, port_note]})
		out.append({"id": "stop_host", "label": "STOP HOSTING", "desc": "Sends everyone who joined back to their own Ark."})
	else:
		out.append({"id": "host", "label": "HOST ONLINE GAME",
			"desc": "Friends can drop in and out of your game over Wi-Fi or the internet (%s)." % port_note})
		if mode == "hub":
			out.append({"id": "join", "label": "JOIN ONLINE GAME", "desc": "Drop into a friend's game. You'll need their IP address."})
	return out


func _on_online_pick(id: String) -> void:
	match id:
		"host":
			if Net.host_game():
				close_menus()
				var ips: PackedStringArray = Net.local_ips()
				hud.toast("HOSTING ONLINE", "Your address: %s" % (ips[0] if not ips.is_empty() else "?"), Color(0.5, 1.0, 0.7), 5.0)
			else:
				hud.refresh_menu(_pause_entries())
				hud.toast("CAN'T HOST", Net.last_error, Color(1.0, 0.45, 0.4), 3.0)
		"join":
			hud.open_input("join", "JOIN ONLINE GAME", Game.last_ip,
				"The host's IP address (their pause menu shows it). Same Wi-Fi, a forwarded UDP port %d, or Tailscale." % Net.PORT,
				_join_typed, _back_to_pause)
		"stop_host", "leave":
			close_menus()
			Net.leave()


func _back_to_pause() -> void:
	hud.close_menu()
	hud.open_menu("pause", "PAUSED", _pause_entries(), _on_pause_pick)


func _join_typed(ip: String) -> void:
	ip = ip.strip_edges()
	if ip == "":
		Sfx.play("cant", -6.0)
		return
	Game.last_ip = ip
	Game.save_game() # our own progress is safe on disk before the host's replaces it on screen
	close_menus()
	if Net.join_game(ip):
		hud.toast("CONNECTING", ip, Color(0.6, 0.85, 1.0), 6.0)
	else:
		hud.toast("CAN'T JOIN", Net.last_error, Color(1.0, 0.45, 0.4), 3.0)


## Client frame: our own bot moves itself; this just handles prompts and pausing.
func _update_client() -> void:
	if level == null:
		return
	if hud.is_menu_open():
		hud.set_prompt("")
		return
	var me: GorillaBot = _player_by_slot(Net.my_slot)
	if me == null:
		return
	if me.pause_pressed:
		open_pause()
		return
	hud.set_prompt("")
	if level.is_hub:
		for st: Station in level.stations:
			if me.global_position.distance_to(st.global_position) < Station.INTERACT_RANGE:
				hud.set_prompt("%s  (HOST ONLY)" % st.title())
				return


# Host side.

func net_add_remote(peer: int) -> int:
	var p: GorillaBot = add_player(false, -1)
	p.net_mode = "remote"
	p.peer_id = peer
	return p.slot


func net_remove_remote(slot: int) -> void:
	var p: GorillaBot = _player_by_slot(slot)
	if p == null or p.net_mode != "remote":
		return
	players.erase(p)
	p.queue_free()
	camera.targets = players
	if level != null:
		level.set_player_count(players.size())
	hud.toast("PLAYER %d LEFT" % (slot + 1), "Enemies scale back for %d bot%s" % [players.size(), "" if players.size() == 1 else "s"], p.color, 2.5)


func net_remote_input(slot: int, state: Array) -> void:
	var p: GorillaBot = _player_by_slot(slot)
	if p != null and p.net_mode == "remote":
		p.net_state = state


func net_stop_hosting() -> void:
	for p: GorillaBot in players.duplicate():
		if p.net_mode == "remote":
			net_remove_remote(p.slot)
	hud.toast("STOPPED HOSTING", "Your game is offline again", Color(0.8, 0.85, 1.0), 2.5)


func net_level_spec() -> Dictionary:
	return {"map": level.id if level != null else "hub", "tier": level.tier if level != null else 1,
		"seed": int(level.def.get("seed", 0)) if level != null else 0,
		"players": players.size(), "mode": mode, "mission": mission_id, "team": Game.team_data()}


func net_team() -> Dictionary:
	return Game.team_data()


func net_snapshot() -> Array:
	var ps: Array = []
	for p: GorillaBot in players:
		ps.append(p.net_entry())
	return [mode, Game.scrap, Game.kits, ps, level.net_entities() if level != null else [[], [], PackedInt32Array(), false]]


# Client side.

func net_local_input() -> Array:
	var me: GorillaBot = _player_by_slot(Net.my_slot)
	return me.net_input() if me != null else []


func net_enter_client(spec: Dictionary, team: Dictionary) -> void:
	hud.close_menu()
	paused = false
	_busy = false
	world.process_mode = Node.PROCESS_MODE_INHERIT
	for p: GorillaBot in players:
		p.queue_free()
	players.clear()
	Game.apply_team(team)
	net_load_level(spec)
	hud.toast("JOINED ONLINE GAME", "You're P%d. Leave any time from the pause menu." % (Net.my_slot + 1), Color(0.5, 1.0, 0.7), 4.0)


func net_load_level(spec: Dictionary) -> void:
	# Clears since the last level (unlocked stations, threat tiers) come along with every level.
	if spec.has("team"):
		Game.apply_team(spec["team"])
	mode = String(spec.get("mode", "hub"))
	mission_id = String(spec.get("mission", ""))
	var map_id: String = String(spec.get("map", "hub"))
	var def: Dictionary = Maps.HUB if map_id == "hub" else Maps.mission_def(map_id, int(spec.get("seed", 0)))
	if level != null:
		world.remove_child(level)
		level.queue_free()
	level = LevelMap.new()
	level.puppet = true
	level.build(def, int(spec.get("tier", 1)), int(spec.get("players", 1)))
	world.add_child(level)
	level.players = players
	for p: GorillaBot in players:
		p.move_level(level, level.start_pos)
		p.rig.revive()
	_refresh_stations()
	camera.targets = players
	camera.snap_to(level.start_pos)
	hud.set_prompt("")
	if hud.menu_kind == "results":
		hud.close_menu()
		paused = false
	if not _smoke:
		hud.set_fade(1.0)
		hud.fade_to(0.0, 0.35)


func net_apply_snapshot(snap: Array, _first: bool) -> void:
	if level == null:
		return
	mode = String(snap[0])
	Game.scrap = int(snap[1])
	Game.kits = int(snap[2])
	var seen: Dictionary = {}
	for pv: Variant in snap[3]:
		var pe: Array = pv
		var slot: int = int(pe[0])
		seen[slot] = true
		var p: GorillaBot = _player_by_slot(slot)
		if p == null:
			p = _add_net_player(slot, pe[1])
		p.net_apply(pe)
	for p2: GorillaBot in players.duplicate():
		if not seen.has(p2.slot):
			players.erase(p2)
			p2.queue_free()
	camera.targets = players
	level.net_apply_entities(snap[4])


func _add_net_player(slot: int, pos: Vector3) -> GorillaBot:
	var mine: bool = slot == Net.my_slot
	var p: GorillaBot = GorillaBot.new()
	p.setup(level, slot, mine, 0 if mine else -1)
	p.net_mode = "local" if mine else "puppet"
	players_root.add_child(p)
	players.append(p)
	p.move_level(level, pos)
	camera.targets = players
	if mine:
		camera.snap_to(pos)
	return p


func net_apply_event(kind: String, a: Array) -> void:
	match kind:
		"toast":
			hud.toast(String(a[0]), String(a[1]), a[2], float(a[3]))
		"results":
			_set_players_input(false)
			var entries: Array[Dictionary] = [{"id": "ok", "label": "OK",
				"desc": String(a[1]) + "\nThe host takes everyone back to the Ark."}]
			hud.open_menu("results", String(a[0]), entries, _on_client_results_pick)
		"team":
			net_apply_team(a[0])
	if level == null:
		return
	match kind:
		"fx":
			Fx.replay(level.fx_root, String(a[0]), a[1])
		"sfx":
			Sfx.play(String(a[0]), float(a[1]), float(a[2]))
		"shake":
			camera.add_shake(float(a[0]))
		"prig":
			var p: GorillaBot = _player_by_slot(int(a[0]))
			if p != null:
				p.rig.callv(String(a[1]), a[2])
		"erig":
			var e: RobotEnemy = level._enemy_by_id(int(a[0]))
			if e != null and is_instance_valid(e):
				e.rig.callv(String(a[1]), a[2])
		"bolt":
			level.net_spawn_bolt(a)
		"bolt_x":
			level.net_end_bolt(int(a[0]))
		"prop_hit":
			level.net_prop_hit(int(a[0]))
		"push":
			var me: GorillaBot = _player_by_slot(Net.my_slot)
			if me != null:
				me.velocity += a[0] as Vector3


func _on_client_results_pick(_id: String) -> void:
	hud.close_menu()
	_set_players_input(true)


func net_apply_team(team: Dictionary) -> void:
	Game.apply_team(team)
	if level != null:
		_refresh_stations()


## Back to this machine's own game: left, kicked, the host quit, or we never got in.
func net_back_offline(reason: String) -> void:
	hud.close_menu()
	paused = false
	world.process_mode = Node.PROCESS_MODE_INHERIT
	for p: GorillaBot in players:
		p.queue_free()
	players.clear()
	if level != null:
		world.remove_child(level)
		level.queue_free()
		level = null
	Game.restore_own()
	add_player(true, 0)
	go_hub(true)
	hud.toast("OFFLINE", reason, Color(1.0, 0.65, 0.45), 4.5)


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
	forced_seed = 20261128
	_smoke_check_maps()
	_smoke_check_mapgen()
	_smoke_hub(p1)
	_smoke_rigs(p1)
	_smoke_foundry(p1)
	_smoke_upgrades(p1)
	_smoke_ashfall(p1)
	_smoke_mods(p1)
	_smoke_coop(p1)
	_smoke_net(p1)
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


## Random maps: the same seed gives the same map, seeds differ, seed 0 is the hand-made map, and
## many seeds per mission all give a sound map (checked here independently of MapGen's own checks).
func _smoke_check_mapgen() -> void:
	for m: Dictionary in Maps.MISSIONS:
		var id: String = String(m["id"])
		_check(str(Maps.mission_def(id, 0)["rows"]) == str(m["rows"]), "%s: seed 0 is the hand-made map" % id)
		var a: String = str(Maps.mission_def(id, 1234)["rows"])
		_check(a == str(Maps.mission_def(id, 1234)["rows"]), "%s: the same seed gives the same map" % id)
		_check(a != str(Maps.mission_def(id, 98765)["rows"]) and a != str(m["rows"]), "%s: other seeds give other maps" % id)
		var shown: int = 0
		for s: int in range(1, 41):
			var why: String = _mapgen_problem(Maps.mission_def(id, s * 7717))
			if why != "" and shown < 3:
				shown += 1
				_check(false, "%s seed %d: %s" % [id, s * 7717, why])


## What's wrong with a generated map, or "".
func _mapgen_problem(def: Dictionary) -> String:
	var legend: String = "#w.,=~otc$+PXsgbB"
	var rows: Array = def["rows"]
	var h: int = rows.size()
	var w: int = String(rows[0]).length()
	var at: Dictionary = {}   # char -> Array of cells
	for z: int in range(h):
		var line: String = String(rows[z])
		if line.length() != w:
			return "row %d is %d wide, not %d" % [z, line.length(), w]
		for x: int in range(w):
			var c: String = line[x]
			if not legend.contains(c):
				return "unknown character '%s'" % c
			if not at.has(c):
				at[c] = []
			(at[c] as Array).append(Vector2i(x, z))
	for one: String in ["P", "B", "X"]:
		if (at.get(one, []) as Array).size() != 1:
			return "needs exactly one %s" % one
	var blocked: String = LevelMap.WALLS + "~" + LevelMap.SOLID_PROPS
	var walk: Callable = func(x: int, z: int) -> bool:
		return x >= 0 and z >= 0 and x < w and z < h and not blocked.contains(String(rows[z])[x])
	var p: Vector2i = (at["P"] as Array)[0]
	var dist: Dictionary = {p: 0}
	var queue: Array[Vector2i] = [p]
	var head: int = 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if not dist.has(n) and walk.call(n.x, n.y):
				dist[n] = int(dist[cur]) + 1
				queue.append(n)
	var b: Vector2i = (at["B"] as Array)[0]
	if not dist.has(b) or int(dist[b]) < 20:
		return "the boss is unreachable or too close to the start"
	if not dist.has((at["X"] as Array)[0]):
		return "the extraction pad is unreachable"
	var robots: int = 0
	for k: String in ["s", "g", "b", "+"]:
		for c2: Variant in at.get(k, []):
			var cell: Vector2i = c2
			if not dist.has(cell):
				return "a '%s' at %s can't be reached" % [k, cell]
			if k != "+":
				robots += 1
				if maxi(absi(cell.x - p.x), absi(cell.y - p.y)) < 7:
					return "a robot starts right next to P"
	if robots < 12:
		return "only %d robots" % robots
	for k2: String in ["c", "$"]:
		for c3: Variant in at.get(k2, []):
			var cc: Vector2i = c3
			var open: bool = false
			for d2: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				open = open or dist.has(cc + d2)
			if not open:
				return "a crate at %s can't be reached" % cc
	for dz: int in range(-1, 2):
		for dx: int in range(1, 5):
			if not walk.call(p.x + dx, p.y + dz):
				return "the floor east of P isn't clear"
		for dx2: int in range(-1, 2):
			if not walk.call(b.x + dx2, b.y + dz):
				return "the boss is boxed in"
	return ""


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
	g.slash(0)
	g.fire()
	g.dash()
	for i2: int in range(30):
		g.animate(dt, Vector3(4.0, 0.0, 2.0), Vector3.RIGHT, 0.5)
	_check(g.blades_out() > 0.95 and g._blades[0].visible and g._blades[1].visible, "the arm blades slide out on a slash")
	g.knock_down()
	for i3: int in range(30):
		g.animate_down(dt)
	_check(g.blades_out() == 0.0 and not g._blades[0].visible, "a downed gorilla's blades go back in")
	g.revive()
	g.animate(dt, Vector3.ZERO, Vector3.FORWARD, 1.0)
	g.slash(1)
	var swung: bool = false
	for i4: int in range(90):
		g.animate(dt, Vector3.ZERO, Vector3.FORWARD, 1.0)
		swung = swung or absf(g._arms[1].rotation.y) > 0.6
	_check(swung and g.blades_out() < 0.01 and not g._blades[1].visible, "a slash sweeps the arm across, and the blades retract after a pause")
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
	# Slash a scuttler to death and collect its scrap.
	p1.global_position = base
	var s: RobotEnemy = level.spawn_enemy("scuttler", base + east * 1.4, true)
	p1.sim = {"aim": east, "melee": true}
	level.simulate(2.5)
	_check(not s.alive, "the blades kill a scuttler")
	p1.sim = {}
	var before: int = mission_scrap
	level.simulate(2.0)
	_check(mission_scrap > before or level.pickups.get_child_count() > 0, "scrap drops")
	# The arm blades reach well past where a punch did.
	level.simulate(1.0)
	p1.global_position = base
	var far: RobotEnemy = level.spawn_enemy("gunner", base + east * 3.6, false)
	far.max_hp = 99999.0
	far.hp = 99999.0
	p1.sim = {"aim": east, "melee": true}
	level.simulate(0.1)
	p1.sim = {}
	_check(far.hp < far.max_hp, "the arm blades cut a robot 3.6 m away (the old punch reached 2.5)")
	_check(p1.rig.blades_out() > 0.5, "the blades are out while fighting")
	far.take_damage(9999999.0, east, 0.0)
	level.simulate(1.5)
	_check(p1.rig.blades_out() < 0.01, "the blades slide back in after the fight")
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
	_check(Game.aug("arms") == 1 and Game.melee_mult() > arms0, "hydraulic arms raise blade damage")
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
	# Seismic slam: the combo slam stuns.
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


## Online co-op, without sockets: the snapshot survives the wire format, a client's bot drops in,
## goes where its client says and fights with its buttons, a client's copy of the level follows
## the host's snapshot, every event the host sends replays, leaving scales the robots back, a
## client's own bot walks by itself, a client never writes its save, and hosting opens a port.
func _smoke_net(p1: GorillaBot) -> void:
	start_mission("foundry")
	level.simulate(0.2)
	var snap: Array = net_snapshot()
	var back: Variant = bytes_to_var(var_to_bytes(snap))
	_check(back is Array and str(back) == str(snap), "net: the snapshot survives the wire format")
	_check(net_level_spec().has("team"), "net: every level brings the team's progress (unlocks, threat)")
	var e: RobotEnemy = level.enemies[0]
	var hp1: float = e.max_hp
	# Capture what a host would send, with a pretend client in slot 1.
	Net.role = "host"
	Net.peer_slots = {77: 1}
	var slot: int = net_add_remote(77)
	var rb: GorillaBot = _player_by_slot(slot)
	_check(slot == 1 and rb != null and rb.net_mode == "remote" and level.player_count == 2, "net: a client's bot drops in")
	_check(e.max_hp > hp1, "net: robots scale up when a client joins")
	var spot: Vector3 = _free_spot_near(p1.global_position, 2)
	var foe: RobotEnemy = level.spawn_enemy("gunner", _free_spot_near(spot, 1), false)
	var to: Vector3 = foe.global_position - spot
	to.y = 0.0
	net_remote_input(slot, [spot, Vector3.ZERO, to.normalized(), false, true, false, 0, 0])
	var fhp: float = foe.hp
	level.simulate(0.4)
	_check(rb.global_position.distance_to(spot) < 0.05, "net: a client's bot stands where the client says")
	_check(foe.hp < fhp, "net: a client's blade button hits robots on the host")
	Game.kits = 2
	rb.hp = rb.max_hp * 0.5
	net_remote_input(slot, [spot, Vector3.ZERO, to.normalized(), false, false, true, 1, 0])
	level.simulate(0.1)
	_check(Game.kits == 1 and rb.hp > rb.max_hp * 0.5, "net: a client's kit press heals its bot")
	_check(level.counters.get("player_bolts", 0) > 0, "net: a client's cannon button fires")
	net_remote_input(slot, [spot, Vector3.ZERO, to.normalized(), true, false, false, 1, 0])
	level.simulate(1.0 / 60.0)
	_check(rb.is_dashing() and not rb.take_damage(10.0, spot + Vector3(1, 0, 0)), "net: a client's dash dodges on the host")
	net_remote_input(slot, [spot, Vector3.ZERO, to.normalized(), false, false, false, 1, 0])
	level.simulate(0.2)
	foe.take_damage(99999.0, Vector3.RIGHT, 0.0)
	var kinds: Dictionary = {}
	var captured: Array = Net._events.duplicate()
	for ev: Variant in captured:
		kinds[String((ev as Array)[0])] = true
	for want: String in ["fx", "sfx", "prig", "erig", "bolt", "bolt_x", "toast", "shake"]:
		_check(kinds.has(want), "net: the host sends '%s' events" % want)
	var snap2: Array = net_snapshot()
	Net._events.clear()
	Net.role = "offline"
	Net.peer_slots = {}
	# A client's copy of the level, built from the same map, ends up matching the host's.
	var mirror: LevelMap = LevelMap.new()
	mirror.puppet = true
	_check(int(net_level_spec()["seed"]) == int(level.def["seed"]) and int(level.def["seed"]) != 0, "net: the level spec carries the map seed")
	mirror.build(Maps.mission_def("foundry", int(net_level_spec()["seed"])), level.tier, players.size())
	mirror.visible = false
	world.add_child(mirror)
	mirror.net_apply_entities(snap2[4])
	_check(mirror.enemies.size() == level.enemies.size(), "net: the client's level has the host's robots (%d vs %d)" % [mirror.enemies.size(), level.enemies.size()])
	_check(mirror.props.size() == level.props.size() and mirror.pickups.get_child_count() == level.pickups.get_child_count(), "net: ...and its crates and pickups")
	var matched: bool = true
	for he: RobotEnemy in level.enemies:
		var me: RobotEnemy = mirror._enemy_by_id(he.net_id)
		if me == null or me.kind != he.kind or not is_equal_approx(me.hp, he.hp):
			matched = false
			continue
		for i: int in range(20):
			me._puppet_step(0.05)
		if me.global_position.distance_to(he.global_position) > 0.1:
			matched = false
	_check(matched, "net: every robot on the client has the host's id, kind, HP and position")
	_check(mirror.boss != null and mirror._enemy_by_id(level.boss.net_id) == mirror.boss, "net: the client knows the boss")
	# Every event replays on a client without errors.
	var old_level: LevelMap = level
	level = mirror
	for ev2: Variant in captured:
		var ea: Array = ev2
		net_apply_event(String(ea[0]), ea[1] as Array)
	net_apply_event("results", ["MISSION COMPLETE", "test"])
	_check(hud.menu_kind == "results", "net: a client sees the results screen")
	hud.close_menu()
	_set_players_input(true)
	level = old_level
	world.remove_child(mirror)
	mirror.queue_free()
	# The client leaves: its bot goes and the robots scale back down.
	net_remove_remote(slot)
	_check(players.size() == 1 and level.player_count == 1 and is_equal_approx(e.max_hp, hp1), "net: a client leaving scales the robots back")
	# A client's own bot walks the moment you steer it, and sends that to the host.
	var lb: GorillaBot = GorillaBot.new()
	lb.setup(level, 3, false, -1)
	lb.net_mode = "local"
	lb.scripted = true
	players_root.add_child(lb)
	lb.move_level(level, p1.global_position)
	var start: Vector3 = lb.global_position
	lb.sim = {"move": Vector2(1.0, 0.0), "melee": true, "kit": true}
	for i2: int in range(30):
		lb.step(1.0 / 60.0)
	lb.sim = {}
	lb.step(1.0 / 60.0)
	lb.sim = {"kit": true}
	lb.step(1.0 / 60.0)
	var sent: Array = lb.net_input()
	_check(lb.global_position.distance_to(start) > 0.3 and sent.size() == 8 and int(sent[6]) == 2, "net: a client's own bot walks by itself and counts its presses")
	var ent: Array = lb.net_entry()
	lb.net_apply(ent)
	ent[1] = start
	ent[11] = int(ent[11]) + 1
	lb.net_apply(ent)
	_check(lb.global_position.distance_to(start) < 0.01, "net: the host can still move a client's bot (reboot, new level)")
	lb.queue_free()
	# A client's save stays its own.
	var before: String = FileAccess.get_file_as_string(Game.save_path)
	var scrap0: int = Game.scrap
	Net.role = "client"
	Game.apply_team({"scrap": scrap0 + 999, "augments": {"plating": 3}})
	Game.save_game()
	Net.role = "offline"
	_check(FileAccess.get_file_as_string(Game.save_path) == before, "net: a client never writes its save")
	Game.restore_own()
	_check(Game.scrap == scrap0, "net: leaving restores the client's own progress")
	# The pause menu offers hosting and joining, and hosting really opens the port.
	go_hub()
	var ids: Array[String] = []
	for row: Dictionary in _online_entries():
		ids.append(String(row["id"]))
	_check("host" in ids and "join" in ids, "net: the pause menu offers HOST and JOIN")
	_on_online_pick("join")
	_check(hud.menu_kind == "join" and hud.input_text() == Game.last_ip, "net: JOIN asks for the host's address")
	close_menus()
	_check(Net.host_game() and Net.is_host(), "net: hosting opens UDP port %d" % Net.PORT)
	Net.leave()
	_check(Net.role == "offline" and players.size() == 1, "net: stopping hosting")


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
