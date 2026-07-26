extends Control
## Main menu: Play (map / difficulty / side / length), Loadout, Crates, Settings,
## Quit. Built in code against UITheme so the whole app shares one identity.
##
## The play panel writes directly into GameState's cfg_* fields, which is the
## only thing the match scene reads when it loads.

const MATCH_SCENE := "res://scenes/game/match.tscn"
const SETTINGS_SCENE := "res://scenes/ui/settings.tscn"
const LOADOUT_SCENE := "res://scenes/ui/loadout.tscn"

const MAPS := [
	{"id": "saltline", "name": "SALTLINE", "blurb": "Coastal salt works and shipping dock. Long dock sightlines, a silo-covered middle."},
	{"id": "transit", "name": "TRANSIT", "blurb": "Decommissioned metro depot. Tight, vertical, brutal chokepoints."},
]
const DIFFICULTIES = ["RECRUIT", "REGULAR", "VETERAN"]
const LENGTHS = [
	{"label": "SHORT · first to 5", "wins": 5},
	{"label": "STANDARD · first to 7", "wins": 7},
	{"label": "FULL · first to 10", "wins": 10},
]

var _map_index := 0
var _diff_index := 1
var _length_index := 1
var _side_index := 1              ## 0 attack, 1 defend, 2 random

var _map_name: Label = null
var _map_blurb: Label = null
var _diff_button: Button = null
var _side_button: Button = null
var _length_button: Button = null


func _ready() -> void:
	theme = UITheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Coming back from a match: make sure nothing is left captured or paused.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	Settings.apply_graphics_preset()
	_restore_prefs()
	_build()


func _restore_prefs() -> void:
	var d: Dictionary = Persistence.get_value("menu", {})
	_map_index = clampi(int(d.get("map", 0)), 0, MAPS.size() - 1)
	_diff_index = clampi(int(d.get("difficulty", 1)), 0, DIFFICULTIES.size() - 1)
	_length_index = clampi(int(d.get("length", 1)), 0, LENGTHS.size() - 1)
	_side_index = clampi(int(d.get("side", 1)), 0, 2)


func _save_prefs() -> void:
	Persistence.put("menu", {
		"map": _map_index, "difficulty": _diff_index,
		"length": _length_index, "side": _side_index,
	})
	Persistence.save_now()


# ---------------------------------------------------------------------------

func _build() -> void:
	for c in get_children():
		c.queue_free()

	var bg := ColorRect.new()
	bg.color = UITheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	add_child(Backdrop.new())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 44)
	margin.add_theme_constant_override("margin_right", 44)
	margin.add_theme_constant_override("margin_top", 34)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 22)
	margin.add_child(col)

	col.add_child(_build_title())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 22)
	col.add_child(body)

	body.add_child(_build_nav())
	body.add_child(_build_play_panel())

	var version := Label.new()
	version.text = "v%s   ·   offline vs bots" % ProjectSettings.get_setting(
		"application/config/version", "0.1.0")
	version.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	version.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	col.add_child(version)


func _build_title() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	var t := Label.new()
	t.text = "TACTICAL STRIKE"
	t.add_theme_font_size_override("font_size", 46)
	t.add_theme_color_override("font_color", UITheme.TEXT)
	v.add_child(t)
	var s := Label.new()
	s.text = "BOMB DEFUSAL"
	s.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	s.add_theme_color_override("font_color", UITheme.ACCENT)
	v.add_child(s)
	return v


func _build_nav() -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(260, 0)
	v.add_theme_constant_override("separation", 8)

	v.add_child(_big_button("DEPLOY", _on_play, true))
	v.add_child(_big_button("LOADOUT", _on_loadout, false))
	v.add_child(_big_button("CRATES", _on_crates, false))
	v.add_child(_big_button("SETTINGS", _on_settings, false))

	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sp)

	v.add_child(_big_button("QUIT", _on_quit, false))
	return v


func _big_button(text: String, cb: Callable, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 64)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	if primary:
		var sb := UITheme.button_box(Color(0.196, 0.110, 0.031), UITheme.ACCENT)
		sb.border_width_left = 4
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_color_override("font_color", UITheme.ACCENT)
	b.pressed.connect(func():
		AudioMgr.play_ui("ui_click")
		cb.call())
	return b


func _build_play_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)

	var head := Label.new()
	head.text = "MISSION"
	head.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	head.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	v.add_child(head)

	_map_name = Label.new()
	_map_name.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	v.add_child(_map_name)

	_map_blurb = Label.new()
	_map_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_blurb.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	v.add_child(_map_blurb)

	var maps_row := HBoxContainer.new()
	maps_row.add_theme_constant_override("separation", 8)
	for i in MAPS.size():
		var b := Button.new()
		b.text = String(MAPS[i].name)
		b.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var idx := i
		b.pressed.connect(func():
			_map_index = idx
			AudioMgr.play_ui("ui_click")
			_refresh())
		maps_row.add_child(b)
	v.add_child(maps_row)

	v.add_child(HSeparator.new())

	_diff_button = _cycle_row(v, "BOT SKILL", func():
		_diff_index = (_diff_index + 1) % DIFFICULTIES.size())
	_side_button = _cycle_row(v, "YOUR SIDE", func():
		_side_index = (_side_index + 1) % 3)
	_length_button = _cycle_row(v, "MATCH LENGTH", func():
		_length_index = (_length_index + 1) % LENGTHS.size())

	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sp)

	_refresh()
	return panel


## A labelled row whose value cycles on tap — far better than a dropdown on a
## touch screen.
func _cycle_row(parent: Control, label: String, on_tap: Callable) -> Button:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(170, 0)
	l.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func():
		on_tap.call()
		AudioMgr.play_ui("ui_click")
		_refresh())
	row.add_child(b)
	parent.add_child(row)
	return b


func _refresh() -> void:
	var m: Dictionary = MAPS[_map_index]
	if _map_name:
		_map_name.text = String(m.name)
	if _map_blurb:
		_map_blurb.text = String(m.blurb)
	if _diff_button:
		_diff_button.text = DIFFICULTIES[_diff_index]
	if _side_button:
		_side_button.text = ["ATTACK · Havoc", "DEFEND · Aegis", "RANDOM"][_side_index]
		_side_button.add_theme_color_override("font_color",
			[UITheme.TEAM_ATK, UITheme.TEAM_DEF, UITheme.TEXT][_side_index])
	if _length_button:
		_length_button.text = String(LENGTHS[_length_index].label)


# ---------------------------------------------------------------------------

func _on_play() -> void:
	GameState.reset_match()
	GameState.cfg_map = String(MAPS[_map_index].id)
	GameState.cfg_bot_difficulty = _diff_index
	GameState.cfg_rounds_to_win = int(LENGTHS[_length_index].wins)
	match _side_index:
		0: GameState.cfg_player_team = GameState.Team.ATK
		1: GameState.cfg_player_team = GameState.Team.DEF
		_: GameState.cfg_player_team = GameState.Team.ATK if randi() % 2 == 0 else GameState.Team.DEF
	_save_prefs()
	if ResourceLoader.exists(MATCH_SCENE):
		get_tree().change_scene_to_file(MATCH_SCENE)
	else:
		push_error("main_menu: %s not found" % MATCH_SCENE)


func _on_loadout() -> void:
	if ResourceLoader.exists(LOADOUT_SCENE):
		get_tree().change_scene_to_file(LOADOUT_SCENE)


func _on_crates() -> void:
	# Crates live on the loadout screen's second tab.
	if ResourceLoader.exists(LOADOUT_SCENE):
		Persistence.put("loadout_open_tab", 1)
		get_tree().change_scene_to_file(LOADOUT_SCENE)


func _on_settings() -> void:
	if ResourceLoader.exists(SETTINGS_SCENE):
		get_tree().change_scene_to_file(SETTINGS_SCENE)


func _on_quit() -> void:
	Settings.save_to_disk()
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_quit()


## Slow-drifting geometric backdrop. Cheap (a handful of lines redrawn at low
## frequency) and it keeps the menu from looking like a blank slab.
class Backdrop extends Control:
	var t: float = 0.0

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _ready() -> void:
		set_process(true)

	func _process(delta: float) -> void:
		t += delta * 0.06
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		# Diagonal hatch drifting slowly to the right.
		var step := 96.0
		var offset := fmod(t * step, step)
		var col := Color(1, 1, 1, 0.022)
		var x := -h + offset
		while x < w + h:
			draw_line(Vector2(x, h), Vector2(x + h, 0.0), col, 1.0)
			x += step
		# A single accent sweep anchored to the title area.
		draw_line(Vector2(0.0, h * 0.30), Vector2(w, h * 0.30),
			Color(UITheme.ACCENT, 0.06), 1.0)
