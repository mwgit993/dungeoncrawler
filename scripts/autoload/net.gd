extends Node

## Online co-op, join by IP (Matt's request: Minecraft Dungeons-style drop-in / drop-out).
##
## The host runs the real game, exactly as offline. A client sends its bot's movement and
## buttons (`_c_input`, every frame) and draws the world from what the host sends back:
##   _s_welcome  once, on joining: our slot, the level, the team's progress, a full snapshot
##   _s_level    every time the host loads a level (hub or mission)
##   _s_snap     ~20 times a second: every bot, robot, pickup and crate that's still there
##   _s_events   every frame: effects, sounds, toasts, animation cues, bolts, results
##   _s_team     after the host buys something (augments, mods, kits)
## Clients move their own bot locally (so walking and dashing feel instant) and the host takes
## that position as is; everything else, attacks, damage, AI, scrap, is decided by the host.
## Progress works like local co-op: the host's save is the team's, a client's own save is left
## alone while it's connected (Game.save_game does nothing) and reloaded when it leaves.
##
## Joining or leaving never interrupts anyone: a new bot drops in next to a teammate, and when a
## client leaves its bot just disappears and the robots scale back down.

signal status_changed

const PORT: int = 24565
const MAX_CLIENTS: int = 3
const PROTOCOL: int = 3               # 2: arm blades (the "slash" rig cue and effect); 3: random maps (the seed)
const SNAPSHOT_RATE: float = 1.0 / 20.0
const UI_SOUNDS: Array[String] = ["ui", "buy", "cant"]

var role: String = "offline"   # offline, joining, client, host
var main: Main = null
var peer_slots: Dictionary = {}  # host: peer id -> slot of that client's bot
var my_slot: int = -1            # client: the slot of our own bot
var lseq: int = 0                # level sequence: the host bumps it per level, the client tracks it
var last_error: String = ""
var skip_slot: int = -1          # host: events added while set aren't sent to this slot's owner

var _snap_t: float = 0.0
var _events: Array = []          # host: [kind, args, skip_slot] gathered this frame
var _targeted: Dictionary = {}   # host: peer id -> events only that peer gets


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_lost)


func is_host() -> bool:
	return role == "host"


func is_client() -> bool:
	return role == "client"


func online() -> bool:
	return role == "host" or role == "client"


## True while the host should copy local effects and sounds to its clients.
func relaying() -> bool:
	return role == "host" and not peer_slots.is_empty()


func client_count() -> int:
	return peer_slots.size()


## A tag the client and host compare, so different builds don't try to play together.
func build_tag() -> String:
	return "%d:%d" % [PROTOCOL, hash(str(Maps.MISSIONS) + str(Balance.ENEMIES))]


## This machine's IPv4 addresses (LAN, Tailscale ...) to tell a friend.
func local_ips() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for a: String in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


# --- Starting and stopping --------------------------------------------------------------

func host_game() -> bool:
	if online():
		return false
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		last_error = "COULD NOT OPEN PORT %d" % PORT
		return false
	multiplayer.multiplayer_peer = peer
	role = "host"
	peer_slots.clear()
	_events.clear()
	_targeted.clear()
	lseq += 1
	status_changed.emit()
	return true


func join_game(ip: String) -> bool:
	if online() or role == "joining":
		return false
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(ip.strip_edges(), PORT)
	if err != OK:
		last_error = "BAD ADDRESS"
		return false
	multiplayer.multiplayer_peer = peer
	role = "joining"
	status_changed.emit()
	return true


## Stops hosting or leaves the host's game.
func leave() -> void:
	var was: String = role
	_close()
	if was == "client" or was == "joining":
		if main != null:
			main.net_back_offline("YOU LEFT THE GAME")
	elif was == "host" and main != null:
		main.net_stop_hosting()


func _close() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	role = "offline"
	peer_slots.clear()
	my_slot = -1
	_events.clear()
	_targeted.clear()
	status_changed.emit()


# --- Connection callbacks ---------------------------------------------------------------

func _on_peer_connected(_id: int) -> void:
	pass # the host waits for the client's hello


func _on_peer_disconnected(id: int) -> void:
	if role != "host" or not peer_slots.has(id):
		return
	var slot: int = int(peer_slots[id])
	peer_slots.erase(id)
	_targeted.erase(id)
	if main != null:
		main.net_remove_remote(slot)
	status_changed.emit()


func _on_connected() -> void:
	_c_hello.rpc_id(1, build_tag())


func _on_connect_failed() -> void:
	_close()
	if main != null:
		main.net_back_offline("COULD NOT REACH THE HOST")


func _on_server_lost() -> void:
	var was: String = role
	_close()
	if main != null and (was == "client" or was == "joining"):
		main.net_back_offline("THE HOST LEFT THE GAME")


# --- Client -> host ---------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _c_hello(tag: String) -> void:
	if role != "host" or main == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	if tag != build_tag():
		_s_reject.rpc_id(id, "DIFFERENT GAME VERSION: BOTH OF YOU NEED THE LATEST BUILD")
		return
	if main.players.size() >= 4:
		_s_reject.rpc_id(id, "THAT GAME IS FULL (4 BOTS)")
		return
	var slot: int = main.net_add_remote(id)
	peer_slots[id] = slot
	_s_welcome.rpc_id(id, slot, lseq, main.net_level_spec(), main.net_team(), main.net_snapshot())
	status_changed.emit()


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _c_input(state: Array) -> void:
	if role != "host" or main == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	if peer_slots.has(id):
		main.net_remote_input(int(peer_slots[id]), state)


# --- Host -> client ---------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _s_reject(reason: String) -> void:
	_close()
	if main != null:
		main.net_back_offline(reason)


@rpc("authority", "call_remote", "reliable")
func _s_welcome(slot: int, level_seq: int, spec: Dictionary, team: Dictionary, snap: Array) -> void:
	if role != "joining" or main == null:
		return
	role = "client"
	my_slot = slot
	lseq = level_seq
	main.net_enter_client(spec, team)
	main.net_apply_snapshot(snap, true)
	status_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _s_level(level_seq: int, spec: Dictionary) -> void:
	if role != "client" or main == null:
		return
	lseq = level_seq
	main.net_load_level(spec)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _s_snap(level_seq: int, snap: Array) -> void:
	if role == "client" and main != null and level_seq == lseq:
		main.net_apply_snapshot(snap, false)


@rpc("authority", "call_remote", "reliable")
func _s_events(level_seq: int, batch: Array) -> void:
	if role != "client" or main == null:
		return
	for ev: Variant in batch:
		var e: Array = ev
		# Effects from the last level would land in the wrong place; toasts and results still count.
		if level_seq != lseq and String(e[0]) not in ["toast", "results", "team"]:
			continue
		main.net_apply_event(String(e[0]), e[1] as Array)


@rpc("authority", "call_remote", "reliable")
func _s_team(team: Dictionary) -> void:
	if role == "client" and main != null:
		main.net_apply_team(team)


# --- Host: sending ----------------------------------------------------------------------

## Queues an event for every client (or every client but skip_slot's owner).
func ev(kind: String, args: Array) -> void:
	if relaying():
		_events.append([kind, args, skip_slot])


## Queues an event for the client that owns `slot` only.
func ev_to(slot: int, kind: String, args: Array) -> void:
	if role != "host":
		return
	for id: Variant in peer_slots.keys():
		if int(peer_slots[id]) == slot:
			if not _targeted.has(id):
				_targeted[id] = []
			(_targeted[id] as Array).append([kind, args])


func level_changed() -> void:
	if role != "host":
		return
	lseq += 1
	_events.clear()
	for id: Variant in peer_slots.keys():
		_s_level.rpc_id(int(id), lseq, main.net_level_spec())


func team_changed() -> void:
	if role != "host":
		return
	for id: Variant in peer_slots.keys():
		_s_team.rpc_id(int(id), main.net_team())


func _process(delta: float) -> void:
	if main == null:
		return
	if role == "host" and not peer_slots.is_empty():
		_snap_t -= delta
		if _snap_t <= 0.0:
			_snap_t = SNAPSHOT_RATE
			var snap: Array = main.net_snapshot()
			for id: Variant in peer_slots.keys():
				_s_snap.rpc_id(int(id), lseq, snap)
		_flush()
	elif role == "client":
		_c_input.rpc_id(1, main.net_local_input())


func _flush() -> void:
	for id: Variant in peer_slots.keys():
		var slot: int = int(peer_slots[id])
		var batch: Array = []
		for e: Variant in _events:
			var ea: Array = e
			if int(ea[2]) != slot:
				batch.append([ea[0], ea[1]])
		if _targeted.has(id):
			batch.append_array(_targeted[id] as Array)
		if not batch.is_empty():
			_s_events.rpc_id(int(id), lseq, batch)
	_events.clear()
	_targeted.clear()
