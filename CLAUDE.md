# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Dungeon Crawler (working title) is a Godot 4.7 (GDScript) isometric action RPG. The player is a gorilla robot with energy blades that slide out of its forearms and a mouth cannon. Players start on a hub ship, deploy to a map, kill the boss, extract, and spend scrap on upgrades. Co-op is drop-in local for up to 4 players, plus online drop-in/drop-out co-op by IP (**Online co-op** below). Everything is generated in code: tile textures, sculpted character models, effects and sounds. The only file assets are the font (`assets/fonts/`, OFL) and `icon.svg`. Controls and the loop are in `README.md`.

## Commands

`godot` below means the Godot 4.7.x editor binary.

```bash
godot --headless --path . --import                          # fresh clone, or after adding a class_name script
godot --headless --path . --quit-after 30 -- --smoke-test   # must print DUNGEON_SMOKE_TEST_PASSED, zero script errors
godot --path .                                              # play
```

- There's no unit-test framework. The smoke test, `_run_smoke_test()` at the bottom of `scripts/main.gd`, is the only automated check. It runs synchronously, because `--quit-after 30` counts frames, not seconds. It drives everything with direct calls: `hud.press(id)` presses menu rows, `_update_hub()` and `_update_mission(dt)` advance the game, and `LevelMap.simulate(seconds)` steps every entity at a fixed 1/60 s. The player bot is set `scripted`, so it reads its input from `sim`, e.g. `{"aim": Vector3, "melee": true}`. A failed `_check` pushes an error and exits 1 without printing PASSED. If you rename a method it calls, update it there. If you add an enemy, station, shop item or mod, add a check.
- The smoke test calls `Game.use_smoke_save()` first, so it writes `user://dungeon_smoke_test_save.json` and never touches the real save.
- CI (`.github/workflows/build.yml`) runs the smoke test on PRs and on pushes to `main`, on Windows. It auto-merges PRs from `jay-zimphy`, `justgetjay` and `mwgit993` once it passes (draft PRs are skipped), then exports `DungeonCrawler-Windows.zip` (pck plus the editor exe, as in Matt's other repos) and republishes the `latest` release. A second job, `build-macos`, runs after it: the smoke test on macOS, then `DungeonCrawler-macOS.zip`, which is the official Godot.app with the game's pck at `Contents/Resources/Godot.pck` (the binary runs a pck there on launch), renamed, re-signed ad hoc and checked by running its smoke test, added to the same release. So smoke-test locally before opening a PR.

## Code conventions

- Use explicit static types everywhere. Don't use `:=` on a `Variant` (Dictionary lookups, untyped arrays); cast instead, e.g. `String(d["id"])` or `float(stats["hp"])`.
- The whole scene tree is built in code. `scenes/main.tscn` is one `Node` with `main.gd`. The scripts use `class_name` (`Main`, `LevelMap`, `GorillaBot`, `RobotEnemy`, `Rig`, `GorillaRig`, `EnemyRig`, `Sculpt`, `Bolt`, `Pickup`, `Prop`, `Station`, `Decor`, `Fx`, `CameraRig`, `Hud`, `Balance`, `Maps`, `MapGen`), so run `--import` after adding one.
- All gameplay numbers live in `scripts/balance.gd`, and maps are text grids in `scripts/maps.gd` (legend at the top). Keep tunables there rather than inline.
- Input is polled per device, with no InputMap actions. P1 is keyboard/mouse plus joypad 0, and other pads join with START (`main._poll_joins`). Menus are real `Button`s. The d-pad, stick and arrow keys move the selection through the built-in `ui_up` / `ui_down` actions, and Enter / Space press it (`ui_accept`). Godot 4.7's `ui_accept` and `ui_cancel` don't include a pad's A and B, so `main._unhandled_input` handles them: A presses the selected row (`hud.press_focused`), and B (or START in the pause menu) closes the menu like Esc does.
- Text uses Press Start 2P at `font_size` 8, or 16 for titles. The game renders at 640x360 (`window/stretch/mode="viewport"`, integer scale) with nearest filtering, so HUD coordinates are in that pixel space.

## Architecture

**Autoloads:** `Game` (progress, save/load, upgrade-adjusted stats such as `max_hp()`, `melee_mult()` and `mission_tier()`), `Art` (tile textures painted per tileset, cached materials and primitive meshes for props, the floor, wall and character shaders, the UI theme), `Sfx` (synthesized `AudioStreamWAV`s; `Sfx.play(name)` with an unknown name is silent), `Net` (online co-op, below).

**`main.gd` (`Main`)** owns the `World` node, which holds the current `LevelMap`, a `Players` node and the `CameraRig`. It also owns the `Hud`. `mode` is `hub`, `mission` or `results`. `go_hub()` and `start_mission(id)` rebuild the level. Players persist across levels and are moved with `move_level`. Normal play wraps level changes in `_transition` (fade); the smoke test does them instantly. Pausing sets `world.process_mode = DISABLED`, and the HUD runs with `PROCESS_MODE_ALWAYS`. Station menus fill their rows from `Balance` (`_shop_entries`, `_aug_entries`, `_lab_entries`, `_mission_entries`), and purchases go through `_buy` and `_after_purchase`.

**Random maps** (Matt's request): `start_mission` asks `Maps.mission_def(id, seed)` for the mission with a fresh layout from `MapGen` (`scripts/map_gen.gd`), using a new random seed each run (`Main.forced_seed` pins it; the smoke test sets it). MapGen writes rows in the same legend as the hand-made maps, so nothing downstream changes: rooms (start room in one corner, boss room opposite), 3-wide corridors along a spanning tree plus loops, room layouts (pillars, machines, pits or lava pools, loot), the ash map's lava river, robots weighted toward the far rooms, crates, caches and kits. Then it checks that everything can be reached from P and rerolls if not. The start room stays clear east of P and the boss has open floor around it, which the smoke test relies on. A mission's `"gen"` dict tunes it (size, robot count and mix, layout weights, river); its `rows` are the fallback and what seed 0 gives. Same seed, same map on any machine (integer maths and a seeded RNG): the online level spec carries `"seed"`, and decor randomness in `LevelMap._place_things` adds the seed too. About 10 ms per map.

**`LevelMap`** builds one map from a `Maps` entry:
- **Floor**: one plane whose texture is composited from tile images, with baked edge shading. Glow tiles (pits, cracks) pulse in the floor shader.
- **Walls**: walls that touch open tiles are drawn as MultiMeshes. Their collision is merged into one box per row run, and pits get invisible collision too.
- **Props and spawns**: decor, crates (`Prop`), enemies, stations and the extraction pad.
- **Pathfinding**: an `AStarGrid2D` (`find_path`, `walkable`).
- **World helpers**: entities share `hit_arc`, `hit_circle`, `hurt_players`, `spawn_bolt`, `spawn_scrap` and `nearest_player`.
- **Counters**: `counters` tallies events (shots, slams, charges) for the smoke test.

The wall shader dithers away wall pixels that sit between the camera and a player (`players` uniform, set every frame in `_process`). Custom shaders must give colour samplers `source_color`, or the sRGB tile colours render washed out.

**Entities:** each entity has a `step(dt)` method that its `_process` calls, so `simulate()` can fast-forward them. They move with their own `_slide()` built on `move_and_collide`, not `move_and_slide`, so movement is deterministic for any dt.
- **`GorillaBot`**: the player. Its actions are `_melee` (arm blade slashes, alternating arms, out to `Balance.MELEE_RANGE` across `MELEE_ARC`, each leaving an `Fx.slash` trail, plus a two-bladed ground slam on every `COMBO_EVERY`th), `_fire_cannon`, dash and `use_kit`. Its model is a `GorillaRig` (`rig`), told about each action (`slash`, `slam`, `fire`, `hurt`, `dash`, `knock_down`, `revive`) and animated with `rig.animate()` every step. The rig's blades (Matt's request: a weapon that comes out of the arms, with real reach) are glowing parts on emitters on the forearms: they shoot out on an attack, stay out for `GorillaRig.BLADE_HOLD` with the arms raised in a guard, then slide back in (`blades_out()`). Damage lands on the press; the arm's sweep and the trail (`Fx._delay`) follow within about 0.1 s. A blinking rig after a hit is the invulnerability flicker (`_iframes`), not a bug.
- **`RobotEnemy`**: one script for every kind, with stats in `Balance.ENEMIES`. Its states are SLEEP → CHASE → WINDUP → RECOVER, plus CHARGE. `_think()` picks attacks per kind. Telegraphs are red ground decals. Bosses have phase 2 below half HP and summon capped minions (`minion = true`, little scrap). Its model is an `EnemyRig` (`rig`): `_animate()` passes it the state, the wind-up progress and the action, and it plays the strike when the state leaves WINDUP.
- **`Bolt`**: distance-checked projectiles in sub-steps, with no physics bodies.
- **`Pickup`**: scrap that flies to the nearest bot, and repair kits.
- **`Prop`**: breakable crates and caches. Breaking one frees its A* cell.
- **`Fx`**: self-freeing effects.

**Character models** look like HD-2D pixel sprites that can still turn in any direction:
- **`Sculpt`** builds a smooth mesh from soft primitives (`blob()` is a superellipsoid, `tube()` a smooth tube with round caps) with colours in the vertices. `Sculpt.cached(key, build)` builds each mesh once, so every enemy of a kind shares them. The gorilla's team-coloured meshes are cached per colour.
- **`Rig`** (base of `GorillaRig` and `EnemyRig`) is a tree of joints holding sculpted parts and glowing parts (eyes, mouths, cores; `Art.glow_mat`, no outline). It owns the shared effects: hit flash, a squash-and-stretch spring on `root` (`impact()`), recoil tilt (`recoil()`) and blinking. Every animation is code-driven from time and state, with nothing keyframed.
- **`Art.CHAR_SHADER`** shades sculpted parts with three hard light bands and a rim highlight along the top of the silhouette. Its `next_pass`, `CHAR_OUTLINE_SHADER`, is an inverted hull grown a fixed number of screen pixels, so the outline stays 1 px at the 640x360 render size. Each character has its own `Art.char_material()`, so it flashes on its own.
- The smoke test's `_smoke_rigs` builds every rig and checks its parts, its height, the hit flash and each kind's strike.

Physics layers: 1 world, 2 players, 4 enemies. Actors only collide with the world, and push each other apart with `_separation()`.

**Difficulty:** an enemy's HP and damage are `Balance.hp_mult(tier, players)` and `damage_mult(tier, players)`. A mission's tier is its base `MISSION_TIER` plus one per clear. When a player joins mid-mission, `LevelMap.set_player_count` rescales living enemies.

## Online co-op

Matt's request: Minecraft Dungeons-style drop-in / drop-out, join by IP (UDP port `Net.PORT` 24565; Tailscale or a port forward across the internet). `scripts/autoload/net.gd` is the connection and the RPCs; `main.gd`'s "Online co-op" section and each entity's `net_*` methods do the rest.

- **The host runs the real game**, unchanged. A client's bot on the host is a `GorillaBot` with `net_mode = "remote"`: it stands where its client says (`net_state`, sent every frame by `Net._c_input`) and fights with the client's buttons through the host's own `_melee` / `_fire_cannon` / `use_kit`. Kit and interact presses travel as counters, so a dropped packet can't lose a tap.
- **A client draws the host's world.** Its level is built from the same map with `LevelMap.puppet = true`: nothing in it thinks. Robots, pickups and crates follow the snapshots (`main.net_snapshot`, `LevelMap.net_entities`, about 20 a second, unreliable) and are smoothed toward them; robots are numbered in map order (`net_id`), so the ids match without being sent. Other players' bots are `"puppet"`; the client's own bot is `"local"` and moves itself (walking and dashing feel instant), unless the host moves it (`tp_seq` bumps in `move_level` and `revive`).
- **Events** go out every frame (reliable): every `Fx` effect and `Sfx` sound the host plays (both relay themselves, except UI sounds), toasts, camera shake, animation cues (`GorillaBot._rig`, `"erig"` from `RobotEnemy`), bolts (`"bolt"` / `"bolt_x"`: a client flies its own copy), crate hits and results. `Net.skip_slot` keeps one client's own dash from echoing back to it; `Net.ev_to` reaches one client (knockback via `GorillaBot.push_back`, "host only" toasts). Each level gets a sequence number (`Net.lseq`) so stale snapshots and effects are dropped.
- **Progress works like local co-op**: the host's save is the team's. A client mirrors it (`Game.apply_team`, sent on joining, with every level and after purchases via `Net.team_changed`), `Game.save_game` does nothing while `Net.is_client()`, and `Game.restore_own` reloads the client's own save when it leaves (it saves just before joining). Only the host can use the Ark's stations; a client gets a toast.
- Online, pausing doesn't freeze the world and the host's mission logic keeps running with a menu open. `_set_players_input` never touches remote bots.
- **When adding things**: bump `Net.PROTOCOL` when an event, rig cue or effect changes, so mixed builds refuse to connect (2 = arm blades, 3 = random maps: the level spec carries the map seed). Effects through `Fx` and sounds through `Sfx` reach clients for free. A new rig cue on a player goes through `_rig()`; on a robot, add a `Net.ev("erig", ...)` next to it. A new robot state shows up through `net_entry` / `net_apply` (add a telegraph there if its wind-up has one). Anything that moves a player by force must bump `tp_seq` or push through `push_back`. A new kind of entity needs a snapshot entry and a puppet mode. A new purchase must call `Net.team_changed()` (`_after_purchase` does).
- The smoke test's `_smoke_net` covers it without sockets: the snapshot survives `var_to_bytes`, a pretend client's bot drops in, moves, slashes, fires, heals and dodges on the host, a puppet level built from the snapshot matches the host's robots, crates and pickups, every captured event replays, leaving scales robots back, a local bot walks and counts presses, a client never writes its save, and hosting opens the port. Two real processes on localhost were used to test joining in the hub and mid-mission, results, leaving and the host quitting.

## Content touchpoints

- **Enemy kind:** add an entry to `Balance.ENEMIES`, a `_build_<kind>` model and an `_anim_<kind>` branch in `enemy_rig.gd`, its height range and strike in `main._smoke_rigs`, and a branch in `_think()` (plus the attack in `_update_windup` if it's new). For a map character, add it to `LevelMap.ENEMY_CHARS`, the legend in `maps.gd`, and the legend string in `main._smoke_check_maps`.
- **Mission:** add a `Maps.MISSIONS` entry (fallback rows, tileset `foundry`/`ash`/`ship`, boss kind, and a `"gen"` dict for MapGen) plus `Balance.MISSION_TIER` and `MISSION_UNLOCK`. The smoke test checks the hand-made map's shape, boss and unlock rule, and that the boss is reachable; `_smoke_check_mapgen` lays out 40 seeds per mission and checks each one independently of MapGen (one P/B/X, the boss, the pad, every robot, kit and crate reachable, no robot next to P, the floor east of P clear, the boss not boxed in), plus that seeds are repeatable and differ.
- **Station:** add a `Balance.STATION_UNLOCK` entry, a model in `Station.setup` plus `TITLES`, a character in `LevelMap.STATION_CHARS`, and a menu in `main.open_station_menu`.
- **Shop item / augment / mod:** add a `Balance.SHOP` / `AUGMENTS` / `LAB` entry. Its effect goes in `Game` getters (augments), `main._on_*_pick` (consumables) or `GorillaBot` (mods, via `Game.has_mod`).
- **Tileset:** add a `PALETTES` entry and painters in `Art.tiles()`. `Decor.pillar` and `Decor.console` branch on the tileset.
