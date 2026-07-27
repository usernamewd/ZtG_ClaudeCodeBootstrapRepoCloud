class_name BuyMenu
extends Control
## Purchase screen, available in the buy zone during buy time.
##
## Layout: a vertical category rail on the left (Pistols / SMGs / Rifles / Heavy /
## Grenades / Gear), a grid of items in the middle, and a detail panel on the
## right showing the selected weapon's real stats read out of WeaponDB. Built
## entirely in code so it stays in sync with the database.
##
## States every item must communicate at a glance: affordable, too expensive,
## already owned, and restricted to the other team.

signal purchased(item_id: String)
signal closed

enum Avail { BUY, TOO_EXPENSIVE, OWNED, WRONG_TEAM, FULL }

const CATEGORIES := [
	{"label": "PISTOLS", "cat": 0},
	{"label": "SMGS", "cat": 1},
	{"label": "RIFLES", "cat": 2},
	{"label": "HEAVY", "cat": 3},
	{"label": "GRENADES", "cat": 5},
	{"label": "GEAR", "cat": 6},
]

var player: CharacterBase = null
var round_director: Node = null
var in_buy_zone: bool = false

var _current_cat: int = 2               ## open on rifles: the common case
var _selected_id: String = ""
var _rail: VBoxContainer = null
var _grid: GridContainer = null
var _detail: VBoxContainer = null
var _money_label: Label = null
var _timer_label: Label = null
var _hint_label: Label = null
var _cat_buttons: Array[Button] = []
var _last_loadout: Array[String] = []


func _ready() -> void:
	theme = UITheme.build()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	# A plain Array from JSON cannot be assigned to an Array[String]; copy it in.
	_last_loadout.clear()
	for id in Persistence.get_value("last_loadout", []):
		_last_loadout.append(String(id))


func bind(p_player: CharacterBase, p_round_director: Node) -> void:
	player = p_player
	round_director = p_round_director
	if player:
		if not player.inventory_changed.is_connected(_refresh_items):
			player.inventory_changed.connect(_refresh_items)
	if not GameState.money_changed.is_connected(_on_money_changed):
		GameState.money_changed.connect(_on_money_changed)


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var root := MarginContainer.new()
	root.add_theme_constant_override("margin_left", 24)
	root.add_theme_constant_override("margin_right", 24)
	root.add_theme_constant_override("margin_top", 18)
	root.add_theme_constant_override("margin_bottom", 18)
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(UITheme.GAP))
	root.add_child(col)

	col.add_child(_build_header())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", int(UITheme.GAP))
	col.add_child(body)

	body.add_child(_build_rail())
	body.add_child(_build_grid_panel())
	body.add_child(_build_detail_panel())

	col.add_child(_build_footer())
	_select_category(_current_cat)


func _build_header() -> Control:
	var p := PanelContainer.new()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 20)
	p.add_child(h)

	var title := Label.new()
	title.text = "EQUIPMENT"
	title.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	title.add_theme_color_override("font_color", UITheme.TEXT)
	h.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)

	_timer_label = Label.new()
	_timer_label.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	_timer_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	h.add_child(_timer_label)

	_money_label = Label.new()
	_money_label.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	h.add_child(_money_label)

	var close := Button.new()
	close.text = "CLOSE"
	close.custom_minimum_size = Vector2(120, UITheme.TOUCH_MIN)
	close.pressed.connect(func(): close_menu())
	h.add_child(close)
	return p


func _build_rail() -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(190, 0)
	_rail = VBoxContainer.new()
	_rail.add_theme_constant_override("separation", 6)
	p.add_child(_rail)

	_cat_buttons.clear()
	for entry in CATEGORIES:
		var b := Button.new()
		b.text = String(entry.label)
		b.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var cat := int(entry.cat)
		b.pressed.connect(func(): _select_category(cat))
		_rail.add_child(b)
		_cat_buttons.append(b)

	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rail.add_child(sp)

	var quick := Button.new()
	quick.text = "QUICK BUY"
	quick.tooltip_text = "Rebuy your last loadout"
	quick.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
	quick.pressed.connect(quick_buy)
	_rail.add_child(quick)
	return p


func _build_grid_panel() -> Control:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Both the scroller and the grid must expand, or the grid collapses to its
	# minimum width and the cards overlap each other.
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(sc)
	_grid = GridContainer.new()
	# One card per row: a weapon card is a wide name/stats/price strip, and two
	# of them side by side are unreadable at phone width.
	_grid.columns = 1
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", int(UITheme.GAP))
	_grid.add_theme_constant_override("v_separation", int(UITheme.GAP))
	sc.add_child(_grid)
	return p


func _build_detail_panel() -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(300, 0)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 8)
	p.add_child(_detail)
	return p


func _build_footer() -> Control:
	var p := PanelContainer.new()
	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	_hint_label.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	_hint_label.text = "Purchases are only possible inside your spawn during buy time. Equipment you survive with carries to the next round."
	p.add_child(_hint_label)
	return p


# ---------------------------------------------------------------------------
# Population
# ---------------------------------------------------------------------------

func _select_category(cat: int) -> void:
	_current_cat = cat
	for i in _cat_buttons.size():
		var active: bool = int(CATEGORIES[i].cat) == cat
		_cat_buttons[i].add_theme_color_override("font_color",
			UITheme.ACCENT if active else UITheme.TEXT_DIM)
	_refresh_items()


func _refresh_items() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		c.queue_free()
	for id in WeaponDB.ids_in_category(_current_cat):
		var def := WeaponDB.get_def(id)
		if def.is_empty():
			continue
		_grid.add_child(_make_item_card(String(id), def))
	_refresh_money()


func _make_item_card(id: String, def: Dictionary) -> Control:
	var avail := _availability(id, def)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 78)
	btn.disabled = avail != Avail.BUY
	btn.pressed.connect(func(): _try_purchase(id))
	# Selecting for the detail panel must work even when the item can't be
	# bought — players compare guns they can't afford yet.
	btn.mouse_entered.connect(func(): _show_detail(id))
	btn.gui_input.connect(func(e: InputEvent): if e is InputEventScreenTouch and e.pressed: _show_detail(id))

	# The label stack lives inside the Button, so it must not eat the touch that
	# triggers the purchase. A Button is not a container, so the stack has to be
	# anchored — and the preset must be applied AFTER parenting, otherwise the
	# offsets are computed against a zero-sized parent and every card collapses
	# onto the same point.
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	btn.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(texts)

	var name_label := Label.new()
	name_label.text = String(def.get("display_name", id)).to_upper()
	name_label.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	name_label.add_theme_color_override("font_color",
		UITheme.TEXT if avail == Avail.BUY else UITheme.TEXT_FAINT)
	texts.add_child(name_label)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	match avail:
		Avail.OWNED:
			sub.text = "OWNED"
			sub.add_theme_color_override("font_color", UITheme.OK)
		Avail.WRONG_TEAM:
			sub.text = "UNAVAILABLE TO YOUR SIDE"
			sub.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
		Avail.FULL:
			sub.text = "CARRYING MAXIMUM"
			sub.add_theme_color_override("font_color", UITheme.WARN)
		Avail.TOO_EXPENSIVE:
			sub.text = "INSUFFICIENT FUNDS"
			sub.add_theme_color_override("font_color", UITheme.BAD)
		_:
			sub.text = _short_stat_line(def)
			sub.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	texts.add_child(sub)

	var price := Label.new()
	price.text = "%d" % int(def.get("price", 0))
	price.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	price.add_theme_color_override("font_color",
		UITheme.ACCENT if avail == Avail.BUY else UITheme.TEXT_FAINT)
	price.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(price)
	return btn


func _short_stat_line(def: Dictionary) -> String:
	var cat := int(def.get("category", -1))
	if cat == 5:      # grenade
		return "%d m radius" % int(def.get("blast_radius", 0))
	if cat == 6:      # gear
		return String(def.get("gear_summary", "Protective equipment"))
	return "%d dmg  ·  %d rpm" % [
		int(def.get("damage", 0)),
		int(float(def.get("fire_rate", 0.0)) * 60.0)]


func _availability(id: String, def: Dictionary) -> int:
	if player == null:
		return Avail.TOO_EXPENSIVE
	var teams := int(def.get("teams", 0))
	# 0 = both; otherwise a bitmask/flag the database defines per side.
	if teams != 0 and not _team_allowed(teams):
		return Avail.WRONG_TEAM
	if int(def.get("category", -1)) == 5:
		var carried: Array = player.slots[CharacterBase.Slot.GRENADE]
		var max_carry := int(def.get("max_carry", 2))
		var same := 0
		for g in carried:
			if String(g) == id:
				same += 1
		if carried.size() >= CharacterBase.MAX_GRENADES or same >= max_carry:
			return Avail.FULL
	elif player.has_weapon(id):
		return Avail.OWNED
	elif id == "armor" and player.armor > 0.0:
		return Avail.OWNED
	elif id == "helmet" and player.has_helmet:
		return Avail.OWNED
	elif id == "defusekit" and player.has_defuse_kit:
		return Avail.OWNED
	if not Economy.can_afford(player.player_id, int(def.get("price", 0))):
		return Avail.TOO_EXPENSIVE
	return Avail.BUY


func _team_allowed(teams: int) -> bool:
	if player == null:
		return false
	# WeaponDB encodes side restriction; ATK == 0, DEF == 1 in GameState.
	if teams == 1:
		return player.team == GameState.Team.ATK
	if teams == 2:
		return player.team == GameState.Team.DEF
	return true


# ---------------------------------------------------------------------------
# Detail panel
# ---------------------------------------------------------------------------

func _show_detail(id: String) -> void:
	_selected_id = id
	var def := WeaponDB.get_def(id)
	for c in _detail.get_children():
		c.queue_free()
	if def.is_empty():
		return

	var title := Label.new()
	title.text = String(def.get("display_name", id)).to_upper()
	title.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	_detail.add_child(title)

	var cat := int(def.get("category", -1))
	if cat == 5 or cat == 6:
		_add_detail_text(String(def.get("description", "")))
		if cat == 5:
			_add_bar("BLAST", float(def.get("blast_radius", 0.0)) / 20.0,
				"%.0f m" % float(def.get("blast_radius", 0.0)))
			_add_bar("EFFECT", float(def.get("effect_time", 0.0)) / 18.0,
				"%.1f s" % float(def.get("effect_time", 0.0)))
		return

	# Bars are normalized against plausible maxima so guns compare visually.
	_add_bar("DAMAGE", float(def.get("damage", 0.0)) / 120.0,
		"%d" % int(def.get("damage", 0)))
	_add_bar("RATE", float(def.get("fire_rate", 0.0)) / 16.0,
		"%d rpm" % int(float(def.get("fire_rate", 0.0)) * 60.0))
	_add_bar("ACCURACY", clampf(1.0 - float(def.get("spread_base", 0.0)) / 4.0, 0.0, 1.0),
		"%.2f°" % float(def.get("spread_base", 0.0)))
	_add_bar("CONTROL", clampf(1.0 - _pattern_severity(def), 0.0, 1.0), "")
	_add_bar("MOBILITY", clampf((float(def.get("move_speed_mult", 1.0)) - 0.6) / 0.45, 0.0, 1.0),
		"%d%%" % int(float(def.get("move_speed_mult", 1.0)) * 100.0))
	_add_bar("PENETRATION", float(def.get("penetration", 0.0)), "")

	var stats := Label.new()
	stats.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	stats.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	stats.text = "%d + %d rounds   ·   %.1fs reload   ·   kill reward %d" % [
		int(def.get("mag", 0)), int(def.get("reserve", 0)),
		float(def.get("reload_time", 0.0)), int(def.get("kill_reward", 0))]
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_child(stats)

	if bool(def.get("scoped", false)):
		_add_detail_text("Telescopic sight. Extremely punishing while moving.")


func _pattern_severity(def: Dictionary) -> float:
	var pattern = def.get("recoil_pattern", [])
	if not (pattern is Array) or (pattern as Array).is_empty():
		return 0.0
	var total := 0.0
	for v in pattern:
		if v is Vector2:
			total += absf((v as Vector2).y) + absf((v as Vector2).x) * 0.5
	return clampf(total / float((pattern as Array).size()) / 3.0, 0.0, 1.0)


func _add_bar(label: String, fraction: float, value: String) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	l.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	if value != "":
		var v := Label.new()
		v.text = value
		v.add_theme_font_size_override("font_size", UITheme.FS_TINY)
		v.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		h.add_child(v)
	row.add_child(h)
	var bar := StatBar.new()
	bar.fraction = clampf(fraction, 0.0, 1.0)
	bar.custom_minimum_size = Vector2(0, 8)
	row.add_child(bar)
	_detail.add_child(row)


func _add_detail_text(text: String) -> void:
	if text == "":
		return
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	l.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_detail.add_child(l)


# ---------------------------------------------------------------------------
# Purchasing
# ---------------------------------------------------------------------------

func _try_purchase(id: String) -> void:
	if player == null:
		return
	if not _buy_allowed():
		AudioMgr.play_ui("buy_denied")
		return
	var def := WeaponDB.get_def(id)
	if def.is_empty() or _availability(id, def) != Avail.BUY:
		AudioMgr.play_ui("buy_denied")
		return
	var price := int(def.get("price", 0))
	if not Economy.try_spend(player.player_id, price):
		AudioMgr.play_ui("buy_denied")
		return

	var ok := false
	if int(def.get("category", -1)) == 6:
		ok = player.give_gear(id, def)
	else:
		ok = player.give_weapon(id, true)
	if not ok:
		Economy.add(player.player_id, price)   # refund a failed grant
		AudioMgr.play_ui("buy_denied")
		return

	AudioMgr.play_ui("buy_purchase")
	if not _last_loadout.has(id):
		_last_loadout.append(id)
	Persistence.put("last_loadout", _last_loadout)
	purchased.emit(id)
	_refresh_items()
	_show_detail(id)


## Rebuy the previous loadout in a sensible order: armour first, then a primary,
## then utility — the order a player would click.
func quick_buy() -> void:
	if player == null or not _buy_allowed():
		AudioMgr.play_ui("buy_denied")
		return
	var order := ["armor_helmet", "armor", "helmet"]
	for id in order:
		if _last_loadout.has(id):
			_try_purchase(id)
	for id in _last_loadout:
		var def := WeaponDB.get_def(id)
		if def.is_empty():
			continue
		var cat := int(def.get("category", -1))
		if cat >= 0 and cat <= 3:
			_try_purchase(String(id))
	for id in _last_loadout:
		var def2 := WeaponDB.get_def(id)
		if not def2.is_empty() and int(def2.get("category", -1)) == 5:
			_try_purchase(String(id))
	if player.team == GameState.Team.DEF and _last_loadout.has("defusekit"):
		_try_purchase("defusekit")


func _buy_allowed() -> bool:
	if round_director and round_director.has_method("buy_allowed"):
		return round_director.buy_allowed(player.team, in_buy_zone)
	return in_buy_zone and GameState.phase == GameState.Phase.FREEZE_BUY


# ---------------------------------------------------------------------------

func open_menu() -> void:
	visible = true
	_refresh_items()
	if _selected_id != "":
		_show_detail(_selected_id)


func close_menu() -> void:
	visible = false
	closed.emit()


func toggle() -> void:
	if visible:
		close_menu()
	else:
		open_menu()


func _process(_delta: float) -> void:
	if not visible:
		return
	if _timer_label:
		if GameState.phase == GameState.Phase.FREEZE_BUY:
			_timer_label.text = "BUY TIME %0.0f" % GameState.phase_time_left
			_timer_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		elif _buy_allowed():
			_timer_label.text = "BUY WINDOW CLOSING"
			_timer_label.add_theme_color_override("font_color", UITheme.WARN)
		else:
			_timer_label.text = "BUY CLOSED"
			_timer_label.add_theme_color_override("font_color", UITheme.BAD)


func _on_money_changed(id: int) -> void:
	if player and id == player.player_id:
		_refresh_money()
		_refresh_items()


func _refresh_money() -> void:
	if _money_label == null or player == null:
		return
	var m := Economy.get_money(player.player_id)
	_money_label.text = "%d" % m
	_money_label.add_theme_color_override("font_color", UITheme.money_color(m))


## Small filled progress bar used by the detail panel's stat rows.
class StatBar extends Control:
	var fraction: float = 0.0:
		set(v):
			fraction = v
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(1, 1, 1, 0.07))
		draw_rect(Rect2(r.position, Vector2(r.size.x * fraction, r.size.y)),
			UITheme.ACCENT)
