class_name MatchController
extends Node
## Runs a complete bomb-defusal match: loads the map, spawns the player and
## bots, builds the HUD, and implements the world interface RoundDirector calls
## (see src/game/round_director.gd for that contract).
##
## Division of labour:
##   RoundDirector  owns the RULES  (phases, timers, win conditions, payouts)
##   MatchController owns the WORLD (nodes, spawning, bodies, HUD, bomb, pools)
## Keeping them apart is what lets the round rules be reasoned about without a
## rendered scene.

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const PLAYER_SCENE := "res://scenes/characters/player.tscn"
const BOT_SCENE := "res://scenes/characters/bot.tscn"
const BOMB_SCENE := "res://scenes/game/bomb.tscn"
const HUD_SCENE := "res://scenes/ui/hud.tscn"

const MAP_SCENES := {
	"saltline": "res://scenes/maps/saltline.tscn",
	"transit": "res://scenes/maps/transit.tscn",
	"graybox": "res://scenes/maps/graybox.tscn",
}

const TEAM_SIZE := 5
const LOCAL_PLAYER_ID := 0

## Pooled effect scenes: key -> [scene path, preallocated count].
const POOL_SPEC := {
	"tracer": ["res://scenes/weapons/tracer.tscn", 24],
	"impact": ["res://scenes/weapons/impact.tscn", 24],
	"grenade": ["res://scenes/weapons/grenade.tscn", 12],
	"smoke_volume": ["res://scenes/weapons/smoke_volume.tscn", 6],
	"fire_area": ["res://scenes/weapons/fire_area.tscn", 4],
	"frag_blast": ["res://scenes/weapons/frag_blast.tscn", 6],
	"flash_blast": ["res://scenes/weapons/flash_blast.tscn", 6],
	"bomb_blast": ["res://scenes/weapons/bomb_blast.tscn", 2],
}

var map_root: Node3D = null
var map_info: Node = null
var player: CharacterBase = null
var bomb: Bomb = null
var hud: Node = null
var round_director: RoundDirector = null
var bot_director: BotDirector = null

var _buy_menu: BuyMenu = null
var _scoreboard: Scoreboard = null
var _radar: Radar = null
var _kill_feed: KillFeed = null
var _nametags: Nametags = null

var _stats := {"kills": 0, "rounds_won": 0, "rounds_played": 0}
var _autopilot := false
var _autopilot_time := 0.0
var _ending := false


func _ready() -> void:
	add_to_group("match_controller")
	_autopilot = OS.get_environment("TS_AUTOPILOT") != ""
	Settings.apply_graphics_preset()

	_setup_pools()
	if not _load_map():
		return
	# Re-apply now that the map's sun exists; the call in _ready ran against an
	# empty scene and could not reach it.
	Settings.apply_shadow_preset()
	_spawn_player()
	_spawn_bots()
	_spawn_bomb()
	_build_hud()
	_start_match()


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
	var path := String(MAP_SCENES.get(GameState.cfg_map, ""))
	if path == "" or not ResourceLoader.exists(path):
		# Fall back to any map that exists rather than dropping the player into
		# an empty scene.
		for candidate in MAP_SCENES.values():
			if ResourceLoader.exists(String(candidate)):
				path = String(candidate)
				break
	if path == "":
		push_error("MatchController: no map scene available")
		return false
	var packed: PackedScene = load(path)
	map_root = packed.instantiate() as Node3D
	if map_root == null:
		push_error("MatchController: map root is not a Node3D: " + path)
		return false
	add_child(map_root)
	map_info = map_root
	return true


func _spawn_player() -> void:
	if not ResourceLoader.exists(PLAYER_SCENE):
		push_error("MatchController: missing " + PLAYER_SCENE)
		return
	player = (load(PLAYER_SCENE) as PackedScene).instantiate() as CharacterBase
	if player == null:
		return
	player.team = GameState.cfg_player_team
	player.player_id = LOCAL_PLAYER_ID
	add_child(player)
	player.add_to_group("combatant")
	GameState.register_player(LOCAL_PLAYER_ID, Settings.player_name,
		GameState.cfg_player_team, true)
	player.died.connect(_on_character_died.bind(player))


func _spawn_bots() -> void:
	bot_director = BotDirector.new()
	bot_director.name = "BotDirector"
	add_child(bot_director)
	bot_director.setup(map_info, GameState.cfg_bot_difficulty)
	if ResourceLoader.exists(BOT_SCENE):
		bot_director.populate(TEAM_SIZE, GameState.cfg_player_team, self)
		for b in bot_director.bots:
			b.died.connect(_on_character_died.bind(b))
	else:
		push_warning("MatchController: %s missing; running without bots" % BOT_SCENE)


func _spawn_bomb() -> void:
	if not ResourceLoader.exists(BOMB_SCENE):
		push_warning("MatchController: %s missing; objective disabled" % BOMB_SCENE)
		return
	bomb = (load(BOMB_SCENE) as PackedScene).instantiate() as Bomb
	if bomb:
		add_child(bomb)


func _build_hud() -> void:
	if ResourceLoader.exists(HUD_SCENE):
		hud = (load(HUD_SCENE) as PackedScene).instantiate()
		add_child(hud)
		if hud.has_method("bind_player"):
			hud.bind_player(player)

	# Widgets the HUD scene may not own yet are attached here so a partial HUD
	# still yields a complete match experience.
	var layer := CanvasLayer.new()
	layer.name = "MatchHUD"
	layer.layer = 2
	add_child(layer)

	_radar = Radar.new()
	_radar.name = "Radar"
	_radar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_radar.position = Vector2(18, 18)
	_radar.set_meta("hud_id", "radar")
	_radar.add_to_group("hud_movable")
	layer.add_child(_radar)
	_radar.bind(map_info, player)

	_kill_feed = KillFeed.new()
	_kill_feed.name = "KillFeed"
	_kill_feed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_kill_feed.offset_left = -420.0
	_kill_feed.offset_right = -12.0
	_kill_feed.offset_top = 16.0
	_kill_feed.local_player_id = LOCAL_PLAYER_ID
	_kill_feed.set_meta("hud_id", "killfeed")
	_kill_feed.add_to_group("hud_movable")
	layer.add_child(_kill_feed)

	_nametags = Nametags.new()
	_nametags.name = "Nametags"
	layer.add_child(_nametags)
	var cam := _find_camera(player)
	if cam:
		_nametags.bind(cam, player)

	var round_bar := RoundBar.new()
	round_bar.name = "RoundBar"
	round_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	round_bar.offset_left = -190.0
	round_bar.offset_right = 190.0
	round_bar.offset_top = 8.0
	round_bar.offset_bottom = 74.0
	round_bar.set_meta("hud_id", "roundbar")
	round_bar.add_to_group("hud_movable")
	round_bar.controller = self
	layer.add_child(round_bar)

	_buy_menu = BuyMenu.new()
	_buy_menu.name = "BuyMenu"
	layer.add_child(_buy_menu)

	_scoreboard = Scoreboard.new()
	_scoreboard.name = "Scoreboard"
	_scoreboard.local_player_id = LOCAL_PLAYER_ID
	layer.add_child(_scoreboard)

	layer.add_child(_make_hud_button("BUY", Vector2(18, 232), func():
		_buy_menu.in_buy_zone = _player_in_buy_zone()
		_buy_menu.toggle(), "buy"))
	layer.add_child(_make_hud_button("SCORE", Vector2(128, 232), func():
		_scoreboard.toggle(), "score"))

	_buy_menu.bind(player, round_director)


func _make_hud_button(text: String, at: Vector2, cb: Callable,
		hud_id: String) -> Button:
	var b := Button.new()
	b.text = text
	b.position = at
	b.custom_minimum_size = Vector2(96, UITheme.TOUCH_MIN)
	b.size = b.custom_minimum_size
	b.set_meta("hud_id", hud_id)
	b.add_to_group("hud_movable")
	b.pressed.connect(cb)
	return b


func _start_match() -> void:
	round_director = RoundDirector.new()
	round_director.name = "RoundDirector"
	add_child(round_director)
	if _buy_menu:
		_buy_menu.round_director = round_director
	GameState.round_won.connect(_on_round_won)
	GameState.match_over.connect(_on_match_over)
	round_director.start_match(self)


# ---------------------------------------------------------------------------
# The world interface RoundDirector calls
# ---------------------------------------------------------------------------

func spawn_round(_round_number: int) -> void:
	_stats.rounds_played += 1
	var atk_i := 0
	var def_i := 0
	for n in get_tree().get_nodes_in_group("combatant"):
		var c := n as CharacterBase
		if c == null:
			continue
		var index := 0
		if c.team == GameState.Team.ATK:
			index = atk_i
			atk_i += 1
		else:
			index = def_i
			def_i += 1
		c.respawn(_spawn_transform(c.team, index))
		if c is BotBrain:
			(c as BotBrain).reset_for_round()
	if bot_director:
		bot_director.reset_round()
	if bomb:
		bomb.reset()


func give_round_equipment() -> void:
	# Everyone is issued a sidearm and a knife; anything else is bought. Weapons
	# a player survived with are already in their inventory, so this only tops up.
	for n in get_tree().get_nodes_in_group("combatant"):
		var c := n as CharacterBase
		if c == null:
			continue
		if c.weapon_in_slot(CharacterBase.Slot.SECONDARY) == "":
			c.give_weapon("p9", false)
		c.refill_all_ammo()
		c.switch_to_best()


func run_bot_buys() -> void:
	if bot_director:
		bot_director.run_buys()


func assign_bomb() -> void:
	if bomb == null:
		return
	var carrier: CharacterBase = null
	if player and player.team == GameState.Team.ATK and player.alive:
		carrier = player
	elif bot_director:
		carrier = bot_director.pick_bomb_carrier()
	if carrier == null:
		return
	bomb.attach_to(carrier)
	if carrier is BotBrain:
		(carrier as BotBrain).carrying_bomb = true


func reset_world_effects() -> void:
	for group in ["smoke_volume", "fire_area"]:
		for n in get_tree().get_nodes_in_group(group):
			if n.has_method("on_pool_acquire"):
				Pools.release(n)


func get_bomb():
	return bomb


func on_halftime() -> void:
	if player:
		player.team = int(GameState.players.get(LOCAL_PLAYER_ID, {}).get(
			"team", player.team))
	if bot_director:
		bot_director.on_side_swap()


# ---------------------------------------------------------------------------
# Objective actions (called by the player controller and by bots)
# ---------------------------------------------------------------------------

func plant_bomb(planter: CharacterBase, site: String, at: Vector3) -> bool:
	if bomb == null or GameState.phase != GameState.Phase.LIVE:
		return false
	if planter.team != GameState.Team.ATK:
		return false
	var resolved := site
	if resolved == "" and map_info and map_info.has_method("site_containing"):
		resolved = map_info.site_containing(at)
	if resolved == "":
		return false
	bomb.plant(at, resolved, GameState.cfg_bomb_time)
	return true


func begin_defuse(defuser: CharacterBase) -> bool:
	if bomb == null or GameState.phase != GameState.Phase.PLANTED:
		return false
	if defuser.team != GameState.Team.DEF:
		return false
	return bomb.begin_defuse(defuser)


func cancel_defuse() -> void:
	if bomb:
		bomb.cancel_defuse()


## Bots call this when their scripted defuse timer completes; the bomb's own
## progress tracking is the authority for the player.
func defuse_bomb(defuser: CharacterBase) -> void:
	if bomb == null:
		return
	if bomb.defuser == null:
		bomb.begin_defuse(defuser)
	bomb.defuse_elapsed = bomb.defuse_needed
	bomb._tick_defuse(0.0)


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

func _on_character_died(attacker_id: int, weapon_id: String, headshot: bool,
		victim: CharacterBase) -> void:
	if round_director:
		round_director.on_kill(attacker_id, victim.player_id, weapon_id, headshot)
	if attacker_id == LOCAL_PLAYER_ID and victim.player_id != LOCAL_PLAYER_ID:
		_stats.kills += 1
	# A dead bomb carrier drops it where they fell.
	if bomb and bomb.state == Bomb.State.CARRIED and bomb.carrier == victim:
		bomb.drop_at(victim.global_position)
	if bot_director:
		bot_director.broadcast_noise(victim.global_position, 1.0)


func _on_round_won(team: int, _reason: int) -> void:
	if player and team == player.team:
		_stats.rounds_won += 1


func _on_match_over(winning_team: int) -> void:
	if _ending:
		return
	_ending = true
	LoadoutScreen.award_match(int(_stats.rounds_won), int(_stats.rounds_played),
		int(_stats.kills))
	if _scoreboard:
		_scoreboard.show_final(winning_team)


func _spawn_transform(team: int, index: int) -> Transform3D:
	if map_info and map_info.has_method("get_spawn"):
		return map_info.get_spawn(team, index)
	# Read the map's spawn markers directly. Without this, ten characters land on
	# nearly the same point and shove each other out of the level.
	var holder := map_root.get_node_or_null(
		"ATKSpawns" if team == GameState.Team.ATK else "DEFSpawns") if map_root else null
	if holder and holder.get_child_count() > 0:
		var m := holder.get_child(index % holder.get_child_count()) as Node3D
		if m:
			var t := m.global_transform
			# Wrap-around: nudge extra players off the marker so they don't stack.
			var wrap := index / holder.get_child_count()
			if wrap > 0:
				t.origin += Vector3(cos(wrap * 2.4) * 1.4, 0.0, sin(wrap * 2.4) * 1.4)
			t.origin.y += 0.2
			return t
	var side := -18.0 if team == GameState.Team.DEF else 18.0
	return Transform3D(Basis(), Vector3((index - 2) * 2.0, 1.0, side))


func _player_in_buy_zone() -> bool:
	if player == null:
		return false
	if map_info and map_info.has_method("in_buy_zone"):
		return map_info.in_buy_zone(player.team, player.global_position)
	return true


func _find_camera(n: Node) -> Camera3D:
	if n == null:
		return null
	if n is Camera3D:
		return n
	for c in n.get_children():
		var r := _find_camera(c)
		if r:
			return r
	return null


# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _buy_menu and _buy_menu.visible:
		_buy_menu.in_buy_zone = _player_in_buy_zone()
	if _scoreboard and _scoreboard.visible:
		_scoreboard.refresh()
	if _autopilot:
		_run_autopilot(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		leave_match()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		leave_match()


func leave_match() -> void:
	Pools.clear_all()
	GameState.reset_match()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if ResourceLoader.exists(MENU_SCENE):
		get_tree().change_scene_to_file(MENU_SCENE)


## Scripted input so the phase gates can capture a real gameplay frame headlessly
## (see tools/capture.tscn's autopilot_seconds argument). Isolated here and never
## touched by the normal input path.
func _run_autopilot(delta: float) -> void:
	_autopilot_time += delta
	var t := _autopilot_time
	InputHub.move = Vector2(sin(t * 0.7) * 0.4, 1.0 if t < 4.0 else 0.2)
	InputHub.look_delta = Vector2(sin(t * 0.35) * 2.2, cos(t * 0.5) * 0.5)
	InputHub.fire_held = fmod(t, 3.0) > 2.1
	if absf(fmod(t, 6.0) - 5.0) < delta:
		InputHub.reload_pressed = true


## Round timer, bomb state and score, centred at the top of the screen.
class RoundBar extends Control:
	var controller: MatchController = null

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _ready() -> void:
		set_process(true)

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var f := get_theme_default_font()
		if f == null:
			return
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.03, 0.04, 0.05, 0.60))
		draw_rect(r, Color(1, 1, 1, 0.08), false, 1.0)

		var atk := int(GameState.score.get(GameState.Team.ATK, 0))
		var def := int(GameState.score.get(GameState.Team.DEF, 0))

		# Score either side, tinted by team.
		_centered(f, "%d" % atk, Vector2(size.x * 0.16, 40.0), UITheme.FS_TITLE,
			UITheme.TEAM_ATK)
		_centered(f, "%d" % def, Vector2(size.x * 0.84, 40.0), UITheme.FS_TITLE,
			UITheme.TEAM_DEF)

		# Centre: the clock, or the bomb state once planted.
		var mid := Vector2(size.x * 0.5, 34.0)
		if GameState.phase == GameState.Phase.PLANTED:
			var fuse := 0.0
			if controller and controller.bomb:
				fuse = maxf(controller.bomb.fuse_left, 0.0)
			_centered(f, "%0.1f" % fuse, mid, UITheme.FS_HEAD, UITheme.BAD)
			_centered(f, "BOMB DOWN — SITE %s" % GameState.bomb_planted_site,
				Vector2(size.x * 0.5, 54.0), UITheme.FS_TINY, UITheme.BAD)
		else:
			var left: float = maxf(GameState.phase_time_left, 0.0)
			var col := UITheme.TEXT
			if GameState.phase == GameState.Phase.FREEZE_BUY:
				col = UITheme.ACCENT
			elif left < 20.0:
				col = UITheme.WARN
			_centered(f, "%d:%02d" % [int(left) / 60, int(left) % 60], mid,
				UITheme.FS_HEAD, col)
			_centered(f, _phase_text(), Vector2(size.x * 0.5, 54.0),
				UITheme.FS_TINY, UITheme.TEXT_DIM)

		# Alive counts, so you know the trade situation without the scoreboard.
		_centered(f, "%d" % GameState.alive_count(GameState.Team.ATK),
			Vector2(size.x * 0.32, 38.0), UITheme.FS_SMALL, UITheme.TEXT_DIM)
		_centered(f, "%d" % GameState.alive_count(GameState.Team.DEF),
			Vector2(size.x * 0.68, 38.0), UITheme.FS_SMALL, UITheme.TEXT_DIM)

	func _phase_text() -> String:
		match GameState.phase:
			GameState.Phase.FREEZE_BUY: return "BUY TIME"
			GameState.Phase.LIVE: return "ROUND %d" % GameState.round_number
			GameState.Phase.ROUND_END: return "ROUND OVER"
			GameState.Phase.HALFTIME: return "HALFTIME — SIDES SWAP"
			GameState.Phase.MATCH_END: return "MATCH OVER"
			GameState.Phase.WARMUP: return "GET READY"
		return ""

	func _centered(f: Font, text: String, at: Vector2, fs: int, col: Color) -> void:
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(at.x - w * 0.5, at.y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
