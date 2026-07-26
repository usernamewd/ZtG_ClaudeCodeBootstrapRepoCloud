extends Node
## Round economy: money per player, kill/objective rewards, loss bonus streaks,
## purchases. Money values are integers ("credits").

const START_MONEY := 800
const MAX_MONEY := 16000
const WIN_REWARD := 3250
const LOSS_BONUS := [1400, 1900, 2400, 2900, 3400]  # indexed by loss streak - 1
const PLANT_REWARD := 300          # to every ATK player when bomb planted
const DEFUSE_REWARD := 300         # to the defuser
const SURVIVE_LOSS_ATK_PENALTY := true  # ATK survivors who saved get no loss bonus

var money: Dictionary = {}          # player_id -> int


func reset(player_ids: Array) -> void:
	money.clear()
	for id in player_ids:
		money[id] = START_MONEY


func get_money(id: int) -> int:
	return money.get(id, 0)


func add(id: int, amount: int) -> void:
	money[id] = clampi(get_money(id) + amount, 0, MAX_MONEY)
	GameState.money_changed.emit(id)


func can_afford(id: int, price: int) -> bool:
	return get_money(id) >= price


func try_spend(id: int, price: int) -> bool:
	if not can_afford(id, price):
		return false
	add(id, -price)
	return true


func award_round_end(winning_team: int) -> void:
	var losing_team: int = GameState.Team.DEF if winning_team == GameState.Team.ATK else GameState.Team.ATK
	GameState.loss_streak[winning_team] = 0
	GameState.loss_streak[losing_team] = mini(GameState.loss_streak[losing_team] + 1, LOSS_BONUS.size())
	var loss_bonus: int = LOSS_BONUS[GameState.loss_streak[losing_team] - 1]
	for p in GameState.players.values():
		if p.team == winning_team:
			add(p.id, WIN_REWARD)
		else:
			add(p.id, loss_bonus)
