extends Node

## Progress that lasts between missions: scrap, what has been bought, which missions are cleared,
## and settings. Saved as JSON in user://. The smoke test switches to its own file first
## (use_smoke_save), so running it never touches a real save.

signal scrap_changed

const SAVE_VERSION: int = 1

var save_path: String = "user://dungeon_save.json"
var scrap: int = 0
var kits: int = 2
var kit_racks: int = 0
var shield_cell: bool = false
var augments: Dictionary = {}   # id -> level
var mods: Dictionary = {}       # id -> true
var clears: Dictionary = {}     # mission id -> times cleared
var seen_unlocks: Dictionary = {} # station/mission id -> true once its unlock has been announced
var sfx_volume: float = 0.8
var fullscreen: bool = false
var last_ip: String = ""        # the last host address typed into JOIN ONLINE GAME


func _ready() -> void:
	load_game()
	apply_display()


func use_smoke_save() -> void:
	save_path = "user://dungeon_smoke_test_save.json"
	reset_progress()


func reset_progress() -> void:
	scrap = 0
	kits = 2
	kit_racks = 0
	shield_cell = false
	augments = {}
	mods = {}
	clears = {}
	seen_unlocks = {}
	scrap_changed.emit()


func add_scrap(amount: int) -> void:
	scrap = maxi(scrap + amount, 0)
	scrap_changed.emit()


func spend(amount: int) -> bool:
	if amount > scrap:
		return false
	scrap -= amount
	scrap_changed.emit()
	return true


func kit_max() -> int:
	return Balance.KITS_BASE_MAX + kit_racks


func aug(id: String) -> int:
	return int(augments.get(id, 0))


func has_mod(id: String) -> bool:
	return bool(mods.get(id, false))


func clear_count(mission_id: String) -> int:
	return int(clears.get(mission_id, 0))


func mission_tier(mission_id: String) -> int:
	var base: int = int(Balance.MISSION_TIER.get(mission_id, 1))
	return mini(base + clear_count(mission_id), Balance.MAX_TIER)


func is_unlocked(requirement: String) -> bool:
	return requirement == "" or clear_count(requirement) > 0


func station_unlocked(station: String) -> bool:
	return is_unlocked(String(Balance.STATION_UNLOCK.get(station, "")))


func mission_unlocked(mission_id: String) -> bool:
	return is_unlocked(String(Balance.MISSION_UNLOCK.get(mission_id, "")))


## Stations and missions that are open but haven't been announced yet; marks them announced.
func take_new_unlocks() -> Array[String]:
	var out: Array[String] = []
	for id: String in Balance.STATION_UNLOCK.keys():
		if String(Balance.STATION_UNLOCK[id]) != "" and station_unlocked(id) and not seen_unlocks.has(id):
			seen_unlocks[id] = true
			out.append(id)
	for id: String in Balance.MISSION_UNLOCK.keys():
		if String(Balance.MISSION_UNLOCK[id]) != "" and mission_unlocked(id) and not seen_unlocks.has(id):
			seen_unlocks[id] = true
			out.append(id)
	return out


# --- Bot stats with upgrades applied --------------------------------------------------

func max_hp() -> float:
	return Balance.PLAYER_HP + float(_aug_per("plating") * aug("plating"))


func melee_mult() -> float:
	return 1.0 + float(_aug_per("arms") * aug("arms")) / 100.0


func cannon_mult() -> float:
	return 1.0 + float(_aug_per("throat") * aug("throat")) / 100.0


func speed_mult() -> float:
	return 1.0 + float(_aug_per("servos") * aug("servos")) / 100.0


func dash_cooldown() -> float:
	return Balance.DASH_COOLDOWN * maxf(1.0 - Balance.SERVO_DASH_CD * float(aug("servos")), 0.3)


func energy_max() -> float:
	return Balance.ENERGY_MAX + float(_aug_per("capacitor") * aug("capacitor"))


func energy_regen() -> float:
	return Balance.ENERGY_REGEN * (1.0 + Balance.CAPACITOR_REGEN * float(aug("capacitor")))


func _aug_per(id: String) -> int:
	for a: Dictionary in Balance.AUGMENTS:
		if String(a["id"]) == id:
			return int(a.get("per", 0))
	return 0


# --- Save / load ------------------------------------------------------------------------

func save_game() -> void:
	# Joined to someone's online game, this holds the host's team progress, not ours.
	if Net.is_client():
		return
	var data: Dictionary = {
		"version": SAVE_VERSION, "scrap": scrap, "kits": kits, "kit_racks": kit_racks,
		"shield_cell": shield_cell, "augments": augments, "mods": mods, "clears": clears,
		"seen_unlocks": seen_unlocks, "sfx_volume": sfx_volume, "fullscreen": fullscreen,
		"last_ip": last_ip,
	}
	var f: FileAccess = FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write save: %s" % save_path)
		return
	f.store_string(JSON.stringify(data, "\t"))


func load_game() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var text: String = FileAccess.get_file_as_string(save_path)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_warning("Save file is not valid JSON, starting fresh.")
		return
	var d: Dictionary = parsed
	scrap = int(d.get("scrap", 0))
	kit_racks = clampi(int(d.get("kit_racks", 0)), 0, 3)
	kits = clampi(int(d.get("kits", 2)), 0, kit_max())
	shield_cell = bool(d.get("shield_cell", false))
	augments = _int_dict(d.get("augments", {}))
	clears = _int_dict(d.get("clears", {}))
	mods = {}
	var m: Variant = d.get("mods", {})
	if m is Dictionary:
		for k: Variant in (m as Dictionary).keys():
			mods[String(k)] = bool((m as Dictionary)[k])
	seen_unlocks = {}
	var s: Variant = d.get("seen_unlocks", {})
	if s is Dictionary:
		for k: Variant in (s as Dictionary).keys():
			seen_unlocks[String(k)] = true
	sfx_volume = clampf(float(d.get("sfx_volume", 0.8)), 0.0, 1.0)
	fullscreen = bool(d.get("fullscreen", false))
	last_ip = String(d.get("last_ip", ""))


# --- Online co-op: the team's progress travels from the host to its clients -------------

func team_data() -> Dictionary:
	return {"scrap": scrap, "kits": kits, "kit_racks": kit_racks, "shield_cell": shield_cell,
		"augments": augments, "mods": mods, "clears": clears}


## A client takes on the host's progress while it plays there (and never saves it).
func apply_team(d: Dictionary) -> void:
	scrap = int(d.get("scrap", scrap))
	kit_racks = int(d.get("kit_racks", kit_racks))
	kits = int(d.get("kits", kits))
	shield_cell = bool(d.get("shield_cell", shield_cell))
	augments = _int_dict(d.get("augments", {}))
	clears = _int_dict(d.get("clears", {}))
	mods = {}
	var m: Variant = d.get("mods", {})
	if m is Dictionary:
		for k: Variant in (m as Dictionary).keys():
			mods[String(k)] = bool((m as Dictionary)[k])
	scrap_changed.emit()


## Back to this machine's own save after leaving an online game.
func restore_own() -> void:
	reset_progress()
	load_game()


func _int_dict(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Dictionary:
		for k: Variant in (v as Dictionary).keys():
			out[String(k)] = int((v as Dictionary)[k])
	return out


func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


func toggle_fullscreen() -> void:
	fullscreen = not fullscreen
	apply_display()
	save_game()
