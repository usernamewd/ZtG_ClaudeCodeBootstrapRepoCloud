class_name WeaponDB
extends RefCounted
## Single source of truth for weapon / equipment balance. ALL members are static:
## never instantiate this class, call `WeaponDB.get_def("ar77")` etc.
##
## Every definition is a Dictionary. `get_def()` returns the *shared const* dict,
## so it allocates nothing and is safe to call from hot paths — but the returned
## Dictionary (and its nested Arrays) is READ-ONLY: use `duplicate_def(id)` when
## you need a mutable copy. `all_ids()` / `ids_in_category()` hand back a fresh
## Array[String] you may sort or shuffle; the `*_ref()` variants return the shared
## read-only lists with no allocation.
##
## ---------------------------------------------------------------------------
## GUN SCHEMA (PISTOL / SMG / RIFLE / HEAVY, and KNIFE which fills the same keys)
## ---------------------------------------------------------------------------
##   id                  String   dictionary key, also the ammo key on CharacterBase
##   display_name        String   UI name
##   category            int      Cat enum
##   slot                int      Slot enum (matches InputHub.switch_slot_request)
##   teams               int      TEAM_BOTH / TEAM_ATK / TEAM_DEF (buy restriction)
##   issued              bool     granted free at round start (p9, knife)
##   price               int      credits
##   kill_reward         int      credits awarded to the killer
##   damage              float    per bullet/pellet, at point blank, before zone
##                                multiplier and armour
##   pellets             int      1 except shotgun (9)
##   fire_rate           float    rounds/s (semi guns: max tap rate)
##   auto                bool     holding fire keeps shooting
##   mag                 int      rounds per magazine
##   reserve             int      spare rounds carried
##   reload_time         float    s, full reload (shell guns: total for an empty mag)
##   draw_time           float    s, until the weapon can fire after switching
##   spread_base         float    deg, standing hip-fire cone half-angle
##   spread_move_add     float    deg added at full running speed (lerp by speed)
##   spread_air_add      float    deg added while airborne
##   recoil_pattern      Array[Vector2]  per-shot kick, x = yaw drift deg
##                                (+ = right), y = pitch up deg. Index clamps to
##                                the last entry once the pattern is exhausted
##                                (that entry is the plateau). Deterministic.
##   recoil_recovery     float    deg/s the camera returns after the shot delay
##   move_speed_mult     float    multiplies CharacterBase movement speed
##   penetration         float    0..1 wall-punch power (see Weapon.gd)
##   armor_pen           float    0..1 fraction of armour mitigation ignored
##   range_falloff_start float    m, full damage up to here
##   range_falloff_end   float    m, damage floor from here on
##   falloff_min_mult    float    damage multiplier at/after range_falloff_end
##   headshot_mult       float    HEAD zone multiplier (default 4.0)
##   ads_fov             float    camera FOV while aiming (DEFAULT_FOV when hip)
##   ads_time            float    s to reach full ADS
##   ads_spread_mult     float    spread multiplier while fully aimed
##   scoped              bool     true = black scope overlay instead of viewmodel
##   scope_fovs          Array    extra zoom steps for scoped guns (deg), else []
##   burst_count         int      0 = no burst mode; else shots per burst
##   burst_rate          float    rounds/s inside a burst
##   burst_delay         float    s between bursts
##   shell_reload        bool     reloads one shell at a time (interruptible)
##   reload_shell_time   float    s per shell when shell_reload
##   tp_model            String   res:// third-person model
##   vm_scene            String   res:// viewmodel scene
##   icon                String   res:// buy-menu icon
##   fire_sfx            String   AudioMgr id
##   reload_sfx          String   AudioMgr id
##   draw_sfx            String   AudioMgr id
##   empty_sfx           String   AudioMgr id (dry fire)
##
## KNIFE extra keys: damage_heavy, rate_heavy, melee_range, back_mult.
## GRENADE keys: fuse_time, blast_radius, max_damage, effect_time, throw_speed,
##   throw_up, bounce, detonate_on_impact, max_carry, dps, projectile_scene.
## GEAR keys: armor_points, grants_helmet, requires_id.
##
## Assets under res://assets/weapons/<id>/ and res://scenes/weapons/vm_<id>.tscn
## are Phase 2 deliverables; the DB only names them.

enum Cat { PISTOL, SMG, RIFLE, HEAVY, KNIFE, GRENADE, GEAR }
enum Slot { PRIMARY, SECONDARY, KNIFE, GRENADE, GEAR }

const TEAM_BOTH := -1        # matches GameState.Team.NONE / ATK / DEF
const TEAM_ATK := 0
const TEAM_DEF := 1

const DEFAULT_FOV := 78.0    # hip-fire camera FOV the ads_fov values are tuned against
const MAX_GRENADES_TOTAL := 4
const DEFAULT_HEADSHOT_MULT := 4.0

const EMPTY_DEF: Dictionary = {}
const EMPTY_IDS: Array[String] = []
const EMPTY_FOVS: Array[float] = []

# --- Recoil patterns -------------------------------------------------------
# Hand-authored so every gun has a learnable signature. x = horizontal drift
# (deg, + right), y = vertical kick (deg). Autos: straight climb for the first
# shots, then a characteristic sideways sweep, then a low plateau.

const RECOIL_P9: Array[Vector2] = [
	Vector2(0.00, 0.62), Vector2(0.08, 0.70), Vector2(0.18, 0.72), Vector2(0.24, 0.68),
	Vector2(0.20, 0.62), Vector2(0.08, 0.58), Vector2(-0.08, 0.55), Vector2(-0.20, 0.52),
]

const RECOIL_TALON: Array[Vector2] = [
	Vector2(0.00, 0.95), Vector2(-0.12, 1.06), Vector2(-0.26, 1.02), Vector2(-0.30, 0.94),
	Vector2(-0.22, 0.88), Vector2(-0.06, 0.84),
]

const RECOIL_SNUB: Array[Vector2] = [
	Vector2(0.04, 0.88), Vector2(0.16, 1.00), Vector2(0.30, 1.05), Vector2(0.36, 0.96),
	Vector2(0.30, 0.86), Vector2(0.14, 0.78), Vector2(-0.06, 0.72), Vector2(-0.22, 0.68),
	Vector2(-0.30, 0.64),
]

# Viper: climbs, sweeps right, then a slow left return — mirror of the mk9.
const RECOIL_VIPER45: Array[Vector2] = [
	Vector2(0.02, 0.68), Vector2(0.06, 0.80), Vector2(0.14, 0.82), Vector2(0.24, 0.74),
	Vector2(0.34, 0.62), Vector2(0.42, 0.50), Vector2(0.46, 0.40), Vector2(0.44, 0.33),
	Vector2(0.36, 0.29), Vector2(0.22, 0.27), Vector2(0.04, 0.26), Vector2(-0.16, 0.25),
	Vector2(-0.34, 0.24), Vector2(-0.46, 0.23), Vector2(-0.50, 0.22), Vector2(-0.44, 0.21),
	Vector2(-0.30, 0.21), Vector2(-0.12, 0.20), Vector2(0.08, 0.20), Vector2(0.24, 0.19),
	Vector2(0.34, 0.19), Vector2(0.36, 0.18), Vector2(0.30, 0.18), Vector2(0.18, 0.18),
	Vector2(0.04, 0.17), Vector2(-0.10, 0.17), Vector2(-0.20, 0.17), Vector2(-0.24, 0.16),
	Vector2(-0.20, 0.16), Vector2(-0.10, 0.16),
]

const RECOIL_MK9: Array[Vector2] = [
	Vector2(0.02, 0.55), Vector2(-0.04, 0.64), Vector2(-0.12, 0.66), Vector2(-0.20, 0.60),
	Vector2(-0.26, 0.50), Vector2(-0.28, 0.42), Vector2(-0.24, 0.34), Vector2(-0.14, 0.29),
	Vector2(0.00, 0.26), Vector2(0.14, 0.24), Vector2(0.26, 0.23), Vector2(0.32, 0.22),
	Vector2(0.32, 0.21), Vector2(0.26, 0.20), Vector2(0.14, 0.20), Vector2(0.00, 0.19),
	Vector2(-0.14, 0.19), Vector2(-0.24, 0.18), Vector2(-0.28, 0.18), Vector2(-0.26, 0.17),
	Vector2(-0.18, 0.17), Vector2(-0.06, 0.17), Vector2(0.08, 0.16), Vector2(0.18, 0.16),
	Vector2(0.24, 0.16), Vector2(0.24, 0.15), Vector2(0.18, 0.15), Vector2(0.08, 0.15),
	Vector2(-0.04, 0.15), Vector2(-0.14, 0.14),
]

# AR-77: four shots almost straight up, hard right hook, long left sweep, settle.
const RECOIL_AR77: Array[Vector2] = [
	Vector2(0.05, 1.05), Vector2(0.02, 1.30), Vector2(-0.04, 1.45), Vector2(0.10, 1.35),
	Vector2(0.28, 1.15), Vector2(0.46, 0.95), Vector2(0.62, 0.72), Vector2(0.70, 0.55),
	Vector2(0.66, 0.40), Vector2(0.48, 0.30), Vector2(0.16, 0.26), Vector2(-0.24, 0.24),
	Vector2(-0.62, 0.22), Vector2(-0.86, 0.20), Vector2(-0.94, 0.18), Vector2(-0.82, 0.18),
	Vector2(-0.54, 0.16), Vector2(-0.18, 0.16), Vector2(0.22, 0.16), Vector2(0.58, 0.15),
	Vector2(0.80, 0.14), Vector2(0.84, 0.14), Vector2(0.70, 0.13), Vector2(0.42, 0.13),
	Vector2(0.08, 0.12), Vector2(-0.26, 0.12), Vector2(-0.50, 0.12), Vector2(-0.60, 0.11),
	Vector2(-0.54, 0.11), Vector2(-0.34, 0.10),
]

# BR-52: same shape, lower amplitude and a tighter loop — easier to control.
const RECOIL_BR52: Array[Vector2] = [
	Vector2(0.03, 0.86), Vector2(-0.02, 1.02), Vector2(0.06, 1.10), Vector2(0.16, 1.02),
	Vector2(0.28, 0.88), Vector2(0.38, 0.70), Vector2(0.44, 0.54), Vector2(0.42, 0.40),
	Vector2(0.32, 0.32), Vector2(0.14, 0.26), Vector2(-0.08, 0.24), Vector2(-0.30, 0.22),
	Vector2(-0.46, 0.20), Vector2(-0.52, 0.19), Vector2(-0.46, 0.18), Vector2(-0.30, 0.17),
	Vector2(-0.08, 0.16), Vector2(0.16, 0.15), Vector2(0.34, 0.15), Vector2(0.44, 0.14),
	Vector2(0.44, 0.14), Vector2(0.34, 0.13), Vector2(0.18, 0.13), Vector2(-0.02, 0.12),
	Vector2(-0.20, 0.12), Vector2(-0.32, 0.11), Vector2(-0.36, 0.11), Vector2(-0.30, 0.10),
	Vector2(-0.18, 0.10), Vector2(-0.04, 0.10),
]

const RECOIL_SR1: Array[Vector2] = [
	Vector2(0.00, 3.20), Vector2(0.15, 3.35), Vector2(-0.20, 3.30), Vector2(0.25, 3.40),
	Vector2(-0.10, 3.35),
]

const RECOIL_BREACHER12: Array[Vector2] = [
	Vector2(0.00, 2.60), Vector2(0.20, 2.75), Vector2(-0.25, 2.70), Vector2(0.30, 2.65),
	Vector2(-0.30, 2.60), Vector2(0.15, 2.58),
]

# Mule: heavy, wide, slow sine. Plateau stays high — 100 rounds of pure spray.
const RECOIL_MULE: Array[Vector2] = [
	Vector2(0.10, 1.25), Vector2(0.24, 1.45), Vector2(0.42, 1.40), Vector2(0.60, 1.20),
	Vector2(0.78, 1.00), Vector2(0.92, 0.82), Vector2(1.00, 0.66), Vector2(0.98, 0.54),
	Vector2(0.84, 0.46), Vector2(0.60, 0.42), Vector2(0.26, 0.40), Vector2(-0.14, 0.38),
	Vector2(-0.54, 0.36), Vector2(-0.88, 0.35), Vector2(-1.10, 0.34), Vector2(-1.16, 0.33),
	Vector2(-1.04, 0.32), Vector2(-0.76, 0.31), Vector2(-0.38, 0.30), Vector2(0.04, 0.30),
	Vector2(0.44, 0.29), Vector2(0.76, 0.28), Vector2(0.96, 0.28), Vector2(1.00, 0.27),
	Vector2(0.88, 0.27), Vector2(0.62, 0.26), Vector2(0.28, 0.26), Vector2(-0.08, 0.25),
	Vector2(-0.42, 0.25), Vector2(-0.68, 0.24),
]

const RECOIL_KNIFE: Array[Vector2] = []

# --- Definitions -----------------------------------------------------------

const DEFS: Dictionary = {

# ============================== PISTOLS ==============================
"p9": {
	"id": "p9", "display_name": "P-9 Cadet", "category": Cat.PISTOL,
	"slot": Slot.SECONDARY, "teams": TEAM_BOTH, "issued": true,
	"price": 0, "kill_reward": 300,
	"damage": 21.0, "pellets": 1, "fire_rate": 6.5, "auto": false,
	"mag": 12, "reserve": 36, "reload_time": 2.0, "draw_time": 0.50,
	"spread_base": 0.50, "spread_move_add": 1.60, "spread_air_add": 5.0,
	"recoil_pattern": RECOIL_P9, "recoil_recovery": 22.0,
	"move_speed_mult": 0.99,
	"penetration": 0.30, "armor_pen": 0.50,
	"range_falloff_start": 22.0, "range_falloff_end": 45.0, "falloff_min_mult": 0.55,
	"headshot_mult": 4.0,
	"ads_fov": 62.0, "ads_time": 0.16, "ads_spread_mult": 0.55,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/p9/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_p9.tscn",
	"icon": "res://assets/weapons/p9/icon.png",
	"fire_sfx": "wpn_p9_fire", "reload_sfx": "wpn_p9_reload",
	"draw_sfx": "wpn_draw_light", "empty_sfx": "wpn_dry_fire",
},

"talon": {
	"id": "talon", "display_name": "Talon MK3", "category": Cat.PISTOL,
	"slot": Slot.SECONDARY, "teams": TEAM_BOTH, "issued": false,
	"price": 700, "kill_reward": 300,
	# High raw damage, poor armour penetration: melts unarmoured eco players,
	# noticeably worse against a full-buy target.
	"damage": 34.0, "pellets": 1, "fire_rate": 5.0, "auto": false,
	"mag": 13, "reserve": 26, "reload_time": 2.2, "draw_time": 0.55,
	"spread_base": 0.40, "spread_move_add": 1.70, "spread_air_add": 5.5,
	"recoil_pattern": RECOIL_TALON, "recoil_recovery": 20.0,
	"move_speed_mult": 0.97,
	"penetration": 0.55, "armor_pen": 0.42,
	"range_falloff_start": 26.0, "range_falloff_end": 55.0, "falloff_min_mult": 0.62,
	"headshot_mult": 4.0,
	"ads_fov": 58.0, "ads_time": 0.18, "ads_spread_mult": 0.50,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/talon/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_talon.tscn",
	"icon": "res://assets/weapons/talon/icon.png",
	"fire_sfx": "wpn_talon_fire", "reload_sfx": "wpn_talon_reload",
	"draw_sfx": "wpn_draw_light", "empty_sfx": "wpn_dry_fire",
},

"snub": {
	"id": "snub", "display_name": "Snub-6", "category": Cat.PISTOL,
	"slot": Slot.SECONDARY, "teams": TEAM_BOTH, "issued": false,
	"price": 600, "kill_reward": 300,
	# Alt fire mode: 3-round burst. Falls back to a 5 rps semi if the weapon
	# script ignores the burst_* keys.
	"damage": 29.0, "pellets": 1, "fire_rate": 5.0, "auto": false,
	"mag": 12, "reserve": 36, "reload_time": 2.3, "draw_time": 0.50,
	"spread_base": 0.55, "spread_move_add": 1.80, "spread_air_add": 6.0,
	"recoil_pattern": RECOIL_SNUB, "recoil_recovery": 21.0,
	"move_speed_mult": 0.97,
	"penetration": 0.42, "armor_pen": 0.62,
	"range_falloff_start": 24.0, "range_falloff_end": 50.0, "falloff_min_mult": 0.58,
	"headshot_mult": 4.5,
	"ads_fov": 60.0, "ads_time": 0.17, "ads_spread_mult": 0.55,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 3, "burst_rate": 12.0, "burst_delay": 0.40,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/snub/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_snub.tscn",
	"icon": "res://assets/weapons/snub/icon.png",
	"fire_sfx": "wpn_snub_fire", "reload_sfx": "wpn_snub_reload",
	"draw_sfx": "wpn_draw_light", "empty_sfx": "wpn_dry_fire",
},

# ================================ SMGs ===============================
"viper45": {
	"id": "viper45", "display_name": "Viper .45", "category": Cat.SMG,
	"slot": Slot.PRIMARY, "teams": TEAM_BOTH, "issued": false,
	"price": 1250, "kill_reward": 600,
	"damage": 21.0, "pellets": 1, "fire_rate": 11.0, "auto": true,
	"mag": 30, "reserve": 90, "reload_time": 2.4, "draw_time": 0.65,
	"spread_base": 0.70, "spread_move_add": 0.55, "spread_air_add": 3.2,
	"recoil_pattern": RECOIL_VIPER45, "recoil_recovery": 26.0,
	"move_speed_mult": 0.94,
	"penetration": 0.45, "armor_pen": 0.55,
	"range_falloff_start": 18.0, "range_falloff_end": 40.0, "falloff_min_mult": 0.55,
	"headshot_mult": 4.0,
	"ads_fov": 62.0, "ads_time": 0.16, "ads_spread_mult": 0.70,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/viper45/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_viper45.tscn",
	"icon": "res://assets/weapons/viper45/icon.png",
	"fire_sfx": "wpn_viper45_fire", "reload_sfx": "wpn_viper45_reload",
	"draw_sfx": "wpn_draw_light", "empty_sfx": "wpn_dry_fire",
},

"mk9": {
	"id": "mk9", "display_name": "MK9 Wasp", "category": Cat.SMG,
	"slot": Slot.PRIMARY, "teams": TEAM_BOTH, "issued": false,
	"price": 1500, "kill_reward": 600,
	"damage": 18.0, "pellets": 1, "fire_rate": 13.5, "auto": true,
	"mag": 30, "reserve": 120, "reload_time": 2.2, "draw_time": 0.60,
	"spread_base": 0.80, "spread_move_add": 0.45, "spread_air_add": 3.0,
	"recoil_pattern": RECOIL_MK9, "recoil_recovery": 28.0,
	"move_speed_mult": 0.96,
	"penetration": 0.40, "armor_pen": 0.60,
	"range_falloff_start": 16.0, "range_falloff_end": 36.0, "falloff_min_mult": 0.50,
	"headshot_mult": 4.0,
	"ads_fov": 63.0, "ads_time": 0.15, "ads_spread_mult": 0.70,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/mk9/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_mk9.tscn",
	"icon": "res://assets/weapons/mk9/icon.png",
	"fire_sfx": "wpn_mk9_fire", "reload_sfx": "wpn_mk9_reload",
	"draw_sfx": "wpn_draw_light", "empty_sfx": "wpn_dry_fire",
},

# =============================== RIFLES ==============================
"ar77": {
	"id": "ar77", "display_name": "AR-77 Hydra", "category": Cat.RIFLE,
	"slot": Slot.PRIMARY, "teams": TEAM_ATK, "issued": false,
	"price": 2700, "kill_reward": 300,
	"damage": 36.0, "pellets": 1, "fire_rate": 10.0, "auto": true,
	"mag": 30, "reserve": 90, "reload_time": 2.6, "draw_time": 0.75,
	"spread_base": 0.85, "spread_move_add": 2.40, "spread_air_add": 8.0,
	"recoil_pattern": RECOIL_AR77, "recoil_recovery": 24.0,
	"move_speed_mult": 0.88,
	"penetration": 0.62, "armor_pen": 0.72,
	"range_falloff_start": 32.0, "range_falloff_end": 72.0, "falloff_min_mult": 0.72,
	"headshot_mult": 4.0,
	"ads_fov": 55.0, "ads_time": 0.22, "ads_spread_mult": 0.26,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/ar77/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_ar77.tscn",
	"icon": "res://assets/weapons/ar77/icon.png",
	"fire_sfx": "wpn_ar77_fire", "reload_sfx": "wpn_ar77_reload",
	"draw_sfx": "wpn_draw_heavy", "empty_sfx": "wpn_dry_fire",
},

"br52": {
	"id": "br52", "display_name": "BR-52 Lancer", "category": Cat.RIFLE,
	"slot": Slot.PRIMARY, "teams": TEAM_DEF, "issued": false,
	"price": 3100, "kill_reward": 300,
	# Lower per-bullet damage than the AR-77 but better armour penetration,
	# tighter cone and a gentler pattern: rewards holding angles.
	"damage": 34.0, "pellets": 1, "fire_rate": 9.2, "auto": true,
	"mag": 30, "reserve": 90, "reload_time": 2.5, "draw_time": 0.75,
	"spread_base": 0.72, "spread_move_add": 2.10, "spread_air_add": 7.4,
	"recoil_pattern": RECOIL_BR52, "recoil_recovery": 26.0,
	"move_speed_mult": 0.87,
	"penetration": 0.70, "armor_pen": 0.82,
	"range_falloff_start": 38.0, "range_falloff_end": 80.0, "falloff_min_mult": 0.78,
	"headshot_mult": 4.0,
	"ads_fov": 50.0, "ads_time": 0.24, "ads_spread_mult": 0.24,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/br52/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_br52.tscn",
	"icon": "res://assets/weapons/br52/icon.png",
	"fire_sfx": "wpn_br52_fire", "reload_sfx": "wpn_br52_reload",
	"draw_sfx": "wpn_draw_heavy", "empty_sfx": "wpn_dry_fire",
},

"sr1": {
	"id": "sr1", "display_name": "SR-1 Verdict", "category": Cat.RIFLE,
	"slot": Slot.PRIMARY, "teams": TEAM_BOTH, "issued": false,
	"price": 4750, "kill_reward": 100,
	# One-shot kill on CHEST/STOMACH even through armour (armor_pen 0.97),
	# LIMB hits (x0.75) leave the target alive. 1.6 s between shots.
	"damage": 118.0, "pellets": 1, "fire_rate": 0.62, "auto": false,
	"mag": 5, "reserve": 20, "reload_time": 3.6, "draw_time": 1.10,
	"spread_base": 3.60, "spread_move_add": 9.50, "spread_air_add": 16.0,
	"recoil_pattern": RECOIL_SR1, "recoil_recovery": 12.0,
	"move_speed_mult": 0.78,
	"penetration": 0.90, "armor_pen": 0.97,
	"range_falloff_start": 90.0, "range_falloff_end": 200.0, "falloff_min_mult": 0.90,
	"headshot_mult": 4.0,
	"ads_fov": 26.0, "ads_time": 0.34, "ads_spread_mult": 0.008,
	"scoped": true, "scope_fovs": [26.0, 11.0],
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/sr1/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_sr1.tscn",
	"icon": "res://assets/weapons/sr1/icon.png",
	"fire_sfx": "wpn_sr1_fire", "reload_sfx": "wpn_sr1_reload",
	"draw_sfx": "wpn_draw_heavy", "empty_sfx": "wpn_dry_fire",
},

# =============================== HEAVY ===============================
"breacher12": {
	"id": "breacher12", "display_name": "Breacher 12", "category": Cat.HEAVY,
	"slot": Slot.PRIMARY, "teams": TEAM_BOTH, "issued": false,
	"price": 1900, "kill_reward": 900,
	# 9 x 24 = 216 point blank, 21.6 past 22 m. Reloads shell by shell and can
	# be interrupted to fire after any shell.
	"damage": 24.0, "pellets": 9, "fire_rate": 1.1, "auto": false,
	"mag": 8, "reserve": 32, "reload_time": 4.8, "draw_time": 0.80,
	"spread_base": 3.40, "spread_move_add": 1.20, "spread_air_add": 3.0,
	"recoil_pattern": RECOIL_BREACHER12, "recoil_recovery": 14.0,
	"move_speed_mult": 0.85,
	"penetration": 0.12, "armor_pen": 0.55,
	"range_falloff_start": 8.0, "range_falloff_end": 22.0, "falloff_min_mult": 0.10,
	"headshot_mult": 3.0,
	"ads_fov": 66.0, "ads_time": 0.20, "ads_spread_mult": 0.80,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": true, "reload_shell_time": 0.55,
	"tp_model": "res://assets/weapons/breacher12/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_breacher12.tscn",
	"icon": "res://assets/weapons/breacher12/icon.png",
	"fire_sfx": "wpn_breacher12_fire", "reload_sfx": "wpn_breacher12_shell",
	"draw_sfx": "wpn_draw_heavy", "empty_sfx": "wpn_dry_fire",
},

"mule": {
	"id": "mule", "display_name": "Mule M-100", "category": Cat.HEAVY,
	"slot": Slot.PRIMARY, "teams": TEAM_BOTH, "issued": false,
	"price": 5200, "kill_reward": 300,
	"damage": 32.0, "pellets": 1, "fire_rate": 8.0, "auto": true,
	"mag": 100, "reserve": 200, "reload_time": 5.4, "draw_time": 1.30,
	"spread_base": 1.35, "spread_move_add": 3.20, "spread_air_add": 9.0,
	"recoil_pattern": RECOIL_MULE, "recoil_recovery": 20.0,
	"move_speed_mult": 0.72,
	"penetration": 0.85, "armor_pen": 0.78,
	"range_falloff_start": 30.0, "range_falloff_end": 68.0, "falloff_min_mult": 0.68,
	"headshot_mult": 3.6,
	"ads_fov": 58.0, "ads_time": 0.30, "ads_spread_mult": 0.38,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/mule/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_mule.tscn",
	"icon": "res://assets/weapons/mule/icon.png",
	"fire_sfx": "wpn_mule_fire", "reload_sfx": "wpn_mule_reload",
	"draw_sfx": "wpn_draw_heavy", "empty_sfx": "wpn_dry_fire",
},

# =============================== KNIFE ===============================
"knife": {
	"id": "knife", "display_name": "Combat Knife", "category": Cat.KNIFE,
	"slot": Slot.KNIFE, "teams": TEAM_BOTH, "issued": true,
	"price": 0, "kill_reward": 1500,
	# `damage` / `fire_rate` are the light (primary) swing; damage_heavy /
	# rate_heavy are the alt swing. Hits behind the target multiply by back_mult
	# (light back-stab = 100.8 -> lethal, heavy back-stab is instant).
	"damage": 42.0, "pellets": 1, "fire_rate": 2.5, "auto": true,
	"damage_heavy": 78.0, "rate_heavy": 0.85, "melee_range": 1.9, "back_mult": 2.4,
	"mag": 0, "reserve": 0, "reload_time": 0.0, "draw_time": 0.40,
	"spread_base": 0.0, "spread_move_add": 0.0, "spread_air_add": 0.0,
	"recoil_pattern": RECOIL_KNIFE, "recoil_recovery": 0.0,
	"move_speed_mult": 1.0,
	"penetration": 0.0, "armor_pen": 0.85,
	"range_falloff_start": 1.9, "range_falloff_end": 1.9, "falloff_min_mult": 1.0,
	"headshot_mult": 1.0,
	"ads_fov": DEFAULT_FOV, "ads_time": 0.0, "ads_spread_mult": 1.0,
	"scoped": false, "scope_fovs": EMPTY_FOVS,
	"burst_count": 0, "burst_rate": 0.0, "burst_delay": 0.0,
	"shell_reload": false, "reload_shell_time": 0.0,
	"tp_model": "res://assets/weapons/knife/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_knife.tscn",
	"icon": "res://assets/weapons/knife/icon.png",
	"fire_sfx": "wpn_knife_swing", "reload_sfx": "wpn_knife_swing",
	"draw_sfx": "wpn_knife_draw", "empty_sfx": "wpn_knife_swing",
},

# ============================= GRENADES ==============================
"frag": {
	"id": "frag", "display_name": "Frag Grenade", "category": Cat.GRENADE,
	"slot": Slot.GRENADE, "teams": TEAM_BOTH, "issued": false,
	"price": 300, "kill_reward": 300, "max_carry": 1,
	"max_damage": 130.0, "blast_radius": 7.0, "fuse_time": 1.6,
	"effect_time": 0.0, "dps": 0.0,
	"throw_speed": 22.0, "throw_up": 4.0, "bounce": 0.35,
	"detonate_on_impact": false,
	"armor_pen": 0.35, "headshot_mult": 1.0,
	"move_speed_mult": 0.99, "draw_time": 0.55,
	"projectile_scene": "res://scenes/weapons/proj_frag.tscn",
	"tp_model": "res://assets/weapons/frag/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_frag.tscn",
	"icon": "res://assets/weapons/frag/icon.png",
	"fire_sfx": "nade_throw", "explode_sfx": "nade_frag_explode",
	"draw_sfx": "wpn_draw_light",
},

"flash": {
	"id": "flash", "display_name": "Flashbang", "category": Cat.GRENADE,
	"slot": Slot.GRENADE, "teams": TEAM_BOTH, "issued": false,
	"price": 200, "kill_reward": 0, "max_carry": 2,
	"max_damage": 0.0, "blast_radius": 12.0, "fuse_time": 1.4,
	"effect_time": 3.4, "dps": 0.0,
	"throw_speed": 23.0, "throw_up": 4.0, "bounce": 0.40,
	"detonate_on_impact": false,
	"armor_pen": 0.0, "headshot_mult": 1.0,
	"move_speed_mult": 0.99, "draw_time": 0.55,
	"projectile_scene": "res://scenes/weapons/proj_flash.tscn",
	"tp_model": "res://assets/weapons/flash/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_flash.tscn",
	"icon": "res://assets/weapons/flash/icon.png",
	"fire_sfx": "nade_throw", "explode_sfx": "nade_flash_pop",
	"draw_sfx": "wpn_draw_light",
},

"smoke": {
	"id": "smoke", "display_name": "Smoke Screen", "category": Cat.GRENADE,
	"slot": Slot.GRENADE, "teams": TEAM_BOTH, "issued": false,
	"price": 300, "kill_reward": 0, "max_carry": 1,
	# blast_radius doubles as the smoke volume radius (physics layer 7).
	"max_damage": 0.0, "blast_radius": 5.0, "fuse_time": 1.6,
	"effect_time": 16.0, "dps": 0.0,
	"throw_speed": 21.0, "throw_up": 4.0, "bounce": 0.25,
	"detonate_on_impact": false,
	"armor_pen": 0.0, "headshot_mult": 1.0,
	"move_speed_mult": 0.99, "draw_time": 0.55,
	"projectile_scene": "res://scenes/weapons/proj_smoke.tscn",
	"tp_model": "res://assets/weapons/smoke/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_smoke.tscn",
	"icon": "res://assets/weapons/smoke/icon.png",
	"fire_sfx": "nade_throw", "explode_sfx": "nade_smoke_hiss",
	"draw_sfx": "wpn_draw_light",
},

"incendiary": {
	"id": "incendiary", "display_name": "Incendiary", "category": Cat.GRENADE,
	"slot": Slot.GRENADE, "teams": TEAM_BOTH, "issued": false,
	"price": 600, "kill_reward": 300, "max_carry": 1,
	"max_damage": 0.0, "blast_radius": 3.6, "fuse_time": 0.0,
	"effect_time": 7.0, "dps": 32.0,
	"throw_speed": 20.0, "throw_up": 4.0, "bounce": 0.0,
	"detonate_on_impact": true,
	"armor_pen": 1.0, "headshot_mult": 1.0,
	"move_speed_mult": 0.99, "draw_time": 0.55,
	"projectile_scene": "res://scenes/weapons/proj_incendiary.tscn",
	"tp_model": "res://assets/weapons/incendiary/tp.glb",
	"vm_scene": "res://scenes/weapons/vm_incendiary.tscn",
	"icon": "res://assets/weapons/incendiary/icon.png",
	"fire_sfx": "nade_throw", "explode_sfx": "nade_fire_ignite",
	"draw_sfx": "wpn_draw_light",
},

# =============================== GEAR ================================
"armor": {
	"id": "armor", "display_name": "Body Armour", "category": Cat.GEAR,
	"slot": Slot.GEAR, "teams": TEAM_BOTH, "issued": false,
	"price": 650, "kill_reward": 0,
	"armor_points": 100.0, "grants_helmet": false, "requires_id": "",
	"move_speed_mult": 1.0,
	"icon": "res://assets/weapons/armor/icon.png",
	"buy_sfx": "gear_armor_equip",
},

"helmet": {
	"id": "helmet", "display_name": "Ballistic Helmet", "category": Cat.GEAR,
	"slot": Slot.GEAR, "teams": TEAM_BOTH, "issued": false,
	# Upgrade on top of body armour; the buy menu should offer the pair for
	# price(armor) + price(helmet) = 1000 when the player owns neither.
	"price": 350, "kill_reward": 0,
	"armor_points": 0.0, "grants_helmet": true, "requires_id": "armor",
	"move_speed_mult": 1.0,
	"icon": "res://assets/weapons/helmet/icon.png",
	"buy_sfx": "gear_armor_equip",
},

"defusekit": {
	"id": "defusekit", "display_name": "Defuse Kit", "category": Cat.GEAR,
	"slot": Slot.GEAR, "teams": TEAM_DEF, "issued": false,
	# Shortens the defuse to GameState.cfg_defuse_kit_time.
	"price": 400, "kill_reward": 0,
	"armor_points": 0.0, "grants_helmet": false, "requires_id": "",
	"move_speed_mult": 1.0,
	"icon": "res://assets/weapons/defusekit/icon.png",
	"buy_sfx": "gear_kit_equip",
},
}

# --- Index (built once, then reused; returned arrays are read-only) ---------

static var _ids_all: Array[String] = []
static var _ids_by_cat: Dictionary = {}
static var _index_built: bool = false


static func _build_index() -> void:
	_index_built = true
	_ids_all.clear()
	_ids_by_cat.clear()
	for cat in Cat.values():
		var bucket: Array[String] = []
		_ids_by_cat[cat] = bucket
	for key in DEFS:
		var id := String(key)
		_ids_all.append(id)
		var cat: int = DEFS[key].get("category", Cat.GEAR)
		var bucket: Array[String] = _ids_by_cat[cat]
		bucket.append(id)
	_ids_all.make_read_only()
	for bucket in _ids_by_cat.values():
		bucket.make_read_only()


static func _ensure_index() -> void:
	if not _index_built:
		_build_index()


# --- Public API ------------------------------------------------------------

## Shared, read-only definition. Empty Dictionary for unknown ids.
static func get_def(id: String) -> Dictionary:
	return DEFS.get(id, EMPTY_DEF)


static func has_def(id: String) -> bool:
	return DEFS.has(id)


## Mutable copy of a definition, for code that needs to tweak a def locally.
static func duplicate_def(id: String) -> Dictionary:
	return DEFS.get(id, EMPTY_DEF).duplicate(true)


## Every id in the database, in definition order. Fresh mutable Array[String]
## (safe to sort/shuffle) — not for per-frame use; cache the result.
static func all_ids() -> Array:
	_ensure_index()
	return _ids_all.duplicate()


## Ids of one Cat, in definition order. Fresh mutable Array[String].
static func ids_in_category(cat: int) -> Array:
	_ensure_index()
	var bucket: Array[String] = _ids_by_cat.get(cat, EMPTY_IDS)
	return bucket.duplicate()


## Shared read-only id list, no allocation — use when you only iterate/read.
static func all_ids_ref() -> Array:
	_ensure_index()
	return _ids_all


## Shared read-only id list for one Cat, no allocation.
static func ids_in_category_ref(cat: int) -> Array:
	_ensure_index()
	return _ids_by_cat.get(cat, EMPTY_IDS)


static func category_of(id: String) -> int:
	return DEFS.get(id, EMPTY_DEF).get("category", -1)


## True for anything that shoots bullets (excludes knife, grenades, gear).
static func is_gun(id: String) -> bool:
	var cat: int = category_of(id)
	return cat == Cat.PISTOL or cat == Cat.SMG or cat == Cat.RIFLE or cat == Cat.HEAVY


static func is_grenade(id: String) -> bool:
	return category_of(id) == Cat.GRENADE


static func is_gear(id: String) -> bool:
	return category_of(id) == Cat.GEAR


static func price_of(id: String) -> int:
	return DEFS.get(id, EMPTY_DEF).get("price", 0)


static func kill_reward_of(id: String) -> int:
	return DEFS.get(id, EMPTY_DEF).get("kill_reward", 0)


static func display_name_of(id: String) -> String:
	return DEFS.get(id, EMPTY_DEF).get("display_name", id)


## Buy restriction check. `team` is a GameState.Team value.
static func buyable_by_team(id: String, team: int) -> bool:
	var d: Dictionary = DEFS.get(id, EMPTY_DEF)
	if d.is_empty():
		return false
	var t: int = d.get("teams", TEAM_BOTH)
	return t == TEAM_BOTH or t == team


## How many of a grenade a player may carry (0 for non-grenades).
static func max_carry(id: String) -> int:
	return DEFS.get(id, EMPTY_DEF).get("max_carry", 0)


## Per-shot recoil kick, clamping past the end of the pattern to its last entry
## (the plateau). Returns Vector2.ZERO for weapons without a pattern.
static func recoil_at(id: String, shot_index: int) -> Vector2:
	var pattern: Array = DEFS.get(id, EMPTY_DEF).get("recoil_pattern", RECOIL_KNIFE)
	var n: int = pattern.size()
	if n == 0:
		return Vector2.ZERO
	return pattern[clampi(shot_index, 0, n - 1)]
