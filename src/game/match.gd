class_name FreeRunMatch
extends Node
## Phase 1 FREE-RUN gameplay scene (scenes/game/freerun.tscn).
##
## No rounds, no bots, no bomb: it loads a map, drops the local player in with a
## full loadout and unlimited money, wires up the shooting-range dummies and
## routes every kill through GameState/Economy exactly the way the round-based
## match does. That kill path is deliberately identical so Phase 3/4 can lift a
## round state machine on top without restructuring this file: the round
## director would drive spawn/equip/phase, and _register_kill() stays as-is.
##
## NAMING DEVIATION from docs/ARCHITECTURE.md: the contract names this script's
## global class `MatchController`. That name is already registered by
## src/game/match_controller.gd (the full round-based match), and a second
## registration is a hard parse error ("Class ... hides a global script class"),
## so the free-run variant registers as FreeRunMatch and lives in its own scene.

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const PLAYER_SCENE := "res://scenes/characters/player.tscn"
const DUMMY_SCENE := "res://scenes/characters/dummy.tscn"

## Map id (GameState.cfg_map) -> scene. Free-run defaults to the graybox range.
const MAP_SCENES := {
	"graybox": "res://scenes/maps/graybox.tscn",
	"saltline": "res://scenes/maps/saltline.tscn",
	"transit": "res://scenes/maps/transit.tscn",
}
const DEFAULT_MAP := "graybox"

## Pooled effects the grenade/bomb code acquires by key. Weapon.gd builds its own
## "wpn_tracer"/"wpn_impact" pools on first fire, so they are not listed here.
## Entries whose scene is missing are skipped rather than erroring.
const POOL_SPEC := {
	"frag_blast": ["res://scenes/weapons/frag_blast.tscn", 4],
	"flash_blast": ["res://scenes/weapons/flash_blast.tscn", 4],
	"smoke_volume": ["res://scenes/weapons/smoke_volume.tscn", 4],
	"fire_area": ["res://scenes/weapons/fire_area.tscn", 4],
}

const LOCAL_PLAYER_ID := 0
## Dummy roster ids start well clear of the human/bot id range.
const DUMMY_ID_BASE := 90
const MAX_DUMMIES := 8
const RESPAWN_DELAY := 2.0
## Economy.add() clamps to Economy.MAX_MONEY, so this is "buy anything, forever".
const FREE_RUN_MONEY := 16000

const LOADOUT_PRIMARY := "ar77"
const LOADOUT_SECONDARY := "p9"
const LOADOUT_KNIFE := "knife"
const LOADOUT_GRENADES: Array[String] = ["frag", "flash", "smoke", "incendiary"]
const LOADOUT_GEAR: Array[String] = ["armor", "helmet"]

## Autopilot pacing (see _run_autopilot).
const AP_LOOK_END := 0.7          # s of opening look-around before locking on
const AP_ENGAGE_RANGE := 12.0     # m: stop closing and hold this distance
const AP_APPROACH_MAX := 9.0      # s: give up closing if the way is blocked
const AP_BURST_PERIOD := 1.4      # s between bursts
const AP_BURST_LEN := 0.45        # s of held trigger per burst

@export var map_root_path: NodePath = ^"MapRoot"
@export var hud_path: NodePath = ^"HUD"

var player: CharacterBase = null
var map_info: MapInfo = null

var _map_root: Node3D = null
var _hud: Node = null
var _map_node: Node3D = null
var _dummies: Array[CharacterBase] = []
var _spawn_index: int = 0
var _respawn_timer: float = 0.0
var _leaving: bool = false

var _autopilot: bool = false
var _autopilot_time: float = 0.0
var _autopilot_target: CharacterBase = null
var _aim_point: Vector3 = Vector3.ZERO

## Shared miss result so roster lookups never build a throwaway dictionary.
const EMPTY_INFO: Dictionary = {}


func _ready() -> void:
	_autopilot = OS.get_environment("TS_AUTOPILOT") != ""
	_map_root = get_node_or_null(map_root_path) as Node3D
	_hud = get_node_or_null(hud_path)

	Settings.apply_graphics_preset()
	_setup_pools()
	GameState.reset_match()

	if not _load_map():
		return
	# The preset call above ran before the map existed, so its sun could not be
	# reached; re-apply now that the light is in the tree.
	Settings.apply_shadow_preset()

	_spawn_player()
	_setup_dummies()
	_reset_economy()
	_bind_hud()

	GameState.set_phase(GameState.Phase.WARMUP, 0.0)

	if _autopilot:
		_start_autopilot()


func _exit_tree() -> void:
	Pools.clear_all()


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _setup_pools() -> void:
	for key in POOL_SPEC:
		var spec: Array = POOL_SPEC[key]
		var path := String(spec[0])
		if not ResourceLoader.exists(path):
			continue
		Pools.create_pool(String(key), load(path), int(spec[1]))


func _load_map() -> bool:
	if _map_root == null:
		push_error("FreeRunMatch: MapRoot node missing at " + String(map_root_path))
		return false
	# TS_MAP is a headless-capture override (tools/capture.tscn cannot reach the
	# menu that normally sets GameState.cfg_map); empty in every normal run.
	var map_id := OS.get_environment("TS_MAP")
	if map_id.is_empty():
		map_id = GameState.cfg_map
	var path := String(MAP_SCENES.get(map_id, ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		path = String(MAP_SCENES[DEFAULT_MAP])
	if not ResourceLoader.exists(path):
		push_error("FreeRunMatch: no map scene available (" + path + ")")
		return false
	_map_node = (load(path) as PackedScene).instantiate() as Node3D
	if _map_node == null:
		push_error("FreeRunMatch: map root is not a Node3D: " + path)
		return false
	_map_root.add_child(_map_node)
	map_info = _map_node as MapInfo
	return true


func _spawn_player() -> void:
	if not ResourceLoader.exists(PLAYER_SCENE):
		push_error("FreeRunMatch: missing " + PLAYER_SCENE)
		return
	player = (load(PLAYER_SCENE) as PackedScene).instantiate() as CharacterBase
	if player == null:
		push_error("FreeRunMatch: " + PLAYER_SCENE + " root is not a CharacterBase")
		return
	player.team = GameState.cfg_player_team
	player.player_id = LOCAL_PLAYER_ID
	add_child(player)
	player.add_to_group("combatant")

	GameState.register_player(LOCAL_PLAYER_ID, Settings.player_name,
		player.team, true)
	player.died.connect(_on_player_died)
	player.respawned.connect(_on_respawned.bind(LOCAL_PLAYER_ID))

	# DEF spawn per the assignment: free-run treats the local player as the
	# defending side unless the menu picked otherwise.
	player.respawn(_spawn_transform(player.team, _spawn_index))
	_give_loadout(player)


## The graybox range ships its own dummies. Only when a map exposes DummySpawns
## markers without bodies do we instantiate them, so the two authoring styles
## both work and neither doubles up.
func _setup_dummies() -> void:
	_collect_dummies(_map_node)
	if _dummies.is_empty() and map_info != null:
		for marker in map_info.dummy_spawns:
			if _dummies.size() >= MAX_DUMMIES:
				break
			var d := _instantiate_dummy(marker.global_transform)
			if d != null:
				_dummies.append(d)

	var enemy_team: int = (GameState.Team.ATK
		if GameState.cfg_player_team == GameState.Team.DEF
		else GameState.Team.DEF)
	for i in _dummies.size():
		var d := _dummies[i]
		# A map that authored its own ids (graybox uses 900+) keeps them; only
		# dummies we spawned ourselves need one.
		var id := d.player_id if d.player_id >= 0 else DUMMY_ID_BASE + i
		d.player_id = id
		d.team = enemy_team
		if not d.is_in_group("combatant"):
			d.add_to_group("combatant")
		GameState.register_player(id, "Target %d" % (i + 1), enemy_team, false)
		d.died.connect(_on_dummy_died.bind(id))
		d.respawned.connect(_on_respawned.bind(id))


func _collect_dummies(n: Node) -> void:
	if n == null:
		return
	for child in n.get_children():
		if child is Dummy:
			if _dummies.size() < MAX_DUMMIES:
				_dummies.append(child as CharacterBase)
			continue
		_collect_dummies(child)


func _instantiate_dummy(xform: Transform3D) -> CharacterBase:
	if not ResourceLoader.exists(DUMMY_SCENE):
		push_warning("FreeRunMatch: missing " + DUMMY_SCENE)
		return null
	var d := (load(DUMMY_SCENE) as PackedScene).instantiate() as CharacterBase
	if d == null:
		return null
	_map_root.add_child(d)
	d.global_transform = xform
	# Dummy captures its spawn pose on the first physics tick; it is being moved
	# after _ready here, so hand it the real transform explicitly.
	if d.has_method("set_spawn_transform"):
		d.call("set_spawn_transform", xform)
	return d


## Free-run kit: rifle + pistol + knife + one of every grenade + full armour.
func _give_loadout(c: CharacterBase) -> void:
	if c == null:
		return
	c.clear_inventory()
	c.give_weapon(LOADOUT_SECONDARY, false)
	c.give_weapon(LOADOUT_KNIFE, false)
	for id in LOADOUT_GRENADES:
		c.give_weapon(id, false)
	for id in LOADOUT_GEAR:
		c.give_gear(id)
	c.give_weapon(LOADOUT_PRIMARY, true)
	c.refill_all_ammo()
	c.switch_to_best()


func _reset_economy() -> void:
	Economy.reset(GameState.players.keys())
	Economy.add(LOCAL_PLAYER_ID, FREE_RUN_MONEY)


func _bind_hud() -> void:
	if _hud == null:
		return
	if _hud.has_method("bind_player"):
		_hud.call("bind_player", player)


func _spawn_transform(team: int, index: int) -> Transform3D:
	if map_info != null:
		return map_info.get_spawn(team, index)
	return Transform3D(Basis(), Vector3(0.0, 1.0, 0.0))


# ---------------------------------------------------------------------------
# Kills — identical bookkeeping to the round-based match so Phase 3/4 can reuse
# it: roster k/d, WeaponDB kill reward, kill feed.
# ---------------------------------------------------------------------------

func _on_player_died(attacker_id: int, weapon_id: String, headshot: bool) -> void:
	_register_kill(attacker_id, LOCAL_PLAYER_ID, weapon_id, headshot)
	_respawn_timer = RESPAWN_DELAY


func _on_dummy_died(attacker_id: int, weapon_id: String, headshot: bool,
		victim_id: int) -> void:
	# The Dummy respawns itself; only the bookkeeping belongs here.
	_register_kill(attacker_id, victim_id, weapon_id, headshot)


func _register_kill(attacker_id: int, victim_id: int, weapon_id: String,
		headshot: bool) -> void:
	var victim: Dictionary = GameState.players.get(victim_id, EMPTY_INFO)
	if not victim.is_empty():
		victim["deaths"] = int(victim["deaths"]) + 1
		victim["alive"] = false

	if attacker_id >= 0 and attacker_id != victim_id:
		var killer: Dictionary = GameState.players.get(attacker_id, EMPTY_INFO)
		if not killer.is_empty():
			killer["kills"] = int(killer["kills"]) + 1
		var reward := int(WeaponDB.get_def(weapon_id).get("kill_reward", 0))
		if reward != 0:
			Economy.add(attacker_id, reward)

	GameState.kill_feed.emit(attacker_id, victim_id, weapon_id, headshot)


func _on_respawned(id: int) -> void:
	var info: Dictionary = GameState.players.get(id, EMPTY_INFO)
	if not info.is_empty():
		info["alive"] = true


func _respawn_player() -> void:
	if player == null:
		return
	_spawn_index += 1
	player.respawn(_spawn_transform(player.team, _spawn_index))
	_give_loadout(player)


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_respawn_timer = 0.0
			_respawn_player()
	if _autopilot:
		_run_autopilot(delta)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		leave_to_menu()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		leave_to_menu()


## Android back / ESC: tear the match down and hand the tree back to the menu.
func leave_to_menu() -> void:
	if _leaving:
		return
	_leaving = true
	InputHub.reset()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _hud != null and _hud.has_method("unbind_player"):
		_hud.call("unbind_player")
	GameState.reset_match()
	Pools.clear_all()
	if ResourceLoader.exists(MENU_SCENE):
		# change_scene_to_file frees this scene at the end of the frame.
		get_tree().change_scene_to_file(MENU_SCENE)
	else:
		queue_free()


# ---------------------------------------------------------------------------
# Autopilot
# ---------------------------------------------------------------------------

## Scripted stand-in for the player's hands, so tools/capture.tscn can grab a
## real gameplay frame headlessly (walk, look around, burst a target). Enabled
## only by the TS_AUTOPILOT env var and never touched by the normal input path.
func _start_autopilot() -> void:
	_autopilot_time = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_resolve_autopilot_target()


func _run_autopilot(delta: float) -> void:
	if player == null or not player.alive:
		return
	_autopilot_time += delta
	var t := _autopilot_time

	if t < AP_LOOK_END:
		# Open by walking and sweeping the view, so the captured frame is a
		# moving player rather than a spawn statue.
		InputHub.move = Vector2(0.0, 1.0)
		InputHub.look_delta = Vector2(sin(t * 2.2) * 1.6, 0.0)
		InputHub.fire_held = false
		return

	# From here the view is written by look_at_point(); look_delta stays zero so
	# the player's own look pass leaves that aim alone.
	InputHub.look_delta = Vector2.ZERO
	if _autopilot_target == null or not is_instance_valid(_autopilot_target) \
			or not _autopilot_target.alive:
		_resolve_autopilot_target()
	if _autopilot_target == null:
		InputHub.move = Vector2(0.0, 0.6)
		InputHub.fire_held = false
		return

	_aim_point = _autopilot_target.eye_position()
	# Upper chest rather than the head: a burst that lands is worth more to a
	# screenshot than one that whiffs over a crouching silhouette.
	_aim_point.y -= 0.22
	if player.has_method("look_at_point"):
		player.call("look_at_point", _aim_point)

	# Aim is locked on the target, so "forward" closes the distance to it. Give
	# up walking once close enough, or if the route is blocked and time is up.
	var gap := player.global_position.distance_squared_to(
		_autopilot_target.global_position)
	if gap > AP_ENGAGE_RANGE * AP_ENGAGE_RANGE and t < AP_APPROACH_MAX:
		InputHub.move = Vector2(0.0, 1.0)
	else:
		InputHub.move = Vector2(sin(t * 1.3) * 0.5, 0.0)

	# Repeating burst, so any capture instant lands on a live gunfight rather
	# than a lull, plus a reload the moment the magazine runs dry.
	InputHub.fire_held = fmod(t, AP_BURST_PERIOD) > AP_BURST_PERIOD - AP_BURST_LEN
	if player.get_mag(player.current_weapon_id()) <= 0:
		InputHub.reload_pressed = true


func _resolve_autopilot_target() -> void:
	_autopilot_target = null
	if player == null:
		return
	var best := INF
	for c in _dummies:
		if c == null or not is_instance_valid(c) or not c.alive:
			continue
		var d := c.global_position.distance_squared_to(player.global_position)
		if d < best:
			best = d
			_autopilot_target = c
