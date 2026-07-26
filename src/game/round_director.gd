class_name RoundDirector
extends Node
## The bomb-defusal round state machine: freeze/buy -> live -> planted ->
## round end -> halftime -> match end, plus win detection, economy payouts,
## equipment carry-over and side swap.
##
## Owns *rules*, not presentation. It drives GameState (which everything else
## observes) and asks the match controller to do world work through a small
## interface, so the same rules can run with or without a rendered match:
##
##   world.spawn_round(round_number)      place everyone at spawns, reset bodies
##   world.give_round_equipment()         issued weapons, carry-over survivors
##   world.run_bot_buys()                 bots purchase during FREEZE_BUY
##   world.assign_bomb()                  hand the bomb to an attacker
##   world.reset_world_effects()          clear smokes/fires/grenades/decals
##   world.get_bomb()                     -> Bomb or null
##
## Phase transitions all go through _set_phase so nothing can advance the clock
## without announcing it.

signal phase_elapsed(phase: int)

const ROUND_END_TIME := 5.0
const HALFTIME_TIME := 8.0
const MATCH_END_TIME := 10.0
const WARMUP_TIME := 3.0

var world: Node = null                  ## the match controller (see interface above)
var running: bool = false

var _timer: float = 0.0
var _pending_win_team: int = GameState.Team.NONE
var _pending_reason: int = -1
var _bomb_connected: bool = false


func start_match(p_world: Node) -> void:
	world = p_world
	running = true
	GameState.round_number = 0
	GameState.score[GameState.Team.ATK] = 0
	GameState.score[GameState.Team.DEF] = 0
	GameState.loss_streak[GameState.Team.ATK] = 0
	GameState.loss_streak[GameState.Team.DEF] = 0
	Economy.reset(GameState.players.keys())
	_set_phase(GameState.Phase.WARMUP, WARMUP_TIME)


func stop() -> void:
	running = false
	_set_phase(GameState.Phase.IDLE, 0.0)


func _process(delta: float) -> void:
	if not running:
		return
	if _timer > 0.0:
		_timer = maxf(0.0, _timer - delta)
		GameState.phase_time_left = _timer

	match GameState.phase:
		GameState.Phase.WARMUP:
			if _timer <= 0.0:
				_begin_round()
		GameState.Phase.FREEZE_BUY:
			if _timer <= 0.0:
				_go_live()
		GameState.Phase.LIVE:
			_check_live_win()
			if running and GameState.phase == GameState.Phase.LIVE and _timer <= 0.0:
				# Time expired with no plant: defenders hold.
				_end_round(GameState.Team.DEF, GameState.WinReason.TIME)
		GameState.Phase.PLANTED:
			# The bomb owns its own fuse and tells us when it detonates or is
			# defused; we only watch for an elimination win here.
			_check_planted_win()
		GameState.Phase.ROUND_END:
			if _timer <= 0.0:
				_after_round_end()
		GameState.Phase.HALFTIME:
			if _timer <= 0.0:
				_begin_round()
		GameState.Phase.MATCH_END:
			pass


# ---------------------------------------------------------------- round start

func _begin_round() -> void:
	GameState.round_number += 1
	GameState.bomb_planted_site = ""
	_pending_win_team = GameState.Team.NONE
	_pending_reason = -1
	_bomb_connected = false

	if world:
		if world.has_method("reset_world_effects"):
			world.reset_world_effects()
		if world.has_method("spawn_round"):
			world.spawn_round(GameState.round_number)
		if world.has_method("give_round_equipment"):
			world.give_round_equipment()
		if world.has_method("assign_bomb"):
			world.assign_bomb()

	for p in GameState.players.values():
		p.alive = true

	_set_phase(GameState.Phase.FREEZE_BUY, GameState.cfg_freeze_time)
	GameState.round_started.emit(GameState.round_number)

	# Bots buy immediately so their loadout is visible during the freeze, the
	# same window the player buys in.
	if world and world.has_method("run_bot_buys"):
		world.run_bot_buys()


func _go_live() -> void:
	_set_phase(GameState.Phase.LIVE, GameState.cfg_round_time)
	_connect_bomb()


func _connect_bomb() -> void:
	if _bomb_connected or world == null or not world.has_method("get_bomb"):
		return
	var bomb = world.get_bomb()
	if bomb == null:
		return
	_bomb_connected = true
	if not bomb.planted.is_connected(_on_bomb_planted):
		bomb.planted.connect(_on_bomb_planted)
	if not bomb.defused.is_connected(_on_bomb_defused):
		bomb.defused.connect(_on_bomb_defused)
	if not bomb.exploded.is_connected(_on_bomb_exploded):
		bomb.exploded.connect(_on_bomb_exploded)


# ---------------------------------------------------------------- win checks

func _check_live_win() -> void:
	# Attackers wiped before planting: defenders win. Defenders wiped: attackers
	# win — the bomb no longer needs planting once nobody can defuse.
	if GameState.alive_count(GameState.Team.ATK) == 0:
		_end_round(GameState.Team.DEF, GameState.WinReason.ELIMINATION)
	elif GameState.alive_count(GameState.Team.DEF) == 0:
		_end_round(GameState.Team.ATK, GameState.WinReason.ELIMINATION)


func _check_planted_win() -> void:
	# After a plant, wiping the attackers does NOT win the round — the bomb is
	# still ticking and must be defused. Only wiping the defenders ends it.
	if GameState.alive_count(GameState.Team.DEF) == 0:
		var bomb = world.get_bomb() if world and world.has_method("get_bomb") else null
		if bomb == null or bomb.defuser == null:
			_end_round(GameState.Team.ATK, GameState.WinReason.DETONATION)


func _on_bomb_planted(site: String) -> void:
	if GameState.phase != GameState.Phase.LIVE:
		return
	GameState.bomb_planted_site = site
	_set_phase(GameState.Phase.PLANTED, GameState.cfg_bomb_time)
	GameState.bomb_planted.emit(site)
	# Plant reward goes to the whole attacking side.
	for p in GameState.players.values():
		if p.team == GameState.Team.ATK:
			Economy.add(p.id, Economy.PLANT_REWARD)


func _on_bomb_defused(defuser_id: int) -> void:
	if GameState.phase != GameState.Phase.PLANTED:
		return
	if defuser_id >= 0:
		Economy.add(defuser_id, Economy.DEFUSE_REWARD)
	GameState.bomb_defused.emit()
	_end_round(GameState.Team.DEF, GameState.WinReason.DEFUSE)


func _on_bomb_exploded() -> void:
	if GameState.phase != GameState.Phase.PLANTED:
		return
	GameState.bomb_exploded.emit()
	_end_round(GameState.Team.ATK, GameState.WinReason.DETONATION)


# ---------------------------------------------------------------- round end

func _end_round(winning_team: int, reason: int) -> void:
	if GameState.phase == GameState.Phase.ROUND_END:
		return
	_pending_win_team = winning_team
	_pending_reason = reason
	GameState.score[winning_team] = int(GameState.score[winning_team]) + 1
	Economy.award_round_end(winning_team)
	_set_phase(GameState.Phase.ROUND_END, ROUND_END_TIME)
	GameState.round_won.emit(winning_team, reason)
	AudioMgr.play_ui("round_win" if winning_team == GameState.cfg_player_team else "round_lose")


func _after_round_end() -> void:
	var atk: int = int(GameState.score[GameState.Team.ATK])
	var def: int = int(GameState.score[GameState.Team.DEF])
	var target: int = GameState.cfg_rounds_to_win

	if atk >= target or def >= target:
		var winner: int = GameState.Team.ATK if atk > def else GameState.Team.DEF
		_set_phase(GameState.Phase.MATCH_END, MATCH_END_TIME)
		GameState.match_over.emit(winner)
		AudioMgr.play_ui("match_win")
		running = false
		return

	if _is_halftime():
		_do_halftime()
		return

	_begin_round()


## Halftime falls at the round where each side has played half the maximum
## rounds — with rounds_to_win = N the first half is N rounds long.
func _is_halftime() -> bool:
	return GameState.round_number == GameState.cfg_rounds_to_win


func _do_halftime() -> void:
	GameState.swap_sides()
	# Both sides restart the economy at halftime, as the genre does.
	Economy.reset(GameState.players.keys())
	GameState.loss_streak[GameState.Team.ATK] = 0
	GameState.loss_streak[GameState.Team.DEF] = 0
	if world and world.has_method("on_halftime"):
		world.on_halftime()
	_set_phase(GameState.Phase.HALFTIME, HALFTIME_TIME)


# ---------------------------------------------------------------- kills

## Called by the match controller when any combatant dies.
func on_kill(killer_id: int, victim_id: int, weapon_id: String, headshot: bool) -> void:
	var victim: Dictionary = GameState.players.get(victim_id, {})
	if not victim.is_empty():
		victim.alive = false
		victim.deaths = int(victim.deaths) + 1

	if killer_id >= 0 and killer_id != victim_id:
		var killer: Dictionary = GameState.players.get(killer_id, {})
		if not killer.is_empty():
			# Team kills cost money instead of paying out.
			if killer.team == victim.get("team", GameState.Team.NONE):
				Economy.add(killer_id, -300)
			else:
				killer.kills = int(killer.kills) + 1
				var def := WeaponDB.get_def(weapon_id)
				Economy.add(killer_id, int(def.get("kill_reward", 300)))

	GameState.kill_feed.emit(killer_id, victim_id, weapon_id, headshot)


# ---------------------------------------------------------------- helpers

func _set_phase(p: int, duration: float) -> void:
	_timer = duration
	GameState.set_phase(p, duration)
	phase_elapsed.emit(p)


func phase_time_left() -> float:
	return _timer


func buy_allowed(team: int, in_buy_zone: bool) -> bool:
	# Buying is restricted to the buy zone during the freeze window, and for a
	# short grace period after going live.
	if not in_buy_zone:
		return false
	if GameState.phase == GameState.Phase.FREEZE_BUY:
		return true
	if GameState.phase == GameState.Phase.LIVE:
		return GameState.cfg_round_time - _timer < 12.0
	return false


func win_reason_text(reason: int) -> String:
	match reason:
		GameState.WinReason.ELIMINATION: return "Enemy team eliminated"
		GameState.WinReason.DETONATION: return "Target destroyed"
		GameState.WinReason.DEFUSE: return "Bomb defused"
		GameState.WinReason.TIME: return "Time expired"
	return ""
