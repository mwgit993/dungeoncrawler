class_name Balance
extends RefCounted

## Every gameplay number in one place, so the loop can be tuned without digging through code.
## Distances are in metres (one map tile is TILE metres across), times in seconds,
## damage and HP in plain points.

# --- World -----------------------------------------------------------------------------
const TILE: float = 2.0
const WALL_H: float = 1.6

# --- Camera ----------------------------------------------------------------------------
const CAMERA_SIZE: float = 17.0       # metres of world visible top to bottom
const CAMERA_MAX_SIZE: float = 30.0   # zooms out up to this to keep every co-op player on screen
const CAMERA_PITCH: float = 30.0      # degrees down from horizontal (30 = classic 2:1 isometric)
const CAMERA_YAW: float = 45.0
const CAMERA_FOLLOW: float = 7.0      # higher = camera catches up faster

# --- Gorilla bot -----------------------------------------------------------------------
const PLAYER_HP: float = 100.0
const PLAYER_SPEED: float = 6.0
const PLAYER_ACCEL: float = 55.0
const DASH_SPEED: float = 17.0
const DASH_TIME: float = 0.17
const DASH_COOLDOWN: float = 0.9
const HIT_IFRAMES: float = 0.45       # invulnerable this long after taking a hit

const MELEE_DAMAGE: float = 24.0
const MELEE_RANGE: float = 2.5
const MELEE_ARC: float = 120.0        # degrees, centred on the aim direction
const MELEE_COOLDOWN: float = 0.36
const MELEE_KNOCKBACK: float = 7.0
const COMBO_EVERY: int = 3            # every 3rd punch in a row is a two-fisted ground slam
const COMBO_WINDOW: float = 1.1       # punches further apart than this restart the count
const SLAM_RADIUS: float = 3.4
const SLAM_MULT: float = 1.6          # slam damage = MELEE_DAMAGE * this

const CANNON_DAMAGE: float = 15.0
const CANNON_SPEED: float = 24.0
const CANNON_RANGE: float = 18.0
const CANNON_COOLDOWN: float = 0.2
const ENERGY_MAX: float = 100.0
const CANNON_ENERGY: float = 11.0     # energy per mouth-cannon shot
const ENERGY_REGEN: float = 30.0      # per second
const ENERGY_REGEN_DELAY: float = 0.5 # regen pauses this long after a shot

const KIT_HEAL: float = 45.0
const KITS_BASE_MAX: int = 3          # repair kits you can carry before buying Kit Racks
const SHIELD_CELL_HP: float = 40.0
const RESPAWN_TIME: float = 8.0       # co-op: a downed bot reboots next to a teammate
const PICKUP_RADIUS: float = 2.2      # scrap flies to you from this far
const FAIL_SCRAP_KEPT: float = 0.5    # share of a failed mission's scrap you keep

# --- Enemies ---------------------------------------------------------------------------
# hp, speed, damage per hit, range = attack reach, cooldown between attacks,
# aggro = wake-up distance, radius = body size, scrap = drop range (min, max),
# heft = knockback resistance (0 = flies, 1 = immovable).
const ENEMIES: Dictionary = {
	"scuttler": {"name": "SCUTTLER", "hp": 32.0, "speed": 5.0, "damage": 8.0, "range": 1.3,
		"cooldown": 0.9, "aggro": 11.0, "radius": 0.5, "scrap": Vector2i(2, 4), "heft": 0.0},
	"gunner": {"name": "GUNNER", "hp": 48.0, "speed": 3.0, "damage": 10.0, "range": 13.0,
		"cooldown": 1.9, "aggro": 14.0, "radius": 0.6, "scrap": Vector2i(4, 7), "heft": 0.3,
		"keep_away": 8.0, "shot_speed": 11.0, "burst": 3, "burst_gap": 0.18},
	"bruiser": {"name": "BRUISER", "hp": 170.0, "speed": 2.5, "damage": 26.0, "range": 2.4,
		"cooldown": 2.4, "aggro": 10.0, "radius": 0.95, "scrap": Vector2i(10, 15), "heft": 0.8,
		"windup": 0.75, "slam_radius": 2.9},
	# Foundry boss: charges, slams and calls scuttlers.
	"foreman": {"name": "FOREMAN-9", "hp": 950.0, "speed": 3.0, "damage": 24.0, "range": 3.2,
		"cooldown": 1.6, "aggro": 13.0, "radius": 1.5, "scrap": Vector2i(110, 140), "heft": 1.0,
		"windup": 0.8, "slam_radius": 3.6, "charge_speed": 15.0, "summon": "scuttler",
		"summon_every": 9.0, "max_minions": 6},
	# Ashfall boss: bolt rings, slams and calls gunners.
	"warden": {"name": "MAGMA WARDEN", "hp": 1400.0, "speed": 2.4, "damage": 22.0, "range": 3.0,
		"cooldown": 1.5, "aggro": 13.0, "radius": 1.6, "scrap": Vector2i(170, 210), "heft": 1.0,
		"windup": 0.9, "slam_radius": 3.8, "shot_speed": 9.0, "nova": 14, "summon": "gunner",
		"summon_every": 11.0, "max_minions": 4},
}
const CRATE_HP: float = 20.0
const CRATE_SCRAP: Vector2i = Vector2i(3, 8)
const CACHE_SCRAP: Vector2i = Vector2i(35, 50)  # the "$" stashes on the maps

# --- Difficulty ------------------------------------------------------------------------
# A mission's threat tier = its base tier + 1 per previous clear (capped at MAX_TIER).
const MISSION_TIER: Dictionary = {"foundry": 1, "ashfall": 2}
const MAX_TIER: int = 10
const TIER_HP: float = 0.35       # each tier above 1 adds +35% enemy HP
const TIER_DAMAGE: float = 0.15   # ... +15% enemy damage
const TIER_SCRAP: float = 0.25    # ... +25% scrap
# Co-op scaling, indexed by how many bots are in the mission (index 0 is unused).
const COOP_HP: Array[float] = [1.0, 1.0, 1.65, 2.3, 2.95]
const COOP_DAMAGE: Array[float] = [1.0, 1.0, 1.1, 1.2, 1.3]
const COOP_SCRAP: Array[float] = [1.0, 1.0, 1.35, 1.7, 2.05]

# --- Hub stations ----------------------------------------------------------------------
# Which mission must be cleared once to open each station ("" = open from the start).
const STATION_UNLOCK: Dictionary = {
	"quartermaster": "", "augments": "foundry", "lab": "ashfall", "missions": "",
}
# Missions unlock the same way.
const MISSION_UNLOCK: Dictionary = {"foundry": "", "ashfall": "foundry"}

# Quartermaster: consumables. cost, then +step per level owned for levelled items.
const SHOP: Array[Dictionary] = [
	{"id": "kit", "name": "REPAIR KIT", "desc": "Restores %d HP. Q / LB in a mission.", "cost": 30},
	{"id": "kit_rack", "name": "KIT RACK", "desc": "Carry 1 more repair kit.", "cost": 120,
		"step": 90, "max": 3},
	{"id": "shield", "name": "SHIELD CELL", "desc": "Next mission starts with a %d HP shield.",
		"cost": 60},
]
# Augment Bay: permanent upgrades. "per" is the bonus per level, shown in the description.
const AUGMENTS: Array[Dictionary] = [
	{"id": "arms", "name": "HYDRAULIC ARMS", "desc": "+%d%% smash damage per level.", "per": 15,
		"cost": 80, "step": 70, "max": 5},
	{"id": "throat", "name": "PLASMA THROAT", "desc": "+%d%% cannon damage per level.", "per": 15,
		"cost": 80, "step": 70, "max": 5},
	{"id": "plating", "name": "TITAN PLATING", "desc": "+%d max HP per level.", "per": 20,
		"cost": 90, "step": 80, "max": 5},
	{"id": "servos", "name": "SERVO LEGS", "desc": "+%d%% speed and faster dash per level.",
		"per": 6, "cost": 70, "step": 60, "max": 4},
	{"id": "capacitor", "name": "CAPACITOR", "desc": "+%d energy and faster regen per level.",
		"per": 20, "cost": 70, "step": 60, "max": 4},
]
const SERVO_DASH_CD: float = 0.08     # dash cooldown -8% per Servo Legs level
const CAPACITOR_REGEN: float = 0.12   # energy regen +12% per Capacitor level
# Weapons Lab: one-off mods that change how the weapons behave.
const LAB: Array[Dictionary] = [
	{"id": "splitter", "name": "SPLITTER JAW", "desc": "Cannon fires a fan of 3 bolts (70% each).",
		"cost": 400},
	{"id": "seismic", "name": "SEISMIC FISTS", "desc": "Combo slams are 50% wider and stun.",
		"cost": 350},
	{"id": "arc", "name": "ARC TEETH", "desc": "Bolts arc to a second robot for 50% damage.",
		"cost": 450},
	{"id": "magnet", "name": "MAGNET CORE", "desc": "Pull scrap from 3x as far away.", "cost": 200},
]
const SPLITTER_SPREAD: float = 14.0   # degrees between the fan's bolts
const SPLITTER_MULT: float = 0.7
const SEISMIC_RADIUS: float = 1.5
const SEISMIC_STUN: float = 1.2
const ARC_MULT: float = 0.5
const ARC_RANGE: float = 6.0
const MAGNET_MULT: float = 3.0


## Enemy HP/damage/scrap multipliers for a tier and player count.
static func hp_mult(tier: int, players: int) -> float:
	return (1.0 + TIER_HP * float(tier - 1)) * COOP_HP[clampi(players, 1, 4)]


static func damage_mult(tier: int, players: int) -> float:
	return (1.0 + TIER_DAMAGE * float(tier - 1)) * COOP_DAMAGE[clampi(players, 1, 4)]


static func scrap_mult(tier: int, players: int) -> float:
	return (1.0 + TIER_SCRAP * float(tier - 1)) * COOP_SCRAP[clampi(players, 1, 4)]


## Price of the next level of a shop entry, given how many levels are owned.
static func price(entry: Dictionary, owned: int) -> int:
	return int(entry.get("cost", 0)) + int(entry.get("step", 0)) * owned
