class_name Scoreboard
extends Control
## Full-match scoreboard, opened from a dedicated HUD button (mobile has no TAB).
##
## Shows both teams sorted by performance with kills / deaths / assists, money,
## whether each player is alive, and the round score. Also used as the
## end-of-match screen by calling `show_final()`.

const ROW_H := 40.0

var local_player_id: int = -1

var _atk_rows: VBoxContainer = null
var _def_rows: VBoxContainer = null
var _atk_header: Label = null
var _def_header: Label = null
var _score_label: Label = null
var _title: Label = null
var _subtitle: Label = null
var _sorted: Array = []


func _ready() -> void:
	theme = UITheme.build()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.70)
	add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 30)
	margin.add_theme_constant_override("margin_right", 30)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(UITheme.GAP))
	margin.add_child(col)

	# Header: score in the middle, team names either side.
	var head := PanelContainer.new()
	var hrow := HBoxContainer.new()
	hrow.alignment = BoxContainer.ALIGNMENT_CENTER
	hrow.add_theme_constant_override("separation", 26)
	head.add_child(hrow)

	_title = Label.new()
	_title.text = "SCOREBOARD"
	_title.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	_title.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	hrow.add_child(_title)

	_score_label = Label.new()
	_score_label.add_theme_font_size_override("font_size", UITheme.FS_HUGE)
	hrow.add_child(_score_label)

	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	_subtitle.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	hrow.add_child(_subtitle)

	col.add_child(head)

	var teams := HBoxContainer.new()
	teams.size_flags_vertical = Control.SIZE_EXPAND_FILL
	teams.add_theme_constant_override("separation", int(UITheme.GAP))
	col.add_child(teams)

	var atk_panel := _make_team_panel(GameState.Team.ATK)
	teams.add_child(atk_panel.panel)
	_atk_rows = atk_panel.rows
	_atk_header = atk_panel.header

	var def_panel := _make_team_panel(GameState.Team.DEF)
	teams.add_child(def_panel.panel)
	_def_rows = def_panel.rows
	_def_header = def_panel.header

	var close := Button.new()
	close.text = "CLOSE"
	close.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
	close.pressed.connect(func(): hide_board())
	col.add_child(close)


func _make_team_panel(team: int) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)

	var header := Label.new()
	header.text = String(GameState.TEAM_NAMES.get(team, "TEAM")).to_upper()
	header.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	header.add_theme_color_override("font_color", UITheme.team_color(team))
	v.add_child(header)

	# Column captions
	var caps := HBoxContainer.new()
	caps.add_theme_constant_override("separation", 8)
	for spec in [["PLAYER", 0, true], ["K", 34, false], ["D", 34, false],
			["A", 34, false], ["CREDITS", 84, false]]:
		var l := Label.new()
		l.text = String(spec[0])
		l.add_theme_font_size_override("font_size", UITheme.FS_TINY)
		l.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
		if bool(spec[2]):
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			l.custom_minimum_size = Vector2(float(spec[1]), 0)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		caps.add_child(l)
	v.add_child(caps)

	var sep := HSeparator.new()
	v.add_child(sep)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 3)
	rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(rows)

	return {"panel": panel, "rows": rows, "header": header}


# ---------------------------------------------------------------------------

func refresh() -> void:
	if _atk_rows == null:
		return
	for c in _atk_rows.get_children():
		c.queue_free()
	for c in _def_rows.get_children():
		c.queue_free()

	_score_label.text = "%d : %d" % [
		int(GameState.score.get(GameState.Team.ATK, 0)),
		int(GameState.score.get(GameState.Team.DEF, 0))]
	_score_label.add_theme_color_override("font_color", UITheme.TEXT)
	if _atk_header:
		_atk_header.text = "%s   (%d alive)" % [
			String(GameState.TEAM_NAMES.get(GameState.Team.ATK, "")).to_upper(),
			GameState.alive_count(GameState.Team.ATK)]
	if _def_header:
		_def_header.text = "%s   (%d alive)" % [
			String(GameState.TEAM_NAMES.get(GameState.Team.DEF, "")).to_upper(),
			GameState.alive_count(GameState.Team.DEF)]

	# Sort each side by kills, then fewest deaths — the ordering a player expects.
	_sorted = GameState.players.values().duplicate()
	_sorted.sort_custom(func(a, b):
		if int(a.kills) != int(b.kills):
			return int(a.kills) > int(b.kills)
		return int(a.deaths) < int(b.deaths))

	for p in _sorted:
		var target: VBoxContainer = _atk_rows if int(p.team) == GameState.Team.ATK else _def_rows
		target.add_child(_make_row(p))


func _make_row(p: Dictionary) -> Control:
	var is_local: bool = int(p.id) == local_player_id
	var alive: bool = bool(p.alive)

	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(0, ROW_H)
	var sb := UITheme.flat_box(
		Color(0.145, 0.098, 0.043) if is_local else Color(1, 1, 1, 0.03), 4)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	if is_local:
		sb.border_width_left = 3
		sb.border_color = UITheme.ACCENT
	pc.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	pc.add_child(row)

	var name_label := Label.new()
	name_label.text = String(p.name)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	# A dead player's row dims — the fastest read of who is left.
	name_label.add_theme_color_override("font_color",
		UITheme.TEXT if alive else UITheme.TEXT_FAINT)
	if not bool(p.is_human):
		name_label.text += "  ·  BOT"
	row.add_child(name_label)

	for value in [int(p.kills), int(p.deaths), int(p.assists)]:
		var l := Label.new()
		l.text = str(value)
		l.custom_minimum_size = Vector2(34, 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.add_theme_color_override("font_color",
			UITheme.TEXT if alive else UITheme.TEXT_FAINT)
		row.add_child(l)

	var money := Label.new()
	var m := Economy.get_money(int(p.id))
	money.text = str(m)
	money.custom_minimum_size = Vector2(84, 0)
	money.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money.add_theme_color_override("font_color", UITheme.money_color(m))
	row.add_child(money)
	return pc


# ---------------------------------------------------------------------------

func show_board() -> void:
	refresh()
	visible = true


func hide_board() -> void:
	visible = false


func toggle() -> void:
	if visible:
		hide_board()
	else:
		show_board()


## End-of-match presentation: same table, different framing.
func show_final(winning_team: int) -> void:
	refresh()
	var won: bool = winning_team == GameState.team_of(local_player_id)
	_title.text = "VICTORY" if won else "DEFEAT"
	_title.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	_title.add_theme_color_override("font_color", UITheme.OK if won else UITheme.BAD)
	_subtitle.text = "%s wins the match" % String(
		GameState.TEAM_NAMES.get(winning_team, ""))
	visible = true
