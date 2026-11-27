# Dungeon Crawler

An isometric dungeon crawler (working title) in Godot 4.7. You play a gorilla robot that smashes
with its arms and fires a plasma cannon from its mouth, fighting robot enemies across future
worlds. It has Brood War style maps and a 16-bit look: the 3D world renders at 640x360 and is
scaled up with crisp pixels. Everything is generated in code, including tiles, models, effects
and sounds. The only file assets are the Press Start 2P font (SIL Open Font License) and the icon.

This first build is a test bed for the gameplay loop: a hub ship and two maps.

## Play

Open the project in Godot 4.7 and press F5. Once this repo's CI has run on `main`, a Windows
build is published under Releases as `DungeonCrawler-Windows.zip`.

| | Keyboard + mouse | Controller |
| --- | --- | --- |
| Move | WASD / arrows | Left stick |
| Aim | Mouse | Right stick (or the way you walk) |
| Arm smash | Left click | X or RB |
| Mouth cannon | Right click | B or RT |
| Dash (dodges hits) | Space / Shift | A |
| Repair kit | Q | LB |
| Talk / use | E | Y |
| Pause | Esc | Start |

Every 3rd smash in a row is a two-fisted ground slam that hits all around you. The cannon uses
energy, which recharges when you stop firing. F11 toggles fullscreen.

**Co-op:** player 1 uses the keyboard/mouse or the first controller. Players 2-4 press START on
another controller to drop in at any time, and enemy HP and damage scale with the number of bots.
A downed bot reboots next to a teammate after a few seconds, and if everyone is down the mission
fails. Online play isn't in yet.

## The loop

1. **The Ark** (hub ship): walk up to a station and press E / Y.
   - **Mission table**: deploy to a map.
   - **Quartermaster** (open from the start): repair kits, kit racks, and a shield cell for the
     next mission.
   - **Augment Bay** (unlocks after clearing Derelict Foundry): permanent upgrades to arms,
     cannon, plating, legs and energy.
   - **Weapons Lab** (unlocks after clearing Ashfall Reactor): mods that change your weapons.
     Splitter Jaw fires 3 bolts, Seismic Fists makes slams stun, Arc Teeth makes bolts chain, and
     Magnet Core pulls scrap from further away.
2. **A mission**: robots sleep where the map places them until you get close. Break crates and
   caches for scrap. Destroy the boss to power up the extraction pad, then step onto it.
3. **Results**: you keep all of a cleared mission's scrap, or half of it if your bots are destroyed
   or you abandon. Each clear unlocks the next map or station and raises that map's threat tier, so
   enemies get tougher and drop more scrap.

Maps:
- **Derelict Foundry**: a metal installation with slag channels. Its boss is FOREMAN-9, a loader
  that slams, charges down a red lane, and calls in scuttlers.
- **Ashfall Reactor**: lava fields with a river you cross on bridges. Its boss is the MAGMA
  WARDEN, which slams, fires rings of bolts, and calls in gunners.

Enemies:
- **Scuttler**: rushes you.
- **Gunner**: keeps its distance and fires bursts.
- **Bruiser**: winds up a ground slam. Stay out of the red ring.

## Tweaking

- **`scripts/balance.gd`**: every gameplay number. It covers player stats, weapon damage and
  cooldowns, each enemy's stats, threat-tier and co-op scaling, shop prices, which mission unlocks
  what, and the upgrade and mod effects.
- **`scripts/maps.gd`**: the hub and both maps, drawn as text grids. Each character is one tile:
  `#` wall, `s`/`g`/`b` enemies, `c` crate, `P` start, `X` extraction pad and so on. The full
  legend is at the top of the file. Change the text to move walls or add enemies. Every row of a
  map must be the same length, and the smoke test checks this.

## Smoke test

```bash
godot --headless --path . --import
godot --headless --path . --quit-after 30 -- --smoke-test   # prints DUNGEON_SMOKE_TEST_PASSED
```

It plays through the whole loop with scripted input: the shops, both missions, every enemy and
boss, extraction, failing, the upgrades and mods, co-op scaling, and save/load. It uses its own
save file, so it never touches your progress. CI runs it on every pull request.
