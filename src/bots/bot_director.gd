class_name BotDirector
extends Node
## Creates and manages the bot roster: spawning, naming, role assignment and the
## per-team blackboards. The match controller owns one of these.
##
## Role assignment is deliberate rather than random: a defending side always gets
## an anchor on each site plus a rotator, and an attacking side always gets an
## entry, a support and a bomb carrier. A team of five identical "go to site"
## bots is the thing that most makes an offline match feel fake.

const BOT_SCENE := "res://scenes/characters/bot.tscn"

## Original callsigns, deliberately not resembling any real person or brand.
const NAMES_ATK := ["Ember", "Kestrel", "Rook", "Cinder", "Vulcan", "Wraith", "Ash", "Torch"]
const NAMES_DEF := ["Bastion", "Sentry", "Quarry", "Warden", "Anvil", "Beacon", "Slate", "Keel"]

var blackboards := {}                  ## team -> BotBlackboard
var bots: Array[BotBrain] = []
var map_info: Node = null
var difficulty: int = 1

var _bot_scene: PackedScene = null
var _rng := RandomNumberGenerator.new()
var _next_id := 1


func _ready() -> void:
	_rng.randomize()


func setup(p_map: Node, p_difficulty: int) -> void:
	map_info = p_map
	difficulty = clampi(p_difficulty, 0, 2)
	blackboards[GameState.Team.ATK] = BotBlackboard.new(GameState.Team.ATK, difficulty)
	blackboards[GameState.Team.DEF] = BotBlackboard.new(GameState.Team.DEF, difficulty)


func _process(delta: float) -> void:
	for bb in blackboards.values():
		(bb as BotBlackboard).tick(delta)


## Fill both teams to `per_team`, skipping the slot the human occupies.
func populate(per_team: int, human_team: int, parent: Node) -> void:
	_bot_scene = load(BOT_SCENE) if ResourceLoader.exists(BOT_SCENE) else null
	if _bot_scene == null:
		push_error("BotDirector: %s missing; cannot spawn bots" % BOT_SCENE)
		return

	for team in [GameState.Team.ATK, GameState.Team.DEF]:
		var wanted := per_team - (1 if team == human_team else 0)
		var pool: Array = NAMES_ATK.duplicate() if team == GameState.Team.ATK else NAMES_DEF.duplicate()
		for i in wanted:
			var display_name: String = pool[i % pool.size()]
			_spawn_bot(team, display_name, parent)

	assign_roles()


func _spawn_bot(team: int, display_name: String, parent: Node) -> BotBrain:
	var inst := _bot_scene.instantiate()
	var bot := inst as BotBrain
	if bot == null:
		inst.free()
		push_error("BotDirector: %s root is not a BotBrain" % BOT_SCENE)
		return null
	var id := _next_id
	_next_id += 1
	parent.add_child(bot)
	bot.setup(team, id, difficulty, blackboards[team], map_info)
	bot.add_to_group("combatant")
	GameState.register_player(id, display_name, team, false)
	bots.append(bot)
	return bot


## Assign roles per side. Called at match start and re-called after a side swap.
func assign_roles() -> void:
	for team in [GameState.Team.ATK, GameState.Team.DEF]:
		var squad: Array[BotBrain] = []
		for b in bots:
			if b.team == team:
				squad.append(b)
		if squad.is_empty():
			continue
		squad.shuffle()
		if team == GameState.Team.ATK:
			_assign_attack_roles(squad)
		else:
			_assign_defend_roles(squad)


func _assign_attack_roles(squad: Array[BotBrain]) -> void:
	# Priority order: someone must carry the bomb, someone must enter, someone
	# must trade. Extras lurk and anchor the flank.
	var order := [BotBrain.Role.CARRIER, BotBrain.Role.ENTRY, BotBrain.Role.SUPPORT,
		BotBrain.Role.LURK, BotBrain.Role.ANCHOR]
	for i in squad.size():
		squad[i].role = order[i] if i < order.size() else BotBrain.Role.SUPPORT


func _assign_defend_roles(squad: Array[BotBrain]) -> void:
	# Both sites must be held before anyone plays a luxury angle.
	var order := [BotBrain.Role.SITE_ANCHOR, BotBrain.Role.SITE_ANCHOR,
		BotBrain.Role.FLEX, BotBrain.Role.ANGLE, BotBrain.Role.ROTATOR]
	for i in squad.size():
		squad[i].role = order[i] if i < order.size() else BotBrain.Role.FLEX
	# Pin the two anchors to different sites so they don't stack.
	var anchor_index := 0
	for b in squad:
		if b.role == BotBrain.Role.SITE_ANCHOR:
			b.set_meta("anchor_site", "A" if anchor_index == 0 else "B")
			anchor_index += 1


## Called by the round director at the start of every FREEZE_BUY.
func run_buys() -> void:
	for team in [GameState.Team.ATK, GameState.Team.DEF]:
		var money: Array = []
		for b in bots:
			if b.team == team:
				money.append(Economy.get_money(b.player_id))
		var bb := blackboards[team] as BotBlackboard
		bb.decide_economy(money, int(GameState.loss_streak.get(team, 0)))
	for b in bots:
		if b.alive:
			b.run_buy_logic()


func reset_round() -> void:
	for bb in blackboards.values():
		(bb as BotBlackboard).reset_round()
	for b in bots:
		b.reset_for_round()
	# Re-roll roles occasionally so the same bot isn't always the entry — the
	# player shouldn't be able to learn one bot's habits for a whole match.
	if _rng.randf() < 0.35:
		assign_roles()


func on_side_swap() -> void:
	for b in bots:
		var p: Dictionary = GameState.players.get(b.player_id, {})
		if not p.is_empty():
			b.team = int(p.team)
		b.blackboard = blackboards[b.team]
	assign_roles()


## Broadcast a world noise so nearby bots can react to it.
func broadcast_noise(pos: Vector3, loudness: float) -> void:
	for b in bots:
		if b.alive:
			b.hear_noise(pos, loudness)


func alive_bots(team: int) -> int:
	var n := 0
	for b in bots:
		if b.team == team and b.alive:
			n += 1
	return n


## Pick the attacker who should carry the bomb: the designated carrier if alive,
## otherwise anyone on the attacking side.
func pick_bomb_carrier() -> BotBrain:
	for b in bots:
		if b.team == GameState.Team.ATK and b.alive and b.role == BotBrain.Role.CARRIER:
			return b
	for b in bots:
		if b.team == GameState.Team.ATK and b.alive:
			return b
	return null


func clear() -> void:
	for b in bots:
		if is_instance_valid(b):
			b.queue_free()
	bots.clear()
	blackboards.clear()
	_next_id = 1
