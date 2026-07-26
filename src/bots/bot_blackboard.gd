class_name BotBlackboard
extends RefCounted
## Per-team shared knowledge. One instance per team, owned by BotDirector.
##
## This is what makes a bot team read as a *team*: the site call, the
## save-or-force decision and enemy sightings are decided once and shared,
## instead of five bots each independently rolling the dice. See docs/BOT_AI.md.

const CONTACT_TTL := 6.0        ## s a reported enemy contact stays actionable
const CONTACT_MAX := 16         ## preallocated contact slots (never grows)

## Reported enemy sighting. Positions carry error, so bots never get exact truth
## from a teammate — only from their own eyes.
class Contact:
	var enemy_id: int = -1
	var pos: Vector3 = Vector3.ZERO
	var time: float = 0.0
	var reporter_id: int = -1
	var confident: bool = false   ## true = seen directly, false = heard

	func reset() -> void:
		enemy_id = -1
		pos = Vector3.ZERO
		time = 0.0
		reporter_id = -1
		confident = false


var team: int = -1
var difficulty: int = 1

## Round plan
var called_site: String = ""            ## "A" / "B" — attackers' committed site
var site_committed: bool = false
var executing: bool = false             ## push has started
var eco_round: bool = false             ## team agreed to save
var force_round: bool = false

## Live knowledge
var contacts: Array[Contact] = []
var enemies_seen_at_site := {"A": 0.0, "B": 0.0}   ## last time an enemy was seen at each
var bomb_carrier_id: int = -1
var bomb_dropped_pos: Vector3 = Vector3.ZERO
var bomb_is_dropped: bool = false

## Post-round memory, used to bias the next call so bots aren't predictable.
var last_called_site: String = ""
var last_round_won: bool = false

var _time: float = 0.0
var _free_contacts: Array[Contact] = []


func _init(p_team: int, p_difficulty: int) -> void:
	team = p_team
	difficulty = p_difficulty
	contacts.resize(0)
	for i in CONTACT_MAX:
		_free_contacts.append(Contact.new())


func tick(delta: float) -> void:
	_time += delta
	# Expire stale contacts back into the free list; iterate backwards so
	# removal doesn't skip entries.
	for i in range(contacts.size() - 1, -1, -1):
		if _time - contacts[i].time > CONTACT_TTL:
			var c: Contact = contacts[i]
			contacts.remove_at(i)
			c.reset()
			_free_contacts.append(c)


func reset_round() -> void:
	last_called_site = called_site
	called_site = ""
	site_committed = false
	executing = false
	bomb_is_dropped = false
	bomb_carrier_id = -1
	enemies_seen_at_site["A"] = -999.0
	enemies_seen_at_site["B"] = -999.0
	for c in contacts:
		c.reset()
		_free_contacts.append(c)
	contacts.clear()


func report_contact(enemy_id: int, pos: Vector3, reporter_id: int, confident: bool) -> void:
	# Refresh an existing contact for this enemy rather than piling up entries.
	for c in contacts:
		if c.enemy_id == enemy_id:
			# A direct sighting always wins over a stale or heard one.
			if confident or not c.confident:
				c.pos = pos
				c.time = _time
				c.reporter_id = reporter_id
				c.confident = confident
			return
	if _free_contacts.is_empty():
		return
	var nc: Contact = _free_contacts.pop_back()
	nc.enemy_id = enemy_id
	nc.pos = pos
	nc.time = _time
	nc.reporter_id = reporter_id
	nc.confident = confident
	contacts.append(nc)


func forget_enemy(enemy_id: int) -> void:
	for i in range(contacts.size() - 1, -1, -1):
		if contacts[i].enemy_id == enemy_id:
			var c: Contact = contacts[i]
			contacts.remove_at(i)
			c.reset()
			_free_contacts.append(c)
			return


func contact_count() -> int:
	return contacts.size()


func newest_contact() -> Contact:
	var best: Contact = null
	for c in contacts:
		if best == null or c.time > best.time:
			best = c
	return best


func note_enemy_at_site(site: String) -> void:
	if enemies_seen_at_site.has(site):
		enemies_seen_at_site[site] = _time


func enemies_recently_at(site: String, window := 8.0) -> bool:
	return _time - float(enemies_seen_at_site.get(site, -999.0)) < window


## Attackers pick a site. Weighted by where the enemy is known to be (avoid it),
## by not repeating the last call every round, and by a random component so the
## player can't simply pre-aim one site all match.
func choose_site(rng: RandomNumberGenerator) -> String:
	if site_committed:
		return called_site
	var score_a := 1.0
	var score_b := 1.0
	if enemies_recently_at("A"):
		score_a -= 0.55
	if enemies_recently_at("B"):
		score_b -= 0.55
	if last_called_site == "A":
		score_a -= 0.25
	elif last_called_site == "B":
		score_b -= 0.25
	score_a += rng.randf() * 0.6
	score_b += rng.randf() * 0.6
	called_site = "A" if score_a >= score_b else "B"
	site_committed = true
	return called_site


## The team saves or forces together — a team where two bots eco and three
## full-buy is the classic AI tell.
func decide_economy(team_money: Array, rounds_lost_in_a_row: int) -> void:
	if team_money.is_empty():
		eco_round = false
		force_round = false
		return
	var total := 0
	for m in team_money:
		total += int(m)
	var avg := float(total) / float(team_money.size())
	# Enough for a rifle + armour each: full buy.
	if avg >= 4200.0:
		eco_round = false
		force_round = false
	elif avg >= 2400.0:
		# Can't all afford rifles, but a coordinated force with armour + SMGs is
		# better than trickling in with pistols.
		eco_round = false
		force_round = true
	else:
		# Save together, unless we're on the brink and there is no next round to
		# save for.
		eco_round = rounds_lost_in_a_row < 3
		force_round = not eco_round
