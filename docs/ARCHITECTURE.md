# Tactical Strike — Architecture Contract

Round-based bomb-defusal FPS. Godot 4.5, GL Compatibility renderer, Android
(arm64). Offline vs bots. This file is the integration contract: every
subsystem is written against the interfaces here. Keep it current.

## Global rules

- GDScript, Godot 4.5 syntax, static typing where practical.
- Mobile perf: no per-frame allocations in gameplay code (no `new()`, no
  array/dict literals, no string building inside `_process`/`_physics_process`
  hot paths). Preallocate, use `Pools`.
- Never call `get_node()` with absolute paths across scenes; use groups,
  signals, or exported NodePaths.
- All UI must work by touch only. Portrait is unsupported; landscape only.
- Units: meters, seconds, m/s. 60 physics tps.

## Physics layers (project.godot)

1 world, 2 player, 3 bot, 4 hitbox, 5 projectile, 6 pickup, 7 smoke, 8 clip.
- Character movement bodies collide with world+clip and each other.
- Weapon rays: mask world|hitbox|smoke (smoke tested separately for vision).
- Hitboxes: StaticBody3D on layer 4 attached to bones, no collision with world.

## Autoloads (already present)

- `Settings` — user prefs (sensitivity, gyro, crosshair, HUD layout, preset).
- `GameState` — roster, score, phases, config, signals (see file).
- `Economy` — money, rewards, spending.
- `Persistence` — save file.
- `AudioMgr` — `register(id, stream)`, `play_3d(id, pos)`, `play_ui(id)`.
- `Pools` — `create_pool(key, scene, n)`, `acquire(key, parent)`, `release(node)`.
- `InputHub` (NEW) — bridge between touch UI / keyboard-mouse debug and the
  player controller.

## InputHub contract (src/autoload/input_hub.gd)

```gdscript
var move: Vector2            # local move intent, x=strafe right, y=forward, len<=1
var look_delta: Vector2      # accumulated look delta (pixels*sens), consumed by player
var fire_held: bool
var ads_held: bool           # toggled by button (state kept here)
var crouch_held: bool        # respects Settings.crouch_is_toggle (state kept here)
var jump_pressed: bool       # one-shot, consumed by player (consume_jump())
var reload_pressed: bool     # one-shot, consume_reload()
var interact_held: bool      # plant/defuse button
var switch_slot_request: int # -1 none; 0 primary 1 secondary 2 knife 3 grenade
var grenade_cycle_pressed: bool
func consume_look() -> Vector2   # returns and zeroes look_delta
func consume_jump() -> bool
func consume_reload() -> bool
func consume_switch() -> int
```

Touch controls WRITE these. Player controller READS via the consume API each
physics tick. Keyboard/mouse (editor debug) also writes them (WASD, mouse
captured, Space, C, R, 1-4). Buy/scoreboard/pause buttons are UI-level and do
not go through InputHub.

## Characters

`src/characters/character_base.gd` (class_name CharacterBase extends
CharacterBody3D) — shared by player and bots:

- exported: `team: int`, `player_id: int`
- health/armor: `health: float = 100`, `armor: float = 0`, `has_helmet: bool`
- `func take_damage(raw: float, zone: int, attacker_id: int, weapon_id: String,
   dir: Vector3, headshot_mult := 4.0) -> void` — applies zone multiplier
  (HEAD x4 helmet-reduced, CHEST x1, STOMACH x1.25, LIMB x0.75), armor absorb
  (armor halves body damage while durability lasts), emits `damaged`, `died`.
- signals: `damaged(amount, zone, attacker_id)`, `died(attacker_id, weapon_id,
  headshot)`
- inventory: `slots: Array` [primary_id, secondary_id, "knife", Array grenade
  ids], `ammo: Dictionary` weapon_id -> {mag, reserve}, `current_slot: int`
- `func speed_scale() -> float` — from current weapon def move_speed_mult,
  crouch, ads.
- movement constants: RUN 5.2, WALK_ADS 3.4, CROUCH 2.4 (all * weapon mult),
  JUMP 5.4, gravity from project (16), accel 60 ground / 12 air, decel 55.
- Zone enum: `enum Zone { HEAD, CHEST, STOMACH, LIMB }`.

Hitboxes: child `Hitboxes` node with BoneAttachment3D -> StaticBody3D (layer
4, no mask) + CollisionShape3D per zone; each StaticBody3D has metadata
`zone: int` and `char: NodePath` to the CharacterBase. Weapon rays read these
via `get_meta`.

`src/characters/player.gd` extends CharacterBase — reads InputHub, owns
camera rig: `CamPivot` (yaw on body, pitch on pivot, clamp ±89°), viewmodel
under camera. Full-body self mesh: head + arms hidden for own camera via bone
scale (done in Phase 2), legs visible when looking down.

`src/characters/dummy.gd` extends CharacterBase — Phase 1 shooting-range
target: stands still, respawns 3 s after death, reports damage taken via
floating text (optional).

## Weapons

`src/data/weapon_db.gd` (class_name WeaponDB, all-static). Weapon def is a
Dictionary with keys:
`id, display_name, category (WeaponDB.Cat enum: PISTOL/SMG/RIFLE/HEAVY/
KNIFE/GRENADE/GEAR), price, kill_reward, damage (per bullet), pellets (1
except shotgun 9), fire_rate (rounds/s), auto (bool), mag, reserve,
reload_time, draw_time, spread_base (deg), spread_move_add (deg at full
speed), spread_air_add, recoil_pattern (Array[Vector2] per-shot kick
deg (x=yaw drift, y=pitch up)), recoil_recovery (deg/s), move_speed_mult,
penetration (0..1 power; >0 can pierce thin walls with damage falloff),
range_falloff_start (m), range_falloff_end (m), falloff_min_mult,
tp_model (res path), fire_sfx, headshot_mult (default 4.0)`

Static funcs: `get_def(id) -> Dictionary`, `all_ids() -> Array`,
`ids_in_category(cat) -> Array`.

The 10 guns: p9, talon, snub (pistols) / viper45, mk9 (SMG) / ar77, br52
(DMR), sr1 (bolt sniper) (rifles) / breacher12 (shotgun), mule (auto-heavy)
(heavy). Plus knife, grenades (frag, flash, smoke, incendiary), gear (armor,
helmet, defusekit). Prices CS-like but original values.

`src/weapons/weapon.gd` (class_name Weapon extends Node3D) — runtime
instance on a character; owns firing state machine (ready/firing/reloading/
drawing), consumes ammo from owner CharacterBase, does hitscan:
- ray from a supplied Camera3D (player) or eye Node3D (bot), direction with
  spread + current recoil offset;
- mask world|hitbox; skips shooter; penetration: if hit surface and def
  penetration > 0, continue ray past thin obstacles (<=0.35 m) with damage
  * (0.5 * penetration);
- on hitbox hit → `CharacterBase.take_damage(...)`;
- emits `fired`, `ammo_changed(mag, reserve)`, `reload_started(t)`,
  `reload_finished`, `hit_confirmed(zone, died)` (for hitmarkers).
- Recoil state: `recoil_index` climbs per shot, decays after 0.25 s idle;
  exposes `current_spread_deg()` and `camera_kick()` Vector2 for the player
  camera and HUD crosshair.

## Match flow (scenes/game/match.tscn + src/game/match.gd)

match.gd loads the map scene by GameState.cfg_map, spawns the local player +
bots at team spawns, instantiates HUD, drives phase timers via GameState,
handles kills (economy rewards, kill feed), round wins, side swap, match end.
Phase 1 scope: FREE-RUN mode — no rounds; spawn player + 3 dummies, infinite
money, all weapons grantable.

Maps expose (script `src/game/map_info.gd` on map root, class_name MapInfo):
- `atk_spawns/def_spawns: Array[Marker3D]` (children of ATKSpawns/DEFSpawns)
- `bomb_sites: Dictionary {"A": Area3D, "B": Area3D}`
- `buy_zones: Dictionary {team_int: Area3D}`
- `nav_region: NavigationRegion3D`
- radar metadata: `radar_origin: Vector2` (world XZ of map top-left),
  `radar_scale: float` (world meters per radar px at 256 px)

## HUD (Phase 1 stub scenes/ui/hud.tscn)

CanvasLayer with: TouchControls (own scene), health/armor labels, ammo label,
crosshair (Control drawing 4 lines + dot from Settings + current spread from
weapon signal). Full HUD in Phase 4.

## Touch controls (scenes/ui/touch_controls.tscn, src/ui/touch_controls.gd)

- Left ~40% of screen: dynamic virtual stick (touch-down sets origin, drag
  sets InputHub.move, radius 120 px * hud_scale).
- Right ~60%: look area — drag rotates (writes InputHub.look_delta * Settings
  .look_sensitivity); multitouch safe (track pointer ids separately).
- Buttons (TouchScreenButton or Control+gui_input): Fire (right-bottom, big),
  optional mirrored left fire, ADS toggle, Jump, Crouch, Reload, Interact,
  slot strip (primary/secondary/knife/grenade), grenade cycle.
- Every control belongs to group `hud_movable` with a `hud_id` meta so the
  Phase 4 HUD editor can reposition/scale from Settings.hud_layout.
- Look input must NOT be eaten by buttons: buttons stop events; look area is
  the fallback surface.

## Screenshot/verify tooling

`tools/screenshot.gd` (SceneTree script) — renders a scene N frames under
xvfb and saves PNG. Every phase gate: capture + review. Bots/gameplay can be
driven by adding autorun logic guarded by `OS.get_environment("TS_AUTOPILOT")`.

## Asset layout

- `assets/characters/<name>.glb` + licenses in CREDITS.md
- `assets/weapons/<id>/tp.glb` third-person; viewmodel scenes composed in
  `scenes/weapons/vm_<id>.tscn`
- `assets/env/<kit>/...glb`, `assets/textures/...`
- Sources recorded in CREDITS.md with license + URL. CC0 only (or CC-BY with
  attribution noted).
