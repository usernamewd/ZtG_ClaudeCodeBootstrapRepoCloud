extends Node
## Match + round state machine. Owns the player roster and round flow.
## The active Match scene drives ticks; menus read/reset this between matches.

signal phase_changed(phase: int)
signal round_started(round_number: int)
signal round_won(team: int, reason: int)
signal match_over(winning_team: int)
signal bomb_planted(site: String)
signal bomb_defused
signal bomb_exploded
signal kill_feed(killer_id: int, victim_id: int, weapon_id: String, headshot: bool)
signal money_changed(player_id: int)

enum Team { NONE = -1, ATK = 0, DEF = 1 }  # ATK plants, DEF defends/defuses
enum Phase { IDLE, WARMUP, FREEZE_BUY, LIVE, PLANTED, ROUND_END, HALFTIME, MATCH_END }
enum WinReason { ELIMINATION, DETONATION, DEFUSE, TIME }

const TEAM_NAMES := {Team.ATK: "Havoc", Team.DEF: "Aegis"}

# Match config (set from menu before load)
var cfg_map: String = "saltline"
var cfg_bot_difficulty: int = 1        # 0 easy 1 normal 2 hard
var cfg_player_team: int = Team.DEF
var cfg_rounds_to_win: int = 7         # short match MR6-style default for mobile
var cfg_round_time: float = 115.0
var cfg_freeze_time: float = 8.0
var cfg_bomb_time: float = 40.0
var cfg_defuse_time: float = 10.0
var cfg_defuse_kit_time: float = 5.0
var cfg_plant_time: float = 3.2

# Live state
var phase: int = Phase.IDLE
var round_number: int = 0
var score := {Team.ATK: 0, Team.DEF: 0}
var phase_time_left: float = 0.0
var bomb_planted_site: String = ""
var loss_streak := {Team.ATK: 0, Team.DEF: 0}

## Roster: player_id -> info dict
## {id, name, team, is_human, kills, deaths, assists, alive, money handled by Economy}
var players: Dictionary = {}


func reset_match() -> void:
	phase = Phase.IDLE
	round_number = 0
	score = {Team.ATK: 0, Team.DEF: 0}
	loss_streak = {Team.ATK: 0, Team.DEF: 0}
	players.clear()
	bomb_planted_site = ""


func register_player(id: int, display_name: String, team: int, is_human: bool) -> void:
	players[id] = {
		"id": id, "name": display_name, "team": team, "is_human": is_human,
		"kills": 0, "deaths": 0, "assists": 0, "alive": true,
	}


func set_phase(p: int, time_left: float = 0.0) -> void:
	phase = p
	phase_time_left = time_left
	phase_changed.emit(p)


func team_of(id: int) -> int:
	return players.get(id, {}).get("team", Team.NONE)


func alive_count(team: int) -> int:
	var n := 0
	for p in players.values():
		if p.team == team and p.alive:
			n += 1
	return n


func swap_sides() -> void:
	for p in players.values():
		p.team = Team.DEF if p.team == Team.ATK else Team.ATK
	var s: int = score[Team.ATK]
	score[Team.ATK] = score[Team.DEF]
	score[Team.DEF] = s
	# NOTE: score dict is keyed by team id; after side swap the scores travel
	# with the squads, so swapping the values keeps "score of the squad now
	# playing ATK" correct.
