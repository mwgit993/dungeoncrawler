# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Dungeon Crawler (working title) is a Godot 4.7 (GDScript) isometric action RPG. The player is a gorilla robot with an arm smash and a mouth cannon. Players start on a hub ship, deploy to a map, kill the boss, extract, and spend scrap on upgrades. Co-op is drop-in local for up to 4 players; online is planned. Everything is generated in code: tile textures, 3D models built from primitive meshes, effects and sounds. The only file assets are the font (`assets/fonts/`, OFL) and `icon.svg`. Controls and the loop are in `README.md`.

## Commands

`godot` below means the Godot 4.7.x editor binary.

```bash
godot --headless --path . --import                          # fresh clone, or after adding a class_name script
godot --headless --path . --quit-after 30 -- --smoke-test   # must print DUNGEON_SMOKE_TEST_PASSED, zero script errors
godot --path .                                              # play
```

- There's no unit-test framework. The smoke test, `_run_smoke_test()` at the bottom of `scripts/main.gd`, is the only automated check. It runs synchronously, because `--quit-after 30` counts frames, not seconds. It drives everything with direct calls: `hud.press(id)` presses menu rows, `_update_hub()` and `_update_mission(dt)` advance the game, and `LevelMap.simulate(seconds)` steps every entity at a fixed 1/60 s. The player bot is set `scripted`, so it reads its input from `sim`, e.g. `{"aim": Vector3, "melee": true}`. A failed `_check` pushes an error and exits 1 without printing PASSED. If you rename a method it calls, update it there. If you add an enemy, station, shop item or mod, add a check.
- The smoke test calls `Game.use_smoke_save()` first, so it writes `user://dungeon_smoke_test_save.json` and never touches the real save.
- CI (`.github/workflows/build.yml`) runs the smoke test on PRs and on pushes to `main`. A push to `main` also exports `DungeonCrawler-Windows.zip` (pck plus the editor exe, as in Matt's other repos) and republishes the `latest` release. CI doesn't auto-merge PRs.

## Code conventions

- Use explicit static types everywhere. Don't use `:=` on a `Variant` (Dictionary lookups, untyped arrays); cast instead, e.g. `String(d["id"])` or `float(stats["hp"])`.
- The whole scene tree is built in code. `scenes/main.tscn` is one `Node` with `main.gd`. The scripts use `class_name` (`Main`, `LevelMap`, `GorillaBot`, `RobotEnemy`, `Bolt`, `Pickup`, `Prop`, `Station`, `Decor`, `Fx`, `CameraRig`, `Hud`, `Balance`, `Maps`), so run `--import` after adding one.
- All gameplay numbers live in `scripts/balance.gd`, and maps are text grids in `scripts/maps.gd` (legend at the top). Keep tunables there rather than inline.
- Input is polled per device, with no InputMap actions. P1 is keyboard/mouse plus joypad 0, and other pads join with START (`main._poll_joins`). Menus are real `Button`s and use the built-in `ui_*` actions. `ui_cancel` (Esc/B) closes them.
- Text uses Press Start 2P at `font_size` 8, or 16 for titles. The game renders at 640x360 (`window/stretch/mode="viewport"`, integer scale) with nearest filtering, so HUD coordinates are in that pixel space.

## Architecture

**Autoloads:** `Game` (progress, save/load, upgrade-adjusted stats such as `max_hp()`, `melee_mult()` and `mission_tier()`), `Art` (tile textures painted per tileset, cached materials and primitive meshes, the floor and wall shaders, the UI theme), `Sfx` (synthesized `AudioStreamWAV`s; `Sfx.play(name)` with an unknown name is silent).

**`main.gd` (`Main`)** owns the `World` node, which holds the current `LevelMap`, a `Players` node and the `CameraRig`. It also owns the `Hud`. `mode` is `hub`, `mission` or `results`. `go_hub()` and `start_mission(id)` rebuild the level. Players persist across levels and are moved with `move_level`. Normal play wraps level changes in `_transition` (fade); the smoke test does them instantly. Pausing sets `world.process_mode = DISABLED`, and the HUD runs with `PROCESS_MODE_ALWAYS`. Station menus fill their rows from `Balance` (`_shop_entries`, `_aug_entries`, `_lab_entries`, `_mission_entries`), and purchases go through `_buy` and `_after_purchase`.

**`LevelMap`** builds one map from a `Maps` entry:
- **Floor**: one plane whose texture is composited from tile images, with baked edge shading. Glow tiles (pits, cracks) pulse in the floor shader.
- **Walls**: walls that touch open tiles are drawn as MultiMeshes. Their collision is merged into one box per row run, and pits get invisible collision too.
- **Props and spawns**: decor, crates (`Prop`), enemies, stations and the extraction pad.
- **Pathfinding**: an `AStarGrid2D` (`find_path`, `walkable`).
- **World helpers**: entities share `hit_arc`, `hit_circle`, `hurt_players`, `spawn_bolt`, `spawn_scrap` and `nearest_player`.
- **Counters**: `counters` tallies events (shots, slams, charges) for the smoke test.

The wall shader dithers away wall pixels that sit between the camera and a player (`players` uniform, set every frame in `_process`). Custom shaders must give colour samplers `source_color`, or the sRGB tile colours render washed out.

**Entities:** each entity has a `step(dt)` method that its `_process` calls, so `simulate()` can fast-forward them. They move with their own `_slide()` built on `move_and_collide`, not `move_and_slide`, so movement is deterministic for any dt.
- **`GorillaBot`**: the player. Its model is boxes on pivot nodes animated in code, and its actions are `_melee` (punch combo, slam on every `COMBO_EVERY`th), `_fire_cannon`, dash and `use_kit`.
- **`RobotEnemy`**: one script for every kind, with stats in `Balance.ENEMIES`. Its states are SLEEP → CHASE → WINDUP → RECOVER, plus CHARGE. `_think()` picks attacks per kind. Telegraphs are red ground decals. Bosses have phase 2 below half HP and summon capped minions (`minion = true`, little scrap).
- **`Bolt`**: distance-checked projectiles in sub-steps, with no physics bodies.
- **`Pickup`**: scrap that flies to the nearest bot, and repair kits.
- **`Prop`**: breakable crates and caches. Breaking one frees its A* cell.
- **`Fx`**: self-freeing effects.

Physics layers: 1 world, 2 players, 4 enemies. Actors only collide with the world, and push each other apart with `_separation()`.

**Difficulty:** an enemy's HP and damage are `Balance.hp_mult(tier, players)` and `damage_mult(tier, players)`. A mission's tier is its base `MISSION_TIER` plus one per clear. When a player joins mid-mission, `LevelMap.set_player_count` rescales living enemies.

## Content touchpoints

- **Enemy kind:** add an entry to `Balance.ENEMIES`, a `_build_<kind>` model and an `_animate` branch in `robot_enemy.gd`, and a branch in `_think()` (plus the attack in `_update_windup` if it's new). For a map character, add it to `LevelMap.ENEMY_CHARS`, the legend in `maps.gd`, and the legend string in `main._smoke_check_maps`.
- **Mission:** add a `Maps.MISSIONS` entry (rows, tileset `foundry`/`ash`/`ship`, boss kind) plus `Balance.MISSION_TIER` and `MISSION_UNLOCK`. The smoke test checks the map's shape, boss and unlock rule, and that the boss is reachable.
- **Station:** add a `Balance.STATION_UNLOCK` entry, a model in `Station.setup` plus `TITLES`, a character in `LevelMap.STATION_CHARS`, and a menu in `main.open_station_menu`.
- **Shop item / augment / mod:** add a `Balance.SHOP` / `AUGMENTS` / `LAB` entry. Its effect goes in `Game` getters (augments), `main._on_*_pick` (consumables) or `GorillaBot` (mods, via `Game.has_mod`).
- **Tileset:** add a `PALETTES` entry and painters in `Art.tiles()`. `Decor.pillar` and `Decor.console` branch on the tileset.
